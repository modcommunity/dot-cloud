class_name DotCloudMounter
extends RefCounted

## Mounts downloaded content into the running project's virtual filesystem.
##
## [b]This is the hardest constraint in dot-cloud, so read this before changing
## anything here.[/b]
##
## [b]Godot cannot unmount a resource pack.[/b] There is no
## [code]unload_resource_pack[/code], on any platform, in any version. Once
## [method ProjectSettings.load_resource_pack] returns, that pack's file table is
## merged into the virtual filesystem for the lifetime of the process. The engine
## does not track which pack contributed which entry, so there is nothing to
## unwind even in principle.
##
## The brief for dot-cloud is "dynamically load and unload games while users are
## connected". Given the above, the naive implementation — mount game A at
## [code]res://game/[/code], later mount game B at the same paths with
## [code]replace_files = true[/code] — is broken in a way that only shows up
## later:
##
## - Files that existed in A and not in B [b]still resolve[/b], to A's bytes.
##   A stale [code]res://game/config.tres[/code] silently loads into B.
## - Godot's resource cache may hand back A's already-loaded instance for a path
##   B also defines, depending on whether anything still holds a reference.
## - Nothing errors. The game just behaves as a blend of two content sets.
##
## [b]So dot-cloud does not reuse paths.[/b] Content mounts at
## [code]res://<mount_root>/<content_id>/<version>/[/code] — the version is in the
## path — and "unloading" means:
##
## 1. tear down the scene tree that referenced it — this is the step that
##    actually frees the resources, because Godot's resource cache holds no
##    reference of its own and empties itself when the last one drops,
## 2. check that step 1 was complete ([method purge_resources], which reports
##    what is still referenced and cannot evict anything — see its doc),
## 3. release the store's refs so the objects become evictable,
## 4. forget the mount and never look at those paths again.
##
## The file-table entries linger. That costs a few kilobytes per mount and
## nothing else, because no code and no path ever points at them again. A server
## cycling through fifty maps in a session accumulates fifty namespaces of dead
## file-table entries, which is a rounding error against one texture.
##
## [method needs_restart_to_reclaim] and [method restart_process] exist for the
## rare case where that genuinely is not acceptable.

const CHANNEL := "cloud.mount"

var config: DotCloudConfig

## content_key -> {manifest, prefix, mounted_at, files}
var _mounts: Dictionary = {}


func _init(p_config: DotCloudConfig) -> void:
	config = p_config


# --- Mounting --------------------------------------------------------------

