class_name DotCloudStore
extends RefCounted

## The content-addressed cache: objects on disk, keyed by SHA-256.
## Content addressing makes hot-swapping affordable: games sharing a texture pack download it once, a
## republish fetches only what changed, a partial cannot be confused with another file at the same path
## (which makes resume safe), and verification is checked once when an object is written.
## Objects live in [code]<cache>/objects/<aa>/<full-hash>[/code], sharded by two hex characters because a
## flat directory of 50,000 entries is slow everywhere. Partials live elsewhere, so nothing in `objects/` is unverified.
## [code]<cache>/index.json[/code] tracks size, last use and referencing content sets, for LRU eviction.

const CHANNEL := "cloud.store"

## Index schema version.
const INDEX_VERSION := 1

var config: DotCloudConfig

## hash -> {size:int, used:int (unix secs), refs:Array[String]}
var _index: Dictionary = {}

var _index_dirty: bool = false
var _total_bytes: int = 0

## Cache ceiling actually in force, resolved at [method open] time because on web
## it depends on a quota the browser only reports asynchronously.
var _limit_bytes: int = 0

## Returns the bytes the browser would still let us write, or -1 when unknown; empty means ask
## [method DotWeb.estimate_storage]. A test sets it to stand in for a browser.
var free_bytes_provider: Callable = Callable()

## What packs the cache holds, for [method inventory].
var packs: DotCloudPackBook

## Takes a content key, true while it is mounted (set by [DotCloudClient]); [method delete] refuses those.
var in_use_fn: Callable = Callable()

## -1 ask the page, 0 top-level, 1 embedded in another site; a test or the shell may set it. Decides [code]partitioned[/code] in [method quota_report].
var embedded: int = -1


func _init(p_config: DotCloudConfig) -> void:
	config = p_config
	packs = DotCloudPackBook.new(config.cache_dir.path_join("inventory.json"))


## Creates the cache directories, loads the index, and resolves the size limit.
## Must be awaited: on web the limit comes from the promise [method DotWeb.estimate_storage].
func open() -> DotResult:
	for dir in [config.cache_dir, config.objects_dir(), config.partials_dir()]:
		var made := DotPaths.ensure_dir(dir)
		if not made.ok:
			return made.wrap("Could not create the content cache.")

	if config.request_persistent_storage and DotPlatform.is_web():
		DotWeb.request_persistent_storage()

	_load_index()
	packs.load_file()
	await _resolve_limit()
	if packs.any_pinned():
		_request_persist()

	DotLog.info(
		CHANNEL,
		"cache open",
		{
			"objects": _index.size(),
			"size": DotPaths.format_bytes(_total_bytes),
			"limit": DotPaths.format_bytes(_limit_bytes) if _limit_bytes > 0 else "unlimited",
		}
	)

	return DotResult.success(self)


## Works out how much space we may use.
## On web an unavailable estimate falls back to the configured ceiling, not unlimited, which would
## surface as a failed write halfway through a download.
func _resolve_limit() -> void:
	if not DotPlatform.is_web():
		_limit_bytes = config.effective_cache_bytes()
		return

	var est := await DotWeb.estimate_storage()
	if not est.ok:
		_limit_bytes = config.effective_cache_bytes()
		DotLog.debug(
			CHANNEL,
			"no browser quota estimate; using the configured ceiling",
			{"reason": est.error.message}
		)
		return

	var d: Dictionary = est.value
	var quota := int(d.get("quota", 0))
	if quota <= 0:
		_limit_bytes = config.effective_cache_bytes()
		return

	_limit_bytes = int(float(quota) * config.web_quota_fraction)
	if config.cache_bytes > 0:
		_limit_bytes = mini(_limit_bytes, config.cache_bytes)

	DotLog.info(
		CHANNEL,
		"browser storage",
		{
			"quota": DotPaths.format_bytes(quota),
			"our_limit": DotPaths.format_bytes(_limit_bytes),
		}
	)


func close() -> void:
	flush_index()


## Absolute path of an object, whether or not it exists.
func path_for(sha256: String) -> String:
	var h := sha256.to_lower()
	return config.objects_dir().path_join("%s/%s" % [h.substr(0, 2), h])


