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

## [code]options.uid_policy[/code]: only add ids the process does not know yet.
const UID_ADD_ONLY := "add_only"

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
	scheduler: DotScheduler = null,
	options: Dictionary = {}
) -> DotResult:
	var engine_check := manifest.validate()
	if not engine_check.ok:
		return engine_check

	var key := manifest.key()
	var wanted := manifest.wanted_files()
	var identity := _mount_identity(manifest, wanted)

	# [b]The key is not proof that the content is the same.[/b] `key()` is
	# `content_id@version` and nothing in it is derived from the bytes, so two
	# manifests from two publishers -- or one publisher who re-used a version
	# number -- arrive here indistinguishable. Returning the mounted prefix for
	# whichever got here first means the caller asked for one content set and
	# quietly got another, and since a pack can contain scripts, "another" is
	# somebody else's code.
	#
	# It cannot be repaired after the fact either: the first pack is already
	# merged into the virtual filesystem and there is no unmount, so the only
	# honest answer is to refuse the second and let the caller decide.
	if _mounts.has(key):
		var held: Dictionary = _mounts[key]

		# [b]The same content asked for with more files than were mounted[/b] (API 8): a
		# shell that joined a server as a client and then hosts the same game itself wants
		# the server-only files too, and the pack cannot be unmounted and remounted. The
		# difference is mounted as a second pack at the same prefix; nothing already there
		# is replaced. A narrower ask of the same content is already covered.
		if str(held.get("identity", "")) != identity \
				and str(held.get("whole", "")) == _mount_identity(manifest, manifest.files):
			return await _mount_more(manifest, store, scheduler, options, wanted, held)

		if str(held.get("identity", "")) != identity:
			return DotResult.fail(
				DotError.CODE_CONFLICT,
				"Different content is already mounted under this id and version.",
				("mounted %s, asked for %s -- bump the version, or namespace the "
					+ "content_id, because this one is taken for the life of the "
					+ "process") % [str(held.get("identity", "")), identity]
			)

		DotLog.debug(CHANNEL, "already mounted", {"content": key})
		return DotResult.success(str(held["prefix"]))

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

	var pack_path := _pack_path(manifest, wanted)

	# A pack already built is what gets mounted, and it was assembled from objects verified when
	# they were committed. Re-hashing every object on each refresh cost seconds of a tab's main
	# thread (no worker threads on web) to re-prove what the pack's name already fingerprints.
	var pack_cached := FileAccess.file_exists(pack_path)
	if config.verify_before_mount and scheduler != null and not pack_cached:
		var verified := await _verify_objects(wanted, store, scheduler)
		if not verified.ok:
			return verified

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

	var uid_skips := [0]
	var uids := _register_uids(
		wanted, prefix, manifest.mount_root,
		str(options.get("uid_policy", "")) == UID_ADD_ONLY, manifest.content_id, uid_skips
	)

	var paths := {}
	for f in wanted:
		paths[f.path] = true

	_mounts[key] = {
		"manifest": manifest,
		"identity": identity,
		"whole": _mount_identity(manifest, manifest.files),
		"paths": paths,
		"prefix": prefix,
		"pack": pack_path,
		"mounted_at": Time.get_ticks_msec(),
		"files": wanted.size(),
		"uids": uids,
		"uids_skipped": int(uid_skips[0]),
	}

	store.add_refs(key, manifest.unique_hashes())
	store.flush_index()

	DotLog.info(
		CHANNEL,
		"mounted",
		{
			"content": key, "prefix": prefix, "files": wanted.size(), "uids": uids,
			"uids_skipped": int(uid_skips[0]),
		}
	)

	return DotResult.success(prefix)


## Whether [param manifest] is mounted with every file it now wants: false when the same
## content was mounted for a narrower side or group set, so [method mount] would add the
## rest. Different content under the key reads as covered, as it always has: [method mount]
## is where that is refused.
func covers(manifest: DotCloudManifest) -> bool:
	var held: Dictionary = _mounts.get(manifest.key(), {})
	if held.is_empty():
		return false
	if str(held.get("whole", "")) != _mount_identity(manifest, manifest.files):
		return true
	var paths: Dictionary = held.get("paths", {})
	for f in manifest.wanted_files():
		if not paths.has(f.path):
			return false
	return true


