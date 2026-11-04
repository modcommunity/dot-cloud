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


func _init(p_config: DotCloudConfig) -> void:
	config = p_config


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
	await _resolve_limit()

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


## Promotes a verified partial into the object store.
## Verification happens here and nowhere else: the partial is hashed against its name before the move,
## which lets every other read skip verification and discards a mismatch instead of retrying corrupt bytes.
## [param scheduler] slices the hashing; null hashes synchronously (fine for small files only).
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

	var candidates: Array = []
	for h in _index:
		if (_index[h]["refs"] as Array).is_empty():
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


## Bytes the origin can still write right now (quota minus usage), or -1 when that cannot be
## measured. The ceiling from [method open] is a share of the quota and is used to decide what to
## evict; only this figure may refuse a download, since anything below the quota still fits.
## Must be awaited.
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
	flush_index()

	DotPaths.ensure_dir(config.objects_dir())
	DotPaths.ensure_dir(config.partials_dir())

	# Synced like every commit: on web the filesystem is an IndexedDB mirror and an unsynced clear comes back on reload.
	DotWeb.sync_filesystem()

	DotLog.info(CHANNEL, "cache cleared")
	return removed


## Removes partials that can never be resumed into anything useful; cheap, worth doing at startup.
## A partial is dead when old, or when its object is already in the store (a transfer that fell back
## to another source, e.g. HTTP half then netchan via [method put_bytes]). Keeping those for
## [param max_age_sec] would hold the largest files twice, under the disk pressure that caused the failover.
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
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-16s %s" % [str(k), str(d[k])])
	return out