## Whether an object is present and complete; also refreshes its last-used stamp.
## A cheap check, valid because nothing unverified is written into the object directory.
func has(sha256: String) -> bool:
	var path := path_for(sha256)
	if not FileAccess.file_exists(path):
		# An index entry with no file means the browser evicted our storage or a
		# user cleared it; drop the entry so it is re-downloaded rather than
		# reported present forever.
		if _index.has(sha256):
			_forget(sha256)
		return false

	touch(sha256)
	return true


## Updates an object's last-used time, for LRU eviction ordering.
func touch(sha256: String) -> void:
	if not _index.has(sha256):
		return
	_index[sha256]["used"] = int(Time.get_unix_time_from_system())
	_index_dirty = true


func size_of(sha256: String) -> int:
	if _index.has(sha256):
		return int(_index[sha256]["size"])
	return DotPaths.file_size(path_for(sha256))


func read(sha256: String) -> DotResult:
	if not has(sha256):
		return DotResult.fail(
			DotError.CODE_IO, "Object is not cached.", sha256.substr(0, 16)
		)
	return DotPaths.read_bytes(path_for(sha256))


## Path of the in-progress download for an object.
## Keyed by content hash, so appending to an existing partial cannot splice unrelated bytes.
func partial_path(sha256: String) -> String:
	return config.partials_dir().path_join("%s.part" % sha256.to_lower())


## Bytes already downloaded for an object. 0 when there is no partial.
func partial_size(sha256: String) -> int:
	var path := partial_path(sha256)
	if not FileAccess.file_exists(path):
		return 0
	return maxi(0, DotPaths.file_size(path))


func discard_partial(sha256: String) -> void:
	var path := partial_path(sha256)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		DotWeb.sync_filesystem()


## Promotes a verified partial into the object store; the hash is checked here and nowhere else,
## and a mismatch is discarded, not retried. [param scheduler] slices the hashing (null: synchronous).
func commit_partial(
	sha256: String,
	scheduler: DotScheduler = null
) -> DotResult:
	var src := partial_path(sha256)
	if not FileAccess.file_exists(src):
		return DotResult.fail(
			DotError.CODE_IO, "There is no partial download to commit.", sha256
		)

	var verified: DotResult
	if scheduler != null:
		verified = await scheduler.run(DotHashJob.new(src, sha256))
	else:
		var hashed := DotHash.sha256_file(src)
		if not hashed.ok:
			verified = hashed
		elif not DotHash.constant_time_equal_hex(hashed.value, sha256):
			verified = DotResult.fail(
				DotError.CODE_INTEGRITY,
				"Downloaded content does not match its expected hash.",
				"expected %s, got %s"
					% [sha256.substr(0, 16), str(hashed.value).substr(0, 16)]
			)
		else:
			verified = DotResult.success(sha256)

	if not verified.ok:
		# Corrupt bytes are useless and actively harmful to keep: a resume would
		# append to them and fail identically forever.
		discard_partial(sha256)
		return verified

	var dest := path_for(sha256)
	var parent := DotPaths.ensure_parent_dir(dest)
	if not parent.ok:
		return parent

	var size := DotPaths.file_size(src)

	# A concurrent download of the same hash may have already committed it. Both
	# copies are byte-identical by construction, so the loser just drops its own.
	if FileAccess.file_exists(dest):
		discard_partial(sha256)
		_record(sha256, size)
		return DotResult.success(dest)

	var err := DirAccess.rename_absolute(src, dest)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "moving '%s' into the cache" % src)
		)

	# Sync per object, not once per sync: on web an unflushed write is lost with the tab, and a player
	# closing it mid-download should keep the finished objects.
	DotWeb.sync_filesystem()

	_record(sha256, size)

	DotLog.debug(
		CHANNEL,
		"object committed",
		{"hash": sha256.substr(0, 12), "size": DotPaths.format_bytes(size)}
	)

	return DotResult.success(dest)


