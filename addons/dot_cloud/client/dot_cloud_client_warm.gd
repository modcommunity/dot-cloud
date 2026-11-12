extends RefCounted

## The script warming of [DotCloudClient] ([method DotCloudClient.warm_content] and the class prewarm), in a
## file of their own so the client stays inside the size budget. Nothing here is used on its own.

const CHANNEL := "cloud"

## Project settings (all optional): msec of script compiling per frame under the cover, msec the cover may wait
## (0 = until every script is warmed), msec per frame for scripts left after that, and extra directories to skip.
const SET_BUDGET := "dot_cloud/warm/budget_msec"
const SET_BLOCKING := "dot_cloud/warm/blocking_msec"
const SET_TAIL_BUDGET := "dot_cloud/warm/background_budget_msec"
const SET_SKIP := "dot_cloud/warm/skip_dirs"


## True for a file under a tooling directory at any depth: a pack ships `addons/<x>/examples/`, whose scripts do not parse in a running game.
static func _skipped(path: String) -> bool:
	var parts := path.split("/")
	for i in parts.size() - 1:
		if DotCloudClient.WARM_SKIP_DIRS.has(parts[i]) or (ProjectSettings.get_setting(SET_SKIP, PackedStringArray()) as PackedStringArray).has(parts[i]):
			return true
	return false


## The addon classes a pack names, compiled while its big objects still download.
static func prewarm_classes(c: DotCloudClient, manifest: DotCloudManifest) -> void:
	if DotPlatform.has_threads() or c._prewarming or not c.is_inside_tree():
		return
	var names := PackedStringArray()
	var files := PackedStringArray()
	for file in manifest.files:
		if file.path.get_extension() != "gd" or _skipped(file.path):
			continue
		var object := c.store.path_for(file.sha256)
		if FileAccess.file_exists(object):
			names.append(file.path)
			files.append(object)
	c._prewarming = true
	c._prewarm = DotCloudSliceLoader.new()
	var t0 := Time.get_ticks_msec()
	var classes := DotCloudSliceLoader.named_class_scripts(names, files)
	var res := await c._prewarm.load_all(c.get_tree(), classes, false)
	DotLog.info(CHANNEL, "addon classes prewarmed", {
		"classes": classes.size(), "left_to_warm": c._prewarm.remaining.size(), "ms": Time.get_ticks_msec() - t0, "ok": res.ok,
	})
	c._prewarming = false
	c._prewarm_done.emit()


## See [method DotCloudClient.warm_content].
static func warm_content(c: DotCloudClient, tree: SceneTree, keys: PackedStringArray, force: bool, on_progress: Callable) -> DotCloudSliceLoader:
	var loader := DotCloudSliceLoader.new()
	if on_progress.is_valid():
		loader.progress.connect(func(done: int, total: int, _path: String) -> void: on_progress.call(done, total))
	if DotPlatform.has_threads() and not force:
		return loader

	var scripts := PackedStringArray()
	var seen := {}
	for key in keys:
		var manifest := c.manifest_for(key)
		if manifest == null:
			continue
		for file in manifest.files:
			# Tooling and examples are never loaded by a running game; warming them cost ~12 s of a join.
			if _skipped(file.path):
				continue
			var path := manifest.resource_path(file)
			# A tokenized script ships as x.gdc behind x.gd.remap; load the .gd path either way.
			if path.get_extension() == "gdc":
				path = path.trim_suffix("c")
			if path.get_extension() == "gd" and ResourceLoader.exists(path) and not seen.has(path) and not ResourceLoader.has_cached(path):
				seen[path] = true
				scripts.append(path)

	# Take over from the class prewarm instead of idling while it finishes (~9 s of a web join): stop it after
	# its current slice; named_class_scripts below skips what it compiled and queues what it had not reached.
	if c._prewarming and c._prewarm != null:
		c._prewarm.stop_requested = true
	while c._prewarming:
		await c._prewarm_done
	var t0 := Time.get_ticks_msec()
	var named := DotCloudSliceLoader.named_class_scripts(scripts)
	var scan_ms := Time.get_ticks_msec() - t0
	# Under the cover the frame can be long (it only animates a bar); the default 16 ms yields twice as often for nothing.
	loader.budget_msec = int(ProjectSettings.get_setting(SET_BUDGET, 40))
	loader.deadline_msec = int(ProjectSettings.get_setting(SET_BLOCKING, 0))
	var res := await loader.load_all(tree, named + scripts, false)
	var deferred := loader.remaining.size()
	if deferred > 0:
		loader.load_rest(tree, int(ProjectSettings.get_setting(SET_TAIL_BUDGET, 3)))

	DotLog.info(CHANNEL, "scripts warmed", {
		"content": ",".join(keys), "pack_scripts": scripts.size(), "addon_classes": named.size(),
		"scan_ms": scan_ms, "ms": Time.get_ticks_msec() - t0, "frames": loader.frames_yielded,
		"deferred": deferred, "ok": res.ok, "why": "" if res.ok else str(res.error),
	})
	# Which scripts cost the join its seconds; read at DEBUG so a slow web join can be diagnosed from its log.
	for entry in loader.slowest:
		DotLog.debug(CHANNEL, "slow script", {"ms": entry[0], "path": entry[1]})
	return loader