## The files [param wanted] has that the mount in [param held] lacks, as a second pack at the
## same prefix. The checks are [method mount]'s, applied to the difference.
func _mount_more(
	manifest: DotCloudManifest,
	store: DotCloudStore,
	scheduler: DotScheduler,
	options: Dictionary,
	wanted: Array[DotCloudFile],
	held: Dictionary
) -> DotResult:
	var key := manifest.key()
	var paths: Dictionary = held.get("paths", {})
	var extra: Array[DotCloudFile] = []
	for f in wanted:
		if not paths.has(f.path):
			extra.append(f)

	if extra.is_empty():
		return DotResult.success(str(held["prefix"]))

	for f in extra:
		if f.required and not store.has(f.sha256):
			return DotResult.fail(
				DotError.CODE_STATE, "Content is not fully downloaded.", "first missing: %s" % f.path
			)

	if config.verify_before_mount and scheduler != null:
		var verified := await _verify_objects(extra, store, scheduler)
		if not verified.ok:
			return verified

	var pack_path := _pack_path(manifest, extra)
	var built := _build_pack(manifest, store, extra, pack_path)
	if not built.ok:
		return built

	if not ProjectSettings.load_resource_pack(pack_path, config.allow_replace_files):
		return DotResult.fail(
			DotError.CODE_IO, "The engine refused to mount the content pack.", pack_path
		)

	if config.enforce_mount_prefix:
		var escaped := _check_prefix(manifest, extra)
		if not escaped.ok:
			DotLog.error(
				CHANNEL,
				"content mounted outside its prefix — this is a bug",
				{"content": key, "detail": escaped.error.detail}
			)
			return escaped

	var uid_skips := [0]
	var uids := _register_uids(
		extra, str(held["prefix"]), manifest.mount_root,
		str(options.get("uid_policy", "")) == UID_ADD_ONLY, manifest.content_id, uid_skips
	)

	for f in extra:
		paths[f.path] = true
	held["paths"] = paths
	held["files"] = paths.size()
	held["uids"] = int(held.get("uids", 0)) + uids

	DotLog.info(
		CHANNEL,
		"mounted more of it",
		{"content": key, "added": extra.size(), "files": paths.size(), "uids": uids}
	)
	return DotResult.success(str(held["prefix"]))


## Points every UID this pack declares at the file inside the mount.
##
## [b]An imported asset carries a dependency this addon cannot rewrite, and until this
## existed nothing could load one.[/b] The publisher rewrites `res://` strings inside TEXT
## resources and says so; a `.glb`, a `.png` or anything else the engine imports becomes a
## BINARY `.scn`/`.ctex` under `.godot/imported/`, and its references to its own siblings
## are recorded as a UID with the authored path as a fallback. Neither survives being
## mounted somewhere else: the UID is not registered in the host, so the loader falls back
## to the path — and the path names the project the asset was authored in.
##
## [codeblock]
## invalid UID: 'uid://reboanwombd2' - using text path instead:
##     'res://assets/kenney/survival/Textures/colormap.png'
## Resource file not found: res://assets/kenney/survival/Textures/colormap.png
## [/codeblock]
##
## Measured in game-buses-from-hell, the first game in this family to vendor art: the
## crates' meshes loaded, their texture did not, and the scene node the model was
## instanced under "vanished" — a game that plays perfectly and appears to have shipped
## with no art. [b]Nothing reported it as an error[/b]; both lines above are warnings, and
## the pack, the mount and the scene load all succeeded.
##
## The fix is the half the engine leaves to the host: `ResourceUID` is writable at
## runtime, and every import marker in the pack names both a UID and the file it belongs
## to. So on mount, each one is pointed at the mounted copy, and the binary form's own
## reference resolves — with no rewriting of bytes anywhere.
##
## [b]A pack may claim a UID nothing else owns, and may not TAKE one.[/b] `ResourceUID` is
## global to the process, so registering an id the host already uses would re-point every
## `load("uid://…")` in the build at a file inside downloaded content — an addon's script,
## a shell's scene — which is a mounted pack reaching outside its own prefix by another
## route. That is the thing `enforce_mount_prefix` exists to stop, so the same rule applies
## here: an id whose current path is outside any mount is refused and reported, and one
## that points into content (this pack, or an earlier version of it) is updated.
##
## Returns how many were registered, for the mount's log line.
##
## [b]`add_only` (a subscription's mount) is stricter still.[/b] The rule above lets an id
## move when it points into any mounted content, which is right for a second version of the
## same pack and wrong for a stranger's pack that happens to reuse an id of a game pack or a
## server's map: it would re-point that content for the rest of the process, online sessions
## included. So under `add_only` an id already registered to a path outside THIS content id's
## own mounts is skipped and counted in [param skipped], and only unknown ids are added.
func _register_uids(
	files: Array[DotCloudFile],
	prefix: String,
	mount_root: String,
	add_only: bool = false,
	content_id: String = "",
	skipped: Array = []
) -> int:
	var registered := 0
	var refused := 0
	var content_root := "res://%s/" % mount_root

	for f in files:
		if not f.path.to_lower().ends_with(".import"):
			continue

		var marker := prefix.path_join(f.path)
		var text := FileAccess.get_file_as_string(marker)

		if text == "":
			continue

		var uid_text := _uid_in(text)

		if uid_text == "":
			continue

		var id := ResourceUID.text_to_id(uid_text)

		if id == ResourceUID.INVALID_ID:
			continue

		# [b]The SOURCE file, not the imported output.[/b] An import marker's `uid` is the
		# identity of the thing a scene refers to — `res://…/colormap.png` — and the
		# engine resolves that id and then follows the marker beside it to the imported
		# bytes. Registering the `.scn` instead would hand back an imported resource where
		# a texture was asked for.
		var source := marker.trim_suffix(".import")

		if not ResourceLoader.exists(source) and not FileAccess.file_exists(source):
			continue

		# `set_id` when the host already knows the id and `add_id` when it does not: the
		# two are separate calls and the wrong one is an error rather than an update. A
		# host that mounted an earlier version of the same pack knows it — and that is the
		# ONLY case an existing id may be moved, per the note above.
		if ResourceUID.has_id(id):
			var held := ResourceUID.get_id_path(id)

			if add_only and not held.begins_with("%s%s/" % [content_root, content_id]):
				skipped[0] = int(skipped[0]) + 1
				continue

			if not held.begins_with(content_root):
				DotLog.warn(CHANNEL, "a pack claims a uid the host already owns; refused", {
					"uid": uid_text, "held": held, "wanted": source,
				})
				refused += 1
				continue

			ResourceUID.set_id(id, source)
		else:
			ResourceUID.add_id(id, source)

		registered += 1

	if refused > 0:
		DotLog.error(CHANNEL, "a pack tried to take uids that are not its own", {
			"refused": refused, "prefix": prefix,
		})

	return registered