## Writes bytes directly as an object, verifying them first.
## For content that arrived by another route: the in-band netchan source, or a local import.
func put_bytes(bytes: PackedByteArray, expected_sha256: String) -> DotResult:
	var actual := DotHash.sha256_bytes(bytes)
	if not DotHash.constant_time_equal_hex(actual, expected_sha256):
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"Content does not match its expected hash.",
			"expected %s, got %s"
				% [expected_sha256.substr(0, 16), actual.substr(0, 16)]
		)

	var dest := path_for(expected_sha256)
	if FileAccess.file_exists(dest):
		discard_partial(expected_sha256)
		_record(expected_sha256, bytes.size())
		return DotResult.success(dest)

	var written := DotPaths.write_bytes(dest, bytes)
	if not written.ok:
		return written

	# Drop any partial an interrupted HTTP download left: nothing resumes a partial for committed content,
	# and a netchan fallback after a part-way HTTP failure is exactly when the disk is under pressure.
	discard_partial(expected_sha256)

	_record(expected_sha256, bytes.size())
	return DotResult.success(dest)


## Records that [param content_key] needs these objects, so they survive eviction.
## Otherwise playing game B could evict game A's content and turn a map change into a re-download.
func add_refs(content_key: String, hashes: PackedStringArray) -> void:
	for h in hashes:
		if not _index.has(h):
			continue
		var refs: Array = _index[h]["refs"]
		if not refs.has(content_key):
			refs.append(content_key)
	_index_dirty = true


## Drops a content set's claim on its objects; they become eviction candidates, not deleted,
## so unmounting is free and a quick reconnect finds the content still there.
func release_refs(content_key: String) -> void:
	for h in _index:
		var refs: Array = _index[h]["refs"]
		refs.erase(content_key)
	_index_dirty = true

	DotLog.debug(CHANNEL, "refs released", {"content": content_key})


func ref_count(sha256: String) -> int:
	if not _index.has(sha256):
		return 0
	return (_index[sha256]["refs"] as Array).size()


## Whether the cache is over its ceiling.
func is_over_limit() -> bool:
	return _limit_bytes > 0 and _total_bytes > _limit_bytes


## Bytes that would need to be freed to fit [param incoming] more.
func shortfall(incoming: int = 0) -> int:
	if _limit_bytes <= 0:
		return 0
	return maxi(0, (_total_bytes + incoming) - _limit_bytes)


## Evicts unreferenced objects, least recently used first; returns the bytes freed.
## Referenced objects are never evicted, so a cache full of them cannot shrink: [method prune] reports
## the shortfall and the caller decides whether to proceed or refuse the download.
func prune(need_bytes: int = 0) -> DotResult:
	var target := shortfall(need_bytes)
	if target <= 0:
		return DotResult.success(0)

	var pinned := packs.pinned_hashes()
	var candidates: Array = []
	for h in _index:
		if (_index[h]["refs"] as Array).is_empty() and not pinned.has(h):
			candidates.append(h)

	candidates.sort_custom(func(a: String, b: String) -> bool:
		return int(_index[a]["used"]) < int(_index[b]["used"])
	)

	var freed := 0
	for h in candidates:
		if freed >= target:
			break

		var size := int(_index[h]["size"])
		var err := DirAccess.remove_absolute(path_for(h))
		if err != OK and FileAccess.file_exists(path_for(h)):
			DotLog.warn(
				CHANNEL, "could not evict object", {"hash": h.substr(0, 12)}
			)
			continue

		_forget(h)
		freed += size

	DotWeb.sync_filesystem()
	flush_index()

	DotLog.info(
		CHANNEL,
		"pruned cache",
		{
			"freed": DotPaths.format_bytes(freed),
			"wanted": DotPaths.format_bytes(target),
			"objects": candidates.size(),
		}
	)

	if freed < target:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"The content cache is full and everything in it is in use.",
			"freed %s of %s needed; %d object(s) are referenced by mounted content"
				% [
					DotPaths.format_bytes(freed),
					DotPaths.format_bytes(target),
					_index.size() - candidates.size(),
				]
		)

	return DotResult.success(freed)