## Builds a pack from cached objects and mounts it.
##
## The cache stores objects by hash, but Godot mounts *packs*, so this writes a
## thin PCK whose entries point content paths at the cached bytes. That pack is
## itself cached under the manifest key, so re-mounting the same content on a
## later run is one [method ProjectSettings.load_resource_pack] call.
##
## [param store] must already hold every required object — run the downloader
## first.
func mount(
	manifest: DotCloudManifest,
	store: DotCloudStore,
	scheduler: DotScheduler = null
) -> DotResult:
	var key := manifest.key()

	if _mounts.has(key):
		DotLog.debug(CHANNEL, "already mounted", {"content": key})
		return DotResult.success(manifest.mount_prefix())

	var engine_check := manifest.validate()
	if not engine_check.ok:
		return engine_check

	var wanted := manifest.wanted_files()

	# Everything required must be present before a single file is mounted. A
	# half-mounted game is worse than an unmounted one: it loads, and then fails
	# somewhere unrelated to the missing file.
	var missing := PackedStringArray()
	for f in wanted:
		if f.required and not store.has(f.sha256):
			missing.append(f.path)

	if not missing.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE,
			"Content is not fully downloaded.",
			"%d file(s) missing, first: %s" % [missing.size(), missing[0]]
		)

	if config.verify_before_mount and scheduler != null:
		var verified := await _verify_objects(wanted, store, scheduler)
		if not verified.ok:
			return verified

	var pack_path := _pack_path(manifest)

	var built := _build_pack(manifest, store, wanted, pack_path)
	if not built.ok:
		return built

	var prefix := manifest.mount_prefix()

	# replace_files stays false. With version-namespaced prefixes nothing needs
	# replacing, and enabling it would let downloaded content shadow files the
	# host project shipped — including its scripts.
	var ok := ProjectSettings.load_resource_pack(
		pack_path, config.allow_replace_files
	)

	if not ok:
		return DotResult.fail(
			DotError.CODE_IO,
			"The engine refused to mount the content pack.",
			pack_path
		)

	if config.enforce_mount_prefix:
		var escaped := _check_prefix(manifest, wanted)
		if not escaped.ok:
			# Too late to undo — this is the belt to safe_relative's braces, and
			# reaching it means a bug upstream. Report loudly; the process should
			# be treated as compromised.
			DotLog.error(
				CHANNEL,
				"content mounted outside its prefix — this is a bug",
				{"content": key, "detail": escaped.error.detail}
			)
			return escaped

	_mounts[key] = {
		"manifest": manifest,
		"prefix": prefix,
		"pack": pack_path,
		"mounted_at": Time.get_ticks_msec(),
		"files": wanted.size(),
	}

	store.add_refs(key, manifest.unique_hashes())
	store.flush_index()

	DotLog.info(
		CHANNEL,
		"mounted",
		{"content": key, "prefix": prefix, "files": wanted.size()}
	)

	return DotResult.success(prefix)


## Writes a PCK mapping manifest paths to cached object bytes.
##
## [PCKPacker] takes a target path per file, which is exactly what is needed:
## the cached object lives at a hash-named path and has to appear inside the pack
## at [code]res://<prefix>/<manifest path>[/code]. No export preset can express
## that, which is why the pack is assembled here rather than shipped.
func _build_pack(
	manifest: DotCloudManifest,
	store: DotCloudStore,
	files: Array[DotCloudFile],
	pack_path: String
) -> DotResult:
	# A pack already built for this exact content is byte-identical: both the
	# prefix (id + version) and every object hash are fixed. Rebuilding it would
	# be pure waste on every subsequent launch.
	if FileAccess.file_exists(pack_path):
		DotLog.debug(
			CHANNEL, "reusing cached pack", {"pack": pack_path.get_file()}
		)
		return DotResult.success(pack_path)

	var parent := DotPaths.ensure_parent_dir(pack_path)
	if not parent.ok:
		return parent

	var packer := PCKPacker.new()
	var err := packer.pck_start(pack_path)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "creating pack '%s'" % pack_path)
		)

	var prefix := manifest.mount_prefix()
	var added := 0

	for f in files:
		if not store.has(f.sha256):
			# Optional and absent. Skipped rather than failed — required files
			# were checked before we got here.
			continue

		var target := prefix.path_join(f.path)
		var source := store.path_for(f.sha256)

		err = packer.add_file(target, source)
		if err != OK:
			return DotResult.failure(
				DotError.from_engine(err, "adding '%s' to the pack" % f.path)
			)
		added += 1

	err = packer.flush(false)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "writing pack '%s'" % pack_path)
		)

	DotWeb.sync_filesystem()

	DotLog.debug(
		CHANNEL,
		"built pack",
		{
			"pack": pack_path.get_file(),
			"files": added,
			"size": DotPaths.format_bytes(DotPaths.file_size(pack_path)),
		}
	)

	return DotResult.success(pack_path)


func _pack_path(manifest: DotCloudManifest) -> String:
	# The version is in the filename as well as the mount prefix, so publishing a
	# new version never overwrites the pack a running process has open — which on
	# Windows would fail outright, and elsewhere would corrupt it.
	return config.cache_dir.path_join(
		"packs/%s-%s.pck" % [
			DotPaths.slugify(manifest.content_id),
			DotPaths.slugify(manifest.version),
		]
	)


