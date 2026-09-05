class_name DotCloudStore
extends RefCounted

## The content-addressed cache: objects on disk, keyed by SHA-256.
##
## [b]Content addressing is what makes hot-swapping content affordable.[/b] Files
## are stored under their hash, not their path, so:
##
## - two games sharing a 40 MB texture pack download it once;
## - re-publishing a game re-downloads only what actually changed;
## - a partially-downloaded file cannot be confused with a different file that
##   happens to live at the same path, which is what makes resume safe;
## - verification is a property of the object, checked once when it is written.
##
## Objects live in [code]<cache>/objects/<aa>/<full-hash>[/code] — sharded by the
## first two hex characters, because a flat directory of 50,000 entries is slow to
## enumerate on every filesystem in the target set. Partial downloads live
## somewhere else entirely, so nothing in [code]objects/[/code] is ever
## unverified.
##
## An index at [code]<cache>/index.json[/code] tracks size, last use and which
## content sets reference each object, so eviction can be least-recently-used and
## can leave referenced content alone.

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


func _init(p_config: DotCloudConfig) -> void:
	config = p_config


# --- Lifecycle -------------------------------------------------------------

## Creates the cache directories, loads the index, and resolves the size limit.
##
## Must be awaited: on web the limit comes from
## [method DotWeb.estimate_storage], which is a promise.
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
##
## On web the browser's quota is the real constraint and it is not knowable up
## front, so an unavailable estimate falls back to the configured ceiling rather
## than assuming unlimited — assuming unlimited means discovering the truth as a
## failed write halfway through a download.
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


# --- Object access ---------------------------------------------------------

## Absolute path of an object, whether or not it exists.
func path_for(sha256: String) -> String:
	var h := sha256.to_lower()
	return config.objects_dir().path_join("%s/%s" % [h.substr(0, 2), h])


## Whether an object is present and complete.
##
## A cheap existence check, valid precisely because nothing unverified is ever
## written into the object directory. Also refreshes the last-used stamp, so
## reading content keeps it from being evicted.
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


# --- Partials --------------------------------------------------------------

## Path of the in-progress download for an object.
##
## Keyed by content hash, which is what makes resume safe: two different files
## can never share a partial, so appending to whatever is already there cannot
## splice unrelated bytes together.
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
##
## [b]Verification happens here and nowhere else.[/b] The partial is hashed and
## must match the name it was downloaded under; only then is it moved. That single
## chokepoint is what lets every other read in this class skip verification, and
## it is why a mismatched download is discarded rather than kept and retried
## against the same corrupt bytes.
##
## [param scheduler] slices the hashing. Pass null to hash synchronously, which is
## fine for small files and wrong for large ones on the main thread.
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

	# Sync per object rather than once at the end of a sync: on web an unflushed
	# write is lost when the tab closes, and a player who closes the tab
	# mid-download should keep the objects that already finished. Re-downloading
	# is precisely what the cache exists to avoid.
	DotWeb.sync_filesystem()

	_record(sha256, size)

	DotLog.debug(
		CHANNEL,
		"object committed",
		{"hash": sha256.substr(0, 12), "size": DotPaths.format_bytes(size)}
	)

	return DotResult.success(dest)


## Writes bytes directly as an object, verifying them first.
##
## For content that arrived somewhere other than an HTTP download — the in-band
## netchan source, or a local import.
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

	# The object arrived by another route entirely, so whatever an interrupted
	# HTTP download left behind is now unreachable weight: nothing resumes a
	# partial for content that is already committed, and only sweep_partials
	# would eventually notice — a day later, having held the bytes the whole
	# time. This is the normal shape of a netchan fallback after HTTP failed
	# part-way, which is exactly when the disk is under pressure.
	discard_partial(expected_sha256)

	_record(expected_sha256, bytes.size())
	return DotResult.success(dest)


# --- References ------------------------------------------------------------

## Records that [param content_key] needs these objects.
##
## Referenced objects survive eviction. Without this, playing game B could evict
## game A's content while a player is still connected to a server that will
## switch back to it — turning a map change into a re-download.
func add_refs(content_key: String, hashes: PackedStringArray) -> void:
	for h in hashes:
		if not _index.has(h):
			continue
		var refs: Array = _index[h]["refs"]
		if not refs.has(content_key):
			refs.append(content_key)
	_index_dirty = true


## Drops a content set's claim on its objects.
##
## The objects are not deleted — they become eviction candidates. That is the
## point: unmounting a game should be instant and free, and if the player
## reconnects before the cache fills, the content is still there.
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