## Bytes the origin can still write now (quota minus usage), or -1 when unmeasurable. Only this
## figure may refuse a download; the ceiling from [method open] only decides eviction. Await it.
func free_bytes() -> int:
	if free_bytes_provider.is_valid():
		return int(await free_bytes_provider.call())
	if not DotPlatform.is_web():
		return -1

	var est := await DotWeb.estimate_storage()
	if not est.ok:
		return -1
	var quota := int((est.value as Dictionary).get("quota", 0))
	if quota <= 0:
		return -1
	return maxi(0, quota - int((est.value as Dictionary).get("usage", 0)))


## Whether [method free_bytes] is meaningful here, so a full ceiling can be second-guessed.
func has_measured_free() -> bool:
	return free_bytes_provider.is_valid() or DotPlatform.is_web()


## Deletes everything, including referenced objects, for a "clear downloaded content" button.
## Unsafe while content is mounted: mounted paths keep resolving to deleted files and look like corruption.
## Restart after calling it.
func clear_all() -> DotResult:
	var removed := DotPaths.remove_tree(config.objects_dir())
	DotPaths.remove_tree(config.partials_dir())
	# And the packs: [DotCloudMounter] keeps a `.pck` per mounted set under `<cache_dir>/packs/`, a second
	# copy of everything played; they are rebuilt from the objects on the next mount.
	DotPaths.remove_tree(config.cache_dir.path_join("packs"))

	_index.clear()
	_total_bytes = 0
	_index_dirty = true
	packs.records.clear()
	packs.dirty = true
	flush_index()

	DotPaths.ensure_dir(config.objects_dir())
	DotPaths.ensure_dir(config.partials_dir())

	# Synced like every commit: on web the filesystem is an IndexedDB mirror and an unsynced clear comes back on reload.
	DotWeb.sync_filesystem()

	DotLog.info(CHANNEL, "cache cleared")
	return removed


## Removes partials that can never be resumed; cheap, worth doing at startup. A partial is dead when
## older than [param max_age_sec] or when its object is already stored (a transfer that fell back to
## another source), since keeping it would hold the largest files twice under disk pressure.
func sweep_partials(max_age_sec: float = 86400.0) -> int:
	var now := int(Time.get_unix_time_from_system())
	var removed := 0

	for name in DotPaths.list_files_recursive(config.partials_dir()):
		var path := config.partials_dir().path_join(name)
		var hash_of := String(name).get_file().get_basename()
		if hash_of.length() == 64 and FileAccess.file_exists(path_for(hash_of)):
			DirAccess.remove_absolute(path)
			removed += 1
			continue

		var modified := FileAccess.get_modified_time(path)
		if modified > 0 and (now - modified) < int(max_age_sec):
			continue
		DirAccess.remove_absolute(path)
		removed += 1

	if removed > 0:
		DotWeb.sync_filesystem()
		DotLog.debug(CHANNEL, "swept stale partials", {"count": removed})

	return removed


## Re-hashes every cached object and drops any that no longer match.
## Slow, so opt-in via [member DotCloudConfig.verify_cache_on_start]; catches storage that changed
## underneath us (evicted IndexedDB, trimmed mobile sandbox, failing disk).
func verify_all(scheduler: DotScheduler) -> DotResult:
	var checked := 0
	var dropped := 0

	for h in _index.keys():
		var path := path_for(h)
		if not FileAccess.file_exists(path):
			_forget(h)
			dropped += 1
			continue

		var res := await scheduler.run(DotHashJob.new(path, h))
		checked += 1

		if not res.ok:
			DotLog.warn(
				CHANNEL,
				"cached object failed verification; dropping it",
				{"hash": h.substr(0, 12), "why": res.error.code}
			)
			DirAccess.remove_absolute(path)
			_forget(h)
			dropped += 1

	flush_index()

	DotLog.info(
		CHANNEL, "cache verified", {"checked": checked, "dropped": dropped}
	)

	return DotResult.success({"checked": checked, "dropped": dropped})


func _record(sha256: String, size: int) -> void:
	if _index.has(sha256):
		_index[sha256]["used"] = int(Time.get_unix_time_from_system())
	else:
		_index[sha256] = {
			"size": size,
			"used": int(Time.get_unix_time_from_system()),
			"refs": [],
		}
		_total_bytes += size

	_index_dirty = true