func _verify_objects(
	files: Array[DotCloudFile],
	store: DotCloudStore,
	scheduler: DotScheduler
) -> DotResult:
	var seen := {}

	for f in files:
		if seen.has(f.sha256):
			continue
		seen[f.sha256] = true

		if not store.has(f.sha256):
			continue

		var res := await scheduler.run(
			DotHashJob.new(store.path_for(f.sha256), f.sha256)
		)

		if not res.ok:
			return res.wrap(
				"Cached content for '%s' failed verification." % f.path
			)

	return DotResult.success(seen.size())


## Confirms every mounted path is inside the manifest's prefix and resolvable.
func _check_prefix(
	manifest: DotCloudManifest,
	files: Array[DotCloudFile]
) -> DotResult:
	var prefix := manifest.mount_prefix()

	# Simplified on both sides before comparing. A raw begins_with() is not a
	# containment test: "res://a/b/../../evil" begins with "res://a/b/" and is
	# nowhere near it, so the belt would have agreed with anything the braces
	# let through — which is the opposite of what a second check is for.
	var simple_prefix := prefix.simplify_path()

	for f in files:
		var path := prefix.path_join(f.path).simplify_path()

		if not path.begins_with(simple_prefix + "/"):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Content escaped its mount prefix.",
				"%s is outside %s" % [path, prefix]
			)

		if f.required and not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
			return DotResult.fail(
				DotError.CODE_IO,
				"A required file is not readable after mounting.",
				path
			)

	return DotResult.success(true)


# --- Unmounting ------------------------------------------------------------

## Forgets a mount and releases its cache references.
##
## [b]Does not remove the pack from the virtual filesystem[/b] — the engine has no
## such operation, see the class documentation. What it does is make the content
## unreachable in every way that matters: the caller has torn down the scene tree,
## this drops the resource-cache references and the store's refs, and nothing
## points at those paths again.
##
## The caller must free anything still holding a resource from this content
## [b]before[/b] calling. A [Node] holding a [Mesh] from the pack keeps it alive
## in the resource cache, and the next mount of the same version would hand back
## the stale instance.
func unmount(content_key: String, store: DotCloudStore) -> DotResult:
	if not _mounts.has(content_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "Not mounted.", content_key
		)

	var entry: Dictionary = _mounts[content_key]
	var prefix: String = entry["prefix"]

	# Not "purged" — see purge_resources. This is what the caller still holds.
	var still_cached := purge_resources(prefix)

	store.release_refs(content_key)
	store.flush_index()

	_mounts.erase(content_key)

	DotLog.info(
		CHANNEL,
		"unmounted",
		{
			"content": content_key,
			"still_cached": still_cached,
			"note": "pack file table remains in memory; paths are now unused",
		}
	)

	return DotResult.success(still_cached)


## Counts cached resources still live under [param prefix], and warns about them.
##
## [b]This cannot evict anything, and the version that claimed to did not.[/b]
## Godot's resource cache holds no strong reference of its own: a [Resource]
## registers itself on load and unregisters in its destructor, so a path is in
## the cache exactly while something else still refers to it. Verified in
## 4.4.1 — drop every reference and [method ResourceLoader.has_cached] goes
## false on its own, with nothing called to make it.
##
## So there is no eviction to perform here, and no script-exposed way to force
## one. The previous implementation called
## [code]load(path, "", CACHE_MODE_IGNORE)[/code] and counted the successes,
## with a comment claiming that made the cache release its reference. It does
## not: CACHE_MODE_IGNORE returns a brand-new instance and leaves the cached one
## exactly where it was. The count was the number of resources re-read from disk
## and thrown away — so [method unmount] logged [code]purged=4[/code] having
## purged nothing, and paid for a full duplicate load of the content to say it.
##
## What is left is the useful half: a non-zero return means the caller did
## [b]not[/b] free everything before unmounting, which is the one thing that
## actually breaks a re-mount of this version (it hands back the stale
## instance). Treat it as a leak report, not as work done.
func purge_resources(prefix: String) -> int:
	var still_cached := 0

	# has_cached is the only cache query exposed to script, and there is no
	# "evict by prefix" at all, so this walks the mount's own file list.
	for key in _mounts:
		var entry: Dictionary = _mounts[key]
		if str(entry["prefix"]) != prefix:
			continue

		var manifest: DotCloudManifest = entry["manifest"]
		for f in manifest.files:
			if ResourceLoader.has_cached(prefix.path_join(f.path)):
				still_cached += 1

	if still_cached > 0:
		DotLog.warn(
			CHANNEL,
			"content is still referenced after unmount; free those nodes first",
			{"prefix": prefix, "still_cached": still_cached}
		)

	return still_cached