# --- Eviction --------------------------------------------------------------

## Whether the cache is over its ceiling.
func is_over_limit() -> bool:
	return _limit_bytes > 0 and _total_bytes > _limit_bytes


## Bytes that would need to be freed to fit [param incoming] more.
func shortfall(incoming: int = 0) -> int:
	if _limit_bytes <= 0:
		return 0
	return maxi(0, (_total_bytes + incoming) - _limit_bytes)


## Evicts unreferenced objects, least recently used first.
##
## Returns the bytes freed. Referenced objects are never evicted, so a cache
## entirely full of referenced content cannot shrink — [method prune] reports the
## shortfall it could not meet and the caller decides whether to proceed anyway or
## refuse the download. Deleting content a running game has mounted would be
## worse than either.
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


## Deletes everything, including referenced objects.
##
## For a "clear downloaded content" button. Unsafe while content is mounted:
## Godot has already read the pack's file table, so mounted paths keep resolving
## to files that no longer exist, and the failure looks like corruption. Restart
## after calling it.
func clear_all() -> DotResult:
	var removed := DotPaths.remove_tree(config.objects_dir())
	DotPaths.remove_tree(config.partials_dir())

	_index.clear()
	_total_bytes = 0
	_index_dirty = true
	flush_index()

	DotPaths.ensure_dir(config.objects_dir())
	DotPaths.ensure_dir(config.partials_dir())

	# Same reason every commit flushes: on web the filesystem is an IndexedDB
	# mirror, and a "clear downloaded content" that is never synced comes back
	# on the next load. Every other mutating path in this class syncs; this one
	# is the one where the user explicitly asked.
	DotWeb.sync_filesystem()

	DotLog.info(CHANNEL, "cache cleared")
	return removed


## Removes partials that can never be resumed into anything useful.
##
## Housekeeping for downloads interrupted by a crash. Cheap, and worth doing at
## startup: an abandoned partial is dead weight the size of the file it was.
##
## Two things make one dead. Age is the obvious one. The other is the object
## already being in the store — a partial is only ever resumed for content that
## is [i]missing[/i], so once the object is committed nothing will ever look at
## its partial again. That happens whenever a transfer falls back to a different
## source: HTTP gets half the file, fails, and the in-band source delivers the
## whole thing through [method put_bytes]. Keeping those for [param max_age_sec]
## holds the largest files in the cache twice over, and disk pressure is what
## caused the failover in the first place.
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


# --- Verification ----------------------------------------------------------

## Re-hashes every cached object and drops any that no longer match.
##
## Slow — it reads the whole cache — so it is opt-in via
## [member DotCloudConfig.verify_cache_on_start]. What it catches is storage that
## changed underneath us: a partially-evicted IndexedDB, a trimmed mobile sandbox,
## a failing disk.
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


# --- Index -----------------------------------------------------------------

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
##
## [b]The index is always behind the directory, by design.[/b] Every committed
## object is written and flushed to storage immediately — a tab closed
## mid-download must keep what already finished — but the index is only written
## at the end of a sync, at mount and at prune. So any run that ended without
## [method close] leaves a file on disk that a valid, parseable index knows
## nothing about, and the parse succeeding is precisely why [method _rebuild_index]
## never gets a chance to notice.
##
## An untracked object is worse than a missing one. [method has] finds it, so it
## is never re-downloaded and never re-recorded; [method touch] cannot stamp it;
## it is absent from [member _total_bytes], so [method shortfall] under-reports;
## and [method prune] iterates the index, so it can never be evicted. The cache
## grows past its ceiling by exactly the amount that the last unclean shutdown
## had in flight, permanently, and on a phone that ceiling is the thing keeping
## the app from being killed for disk use.
##
## One directory walk at open, which is what [method _rebuild_index] costs
## anyway whenever the index is missing, and [method sweep_partials] already
## walks the sibling directory at startup.
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
		# The browser evicted our storage, a mobile sandbox was trimmed, or a
		# user cleared it. [method has] would drop these one at a time on the
		# next lookup; doing it now is what makes _total_bytes true before the
		# first shortfall() is reported to a player.
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
##
## Possible only because the store is content-addressed: a filename is a hash, so
## the directory carries everything the index does except last-use times and
## references. Both are recoverable — refs are re-added on the next mount and
## last-use starts from now.
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


# --- Reporting -------------------------------------------------------------

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