func _forget(sha256: String) -> void:
	if not _index.has(sha256):
		return
	_total_bytes -= int(_index[sha256]["size"])
	_total_bytes = maxi(0, _total_bytes)
	_index.erase(sha256)
	_index_dirty = true


func _load_index() -> void:
	_index.clear()
	_total_bytes = 0

	var res := DotPaths.read_json(config.index_path())
	if not res.ok:
		# No index, or an unreadable one. Rebuilding from the directory is always
		# possible because the filenames *are* the hashes — the index is a cache
		# of metadata, never the source of truth.
		_rebuild_index()
		return

	var data: Variant = res.value
	if not (data is Dictionary):
		_rebuild_index()
		return

	var d := data as Dictionary
	if int(d.get("version", 0)) != INDEX_VERSION:
		DotLog.info(
			CHANNEL, "index format changed; rebuilding", {"had": d.get("version")}
		)
		_rebuild_index()
		return

	var objects: Variant = d.get("objects", {})
	if not (objects is Dictionary):
		_rebuild_index()
		return

	for h in (objects as Dictionary):
		var entry: Variant = objects[h]
		if not (entry is Dictionary):
			continue
		var e := entry as Dictionary
		var refs: Array = []
		if e.get("refs") is Array:
			refs = (e["refs"] as Array).duplicate()

		_index[str(h)] = {
			"size": int(e.get("size", 0)),
			"used": int(e.get("used", 0)),
			"refs": refs,
		}
		_total_bytes += int(e.get("size", 0))

	_reconcile_with_disk()


## Makes the loaded index agree with what is actually in [code]objects/[/code].
## The index is always behind the directory by design: objects are flushed at commit but the index only
## at sync end, mount and prune, so an unclean shutdown leaves valid objects a parseable index never
## heard of, and [method _rebuild_index] never runs. An untracked object is never re-downloaded or
## evicted and is missing from [member _total_bytes], so the cache grows past its ceiling permanently.
## One directory walk at open, which a missing index costs anyway.
func _reconcile_with_disk() -> void:
	var on_disk := {}
	for rel in DotPaths.list_files_recursive(config.objects_dir()):
		var name := rel.get_file()
		if name.length() != 64:
			continue
		on_disk[name] = DotPaths.file_size(config.objects_dir().path_join(rel))

	var now := int(Time.get_unix_time_from_system())
	var adopted := 0
	var adopted_bytes := 0

	for h: String in on_disk:
		var size := int(on_disk[h])
		if size < 0:
			continue
		if _index.has(h):
			# Trust the file over the index for size: the index entry may predate
			# a truncated write, and every byte accounting downstream is derived
			# from this number.
			var recorded := int(_index[h]["size"])
			if recorded != size:
				_total_bytes += size - recorded
				_index[h]["size"] = size
				_index_dirty = true
			continue
		# Last use is unknown, so it starts from now. That is the conservative
		# direction: a newly adopted object is evicted last rather than first,
		# and one sync makes it accurate.
		_index[h] = {"size": size, "used": now, "refs": []}
		_total_bytes += size
		adopted += 1
		adopted_bytes += size

	var dropped := 0
	for h: String in _index.keys():
		if on_disk.has(h):
			continue
		# Storage was evicted or cleared: dropping these now makes _total_bytes true before the first
		# shortfall() is reported to a player.
		_forget(h)
		dropped += 1

	if adopted > 0 or dropped > 0:
		_index_dirty = true
		DotLog.info(
			CHANNEL,
			"reconciled the cache index with the object directory",
			{
				"adopted": adopted,
				"adopted_bytes": DotPaths.format_bytes(adopted_bytes),
				"dropped": dropped,
			}
		)