## Whether anything has been mounted that a restart would reclaim.
##
## For a UI that offers "restart to free up memory". Almost never worth showing:
## the leak is file-table entries, measured in kilobytes.
func needs_restart_to_reclaim() -> bool:
	return not _mounts.is_empty() and not DotPlatform.can_unmount_packs()


## Restarts the process to get a clean virtual filesystem.
##
## The only true unmount. Desktop re-execs, a browser tab reloads, mobile cannot
## do either — [method DotPlatform.can_self_restart] says which.
##
## An escape hatch, not part of the normal flow. Needing it means content is being
## mounted at colliding paths, which version namespacing is there to prevent.
func restart_process() -> DotResult:
	if not DotPlatform.can_self_restart():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This platform cannot restart itself.",
			"the player must relaunch the app"
		)

	DotLog.info(CHANNEL, "restarting to reclaim mounted packs")

	if DotPlatform.is_web():
		DotWeb.sync_filesystem()
		DotWeb.eval("window.location.reload()", true)
		return DotResult.success(true)

	var exe := OS.get_executable_path()
	var args := OS.get_cmdline_args()

	var pid := OS.create_process(exe, args)
	if pid <= 0:
		return DotResult.fail(
			DotError.CODE_INTERNAL, "Could not start a new process."
		)

	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).quit()

	return DotResult.success(pid)


# --- Queries ---------------------------------------------------------------

func is_mounted(content_key: String) -> bool:
	return _mounts.has(content_key)


func mount_prefix_of(content_key: String) -> String:
	if not _mounts.has(content_key):
		return ""
	return str(_mounts[content_key]["prefix"])


func mounted_keys() -> PackedStringArray:
	var out := PackedStringArray(_mounts.keys())
	out.sort()
	return out


## The entry scene of a mounted content set, ready to instantiate.
func entry_scene_of(content_key: String) -> DotResult:
	if not _mounts.has(content_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "Not mounted.", content_key
		)

	var manifest: DotCloudManifest = _mounts[content_key]["manifest"]
	var path := manifest.entry_scene_path()

	if path == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"This content declares no entry scene.",
			content_key
		)

	if not ResourceLoader.exists(path):
		return DotResult.fail(
			DotError.CODE_IO,
			"The entry scene is missing from the mounted content.",
			path
		)

	return DotResult.success(path)


func describe() -> Dictionary:
	var mounts := []
	for key in mounted_keys():
		var e: Dictionary = _mounts[key]
		mounts.append({
			"content": key,
			"prefix": e["prefix"],
			"files": e["files"],
		})

	return {
		"mounted": mounts,
		"can_unmount": DotPlatform.can_unmount_packs(),
		"can_restart": DotPlatform.can_self_restart(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if _mounts.is_empty():
		out.append("nothing mounted")
		return out

	for key in mounted_keys():
		var e: Dictionary = _mounts[key]
		out.append("%-28s %-4d %s" % [key, int(e["files"]), e["prefix"]])
	return out
