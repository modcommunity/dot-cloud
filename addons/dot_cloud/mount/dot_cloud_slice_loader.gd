class_name DotCloudSliceLoader
extends RefCounted

## Loads a list of resources a few at a time across frames, so a loading cover keeps animating.

## Emitted after each resource; drive the cover's bar from it.
signal progress(done: int, total: int, path: String)

## Longest a frame may spend loading before it yields, when not threaded.
var budget_msec: int = 8

## Frames that passed while the last load_all ran.
var frames_yielded: int = 0

## What the last load_all loaded. Held so the cache keeps it: a resource nobody references
## leaves the cache, and the load() this loader was meant to speed up would do it again.
var loaded: Array[Resource] = []


## Loads every path, yielding between slices. Threaded where [param threaded] says so (default:
## the platform can); a browser without threads loads on the main thread, a slice per frame.
## Returns success(count) or the first failing path.
func load_all(tree: SceneTree, paths: PackedStringArray, threaded: bool = DotPlatform.has_threads()) -> DotResult:
	frames_yielded = 0
	loaded.clear()
	var total := paths.size()

	if threaded:
		return await _load_threaded(tree, paths)

	var done := 0
	var slice_start := Time.get_ticks_msec()

	for path in paths:
		var res: Resource = load(path) if ResourceLoader.exists(path) else null
		if res == null:
			return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

		loaded.append(res)
		done += 1
		progress.emit(done, total, path)

		if Time.get_ticks_msec() - slice_start >= budget_msec:
			frames_yielded += 1
			await tree.process_frame
			slice_start = Time.get_ticks_msec()

	return DotResult.success(done)


func _load_threaded(tree: SceneTree, paths: PackedStringArray) -> DotResult:
	var pending: Array[String] = []

	for path in paths:
		if not ResourceLoader.exists(path):
			return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

		if ResourceLoader.load_threaded_request(path) == OK:
			pending.append(path)
			continue

		var res: Resource = load(path)
		if res == null:
			return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)
		loaded.append(res)

	var done := paths.size() - pending.size()

	while not pending.is_empty():
		var still: Array[String] = []

		for path in pending:
			match ResourceLoader.load_threaded_get_status(path):
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					still.append(path)
				ResourceLoader.THREAD_LOAD_LOADED:
					loaded.append(ResourceLoader.load_threaded_get(path))
					done += 1
					progress.emit(done, paths.size(), path)
				_:
					return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

		pending = still

		if not pending.is_empty():
			frames_yielded += 1
			await tree.process_frame

	return DotResult.success(done)


## The global-class scripts that the sources at [param paths] name, not yet cached, in
## class-list order. Load them before [param paths]: compiling one pack script otherwise
## compiles every addon class it names in the same frame (244 of them, 3.2 s, in a browser).
static func named_class_scripts(paths: PackedStringArray) -> PackedStringArray:
	var classes := ProjectSettings.get_global_class_list()
	var by_name := {}
	for entry in classes:
		by_name[str(entry["class"])] = str(entry["path"])

	var own := {}
	for path in paths:
		own[path] = true

	var named := {}
	var words := RegEx.create_from_string("\\b[A-Z][A-Za-z0-9_]+\\b")
	for path in paths:
		for found in words.search_all(FileAccess.get_file_as_string(path)):
			var script_path: String = by_name.get(found.get_string(), "")
			if script_path != "" and not own.has(script_path):
				named[script_path] = true

	var out := PackedStringArray()
	for entry in classes:
		var script_path := str(entry["path"])
		if named.has(script_path) and not ResourceLoader.has_cached(script_path):
			out.append(script_path)
	return out