## Rebuilds the index by walking the object directory.
## Possible because a filename is a hash; only last-use times and references are lost, and they are
## re-added on the next mount and restarted from now.
func _rebuild_index() -> void:
	_index.clear()
	_total_bytes = 0

	# The same walk [method _reconcile_with_disk] does, against an empty index —
	# every object on disk is adopted. Keeping one implementation means a rebuilt
	# index and a reconciled one cannot disagree about what the directory says.
	_reconcile_with_disk()
	_index_dirty = true

	DotLog.info(
		CHANNEL,
		"rebuilt cache index",
		{"objects": _index.size(), "size": DotPaths.format_bytes(_total_bytes)}
	)


func flush_index() -> void:
	packs.save()
	if not _index_dirty:
		return

	var objects := {}
	for h in _index:
		objects[h] = _index[h]

	var written := DotPaths.write_json(
		config.index_path(),
		{"version": INDEX_VERSION, "objects": objects},
		false
	)

	if written.ok:
		_index_dirty = false
	else:
		DotLog.warn(
			CHANNEL,
			"could not write the cache index",
			{"detail": written.error.detail}
		)


func total_bytes() -> int:
	return _total_bytes


func limit_bytes() -> int:
	return _limit_bytes


func object_count() -> int:
	return _index.size()


func referenced_bytes() -> int:
	var n := 0
	for h in _index:
		if not (_index[h]["refs"] as Array).is_empty():
			n += int(_index[h]["size"])
	return n


func describe() -> Dictionary:
	return {
		"dir": config.cache_dir,
		"objects": _index.size(),
		"bytes": _total_bytes,
		"bytes_human": DotPaths.format_bytes(_total_bytes),
		"referenced": DotPaths.format_bytes(referenced_bytes()),
		"limit": DotPaths.format_bytes(_limit_bytes) if _limit_bytes > 0 else "unlimited",
		"over_limit": is_over_limit(),
		"packs": packs.records.size(),
		"pinned_packs": packs.records.values().filter(func(r: Dictionary) -> bool: return bool(r["pinned"])).size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-16s %s" % [str(k), str(d[k])])
	return out


## Notes a pack as held (and just used). Called by [DotCloudClient] once its objects are in.
func record_pack(manifest: DotCloudManifest) -> void:
	packs.record(manifest, int(Time.get_unix_time_from_system()))
	flush_index()


## One entry per pack: id, version, kind (game|map|weapon|workshop), game, name, bytes, last_used (unix s), pinned, platform (web|app).
## A record whose objects are all gone (browser eviction) is dropped. Bytes count shared objects in every pack that uses them.
func inventory() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var gone: Array = []
	for k in packs.records:
		var r: Dictionary = packs.records[k]
		var bytes := 0
		var present := 0
		for h in (r["hashes"] as Array):
			if _index.has(h):
				bytes += int(_index[h]["size"])
				present += 1
		if present == 0 and not (r["hashes"] as Array).is_empty():
			gone.append(k)
			continue
		out.append({
			"id": r["id"], "version": r["version"], "kind": r["kind"], "game": r["game"], "name": r["name"],
			"bytes": bytes, "last_used": int(r["last_used"]), "pinned": bool(r["pinned"]),
			"platform": "web" if DotPlatform.is_web() else "app",
		})
	for k in gone:
		packs.records.erase(k)
		packs.dirty = true
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["last_used"]) > int(b["last_used"]))
	return out


## Pins every version of [param id]: eviction skips its objects. Pinning on web also asks the browser for persistent storage.
func set_pinned(id: String, pinned: bool) -> DotResult:
	var keys := packs.keys_for_id(id)
	if keys.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No downloaded content with that id.", id)
	for k in keys:
		packs.records[k]["pinned"] = pinned
	packs.dirty = true
	flush_index()
	if pinned:
		_request_persist()
	DotLog.info(CHANNEL, "pin changed", {"id": id, "pinned": pinned})
	return DotResult.success(keys.size())