## The `uid="uid://…"` line of an import marker, or empty.
static func _uid_in(text: String) -> String:
	for line in text.split("\n"):
		var trimmed := line.strip_edges()

		if not trimmed.begins_with("uid="):
			continue

		return trimmed.substr(4).strip_edges().trim_prefix("\"").trim_suffix("\"")

	return ""


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
	# A pack already built for this exact content is byte-identical, and now the path
	# says so: [method _pack_path] fingerprints the file list, so reuse here means the
	# same paths mapped to the same hashes. It used to mean only the same id and version,
	# which is a claim about the publisher's discipline rather than about these bytes --
	# and republishing one version from a corrected source is how a game gets fixed.
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


func _pack_path(manifest: DotCloudManifest, files: Array[DotCloudFile]) -> String:
	# Version and a fingerprint of the CONTENT are in the name: republishing `id@0.1.0` from corrected
	# sources is the ordinary fix loop, and a path without the fingerprint kept serving the old pack. The
	# version also stops a new publish overwriting a pack a running process has open (fatal on Windows).
	# [param files] is the wanted set, so two group selections of one id@version must not share a path.
	return config.cache_dir.path_join(
		"packs/%s-%s-%s.pck" % [
			DotPaths.slugify(manifest.content_id),
			DotPaths.slugify(manifest.version),
			_pack_fingerprint(manifest, files),
		]
	)


## What the assembled pack will contain, as a short stable digest.
##
## Path AND hash, so a file that moved and a file that changed are both a different
## pack. Sorted, because the manifest's order is the publisher's and two publishes of
## identical content must agree.
## What has to match for an already-mounted key to be the same content.
##
## The file set is the bulk of it, and [method _pack_fingerprint] already answers
## that. [member DotCloudManifest.entry_scene] and
## [member DotCloudManifest.mount_root] are in here as well because neither is a
## file: two manifests can agree about every byte and still disagree about what
## loads and where it lands, and the caller would be handed the first one's answer
## for both.
func _mount_identity(manifest: DotCloudManifest, files: Array[DotCloudFile]) -> String:
	return "%s|%s|%s" % [
		_pack_fingerprint(manifest, files),
		manifest.entry_scene,
		manifest.mount_root,
	]


func _pack_fingerprint(manifest: DotCloudManifest, files: Array[DotCloudFile]) -> String:
	var lines := PackedStringArray()

	for f in files:
		lines.append("%s:%s" % [f.path, f.sha256])

	lines.sort()

	# [b]The id and the version are part of the fingerprint, not just of the name.[/b]
	# A built pack holds its files at `res://<mount_root>/<id>/<version>/...`, so it is
	# only ever valid for the identity it was built for -- and the filename alone stopped
	# saying which as soon as a content_id could contain "/", because the name slugifies
	# it and `alice/x` and `alice_x` slugify alike. Two different packs would then agree
	# about their path and the wrong one would be mounted, which is section 6's bug
	# arriving through a different door.
	return DotHash.sha256_text(
		"%s\n%s\n%s" % [manifest.content_id, manifest.version, "\n".join(lines)]
	).substr(0, 16)


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
## This cannot evict anything: the resource cache holds no strong reference, so a path is cached exactly
## while something else refers to it, and `CACHE_MODE_IGNORE` only returns a new instance. A non-zero
## return means the caller did [b]not[/b] free everything before unmounting, which breaks a re-mount.
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


## The `cfg` root a mounted pack ships (`<prefix>/cfg`), or "" when it has none or is not mounted.
## A reader puts it first in its config roots (weakest), so `cfg/server` and the game still win.
func cfg_root_of(content_key: String) -> String:
	var root := mount_prefix_of(content_key).path_join("cfg")
	return root if mount_prefix_of(content_key) != "" and DirAccess.dir_exists_absolute(root) else ""


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
			# How many of this pack's own uids were registered. A number lower than the
			# `.import` markers it carries means some were refused for belonging to
			# somebody else — see [method _register_uids].
			"uids": e.get("uids", 0),
			"uids_skipped": e.get("uids_skipped", 0),
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