## "Keep content downloaded" for a game: pins its packs now and those it downloads later.
func set_game_pinned(game: String, pinned: bool) -> DotResult:
	if pinned and game.length() > DotCloudPackBook.MAX_GAME_ID:
		return DotResult.fail(DotError.CODE_INVALID, "Game id too long.")
	if pinned and packs.pinned_games.size() >= DotCloudPackBook.MAX_PINNED_GAMES and not packs.pinned_games.has(game):
		return DotResult.fail(DotError.CODE_INVALID, "Too many pinned games.")
	var n := 0
	for k in packs.records:
		if packs.records[k]["game"] == game:
			packs.records[k]["pinned"] = pinned
			n += 1
	var at := packs.pinned_games.find(game)
	if pinned and at < 0:
		packs.pinned_games.append(game)
	elif not pinned and at >= 0:
		packs.pinned_games.remove_at(at)
	packs.dirty = true
	flush_index()
	if pinned:
		_request_persist()
	return DotResult.success(n)


## Deletes a pack's objects, except those another pack still needs. Refuses a pack mounted in this process (its files cannot be unmounted): [code]CODE_STATE[/code].
func delete(id: String, version: String = "", force: bool = false) -> DotResult:
	var keys := packs.keys_for_id(id, version)
	if keys.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No downloaded content with that id.", id)
	for k in keys:
		if not force and bool(packs.records[k].get("pinned", false)):
			return DotResult.fail(DotError.CODE_STATE, "That content is pinned; unpin it or force the delete.", k)
		if in_use_fn.is_valid() and bool(in_use_fn.call(k)):
			return DotResult.fail(DotError.CODE_STATE, "That content is in use; restart to delete it.", k)

	var shared := packs.hashes_used_outside(keys)
	var freed := 0
	for k in keys:
		for h in (packs.records[k]["hashes"] as Array):
			if shared.has(h) or not _index.has(h):
				continue
			var size := int(_index[h]["size"])
			if DirAccess.remove_absolute(path_for(h)) != OK and FileAccess.file_exists(path_for(h)):
				DotLog.warn(CHANNEL, "could not delete object", {"hash": str(h).substr(0, 12)})
				continue
			_forget(h)
			freed += size
		release_refs(k)
		packs.records.erase(k)
	packs.dirty = true
	DotWeb.sync_filesystem()
	flush_index()
	DotLog.info(CHANNEL, "deleted content", {"id": id, "freed": DotPaths.format_bytes(freed)})
	return DotResult.success(freed)


## Deletes every pack that is not pinned and not in use; returns the bytes freed. [method clear_all] is the one that takes pinned packs too.
func clear_unpinned() -> DotResult:
	var freed := 0
	var ids := {}
	for k in packs.records.keys():
		var r: Dictionary = packs.records[k]
		if not bool(r["pinned"]) and not (in_use_fn.is_valid() and bool(in_use_fn.call(k))):
			ids[k] = r
	for k in ids:
		var done := delete(ids[k]["id"], ids[k]["version"])
		if done.ok:
			freed += int(done.value)
	return DotResult.success(freed)


## Free space: [code]{free, quota, usage, quota_cause}[/code], numbers -1 when unknown.
## [code]quota_cause[/code] is "", "unreadable", "near-full" (under a twentieth or 100 MiB left) or
## "partitioned" (embedded in another site). A hint for wording an error only. Await it.
func quota_report() -> Dictionary:
	var free := await free_bytes()
	var quota := -1
	var usage := -1
	if DotPlatform.is_web():
		var est := await DotWeb.estimate_storage()
		if est.ok:
			quota = int((est.value as Dictionary).get("quota", -1))
			usage = int((est.value as Dictionary).get("usage", -1))
	var cause := ""
	if free < 0:
		cause = "unreadable"
	elif quota > 0 and (free < quota / 20 or free < 100 * 1024 * 1024):
		cause = "partitioned" if _is_embedded() else "near-full"
	elif quota <= 0 and free < 100 * 1024 * 1024:
		cause = "partitioned" if _is_embedded() else "near-full"
	return {"free": free, "quota": quota, "usage": usage, "quota_cause": cause}


func _is_embedded() -> bool:
	if embedded >= 0:
		return embedded == 1
	if not DotPlatform.is_web():
		return false
	var loc: Variant = DotWeb.get_global("location")
	if loc == null:
		return false
	var ancestors: Variant = loc.ancestorOrigins
	return ancestors != null and int(ancestors.length) > 0


func _request_persist() -> void:
	if DotPlatform.is_web():
		DotWeb.request_persistent_storage()
