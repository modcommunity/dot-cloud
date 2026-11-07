class_name DotCloudSliceLoader
extends RefCounted

## Loads a list of resources a few at a time across frames, so a loading cover keeps animating.

## Emitted after each resource; drive the cover's bar from it.
signal progress(done: int, total: int, path: String)

## Longest a frame may spend loading before it yields, when not threaded.
var budget_msec: int = 16

## When above 0, [method load_all] stops after this many msec of loading and leaves the rest in [member remaining],
## for [method load_rest] to finish at a small per-frame cost once the cover is down.
var deadline_msec: int = 0

## Paths [method load_all] left unloaded because [member deadline_msec] ran out.
var remaining: PackedStringArray = PackedStringArray()

## When above 0, a frame loads at most this many resources before it yields, whatever the time budget says.
var max_per_frame: int = 0

## Most resources loaded in one frame, and the longest span of loading in one frame (msec), by the last non-threaded load_all.
## A single load() cannot be split, so peak_frame_msec is bounded below by the slowest resource.
var peak_per_frame: int = 0
var peak_frame_msec: int = 0

## Frames that passed while the last load_all ran.
var frames_yielded: int = 0

## What the last load_all loaded. Held so the cache keeps it: a resource nobody references
## leaves the cache, and the load() this loader was meant to speed up would do it again.
var loaded: Array[Resource] = []

## The slowest loads of the last load_all, as [ms, path], longest first (at most [constant SLOWEST_KEPT]).
var slowest: Array = []

const SLOWEST_KEPT := 8


## Loads every path, yielding between slices. Threaded where [param threaded] says so (default:
## the platform can); a browser without threads loads on the main thread, a slice per frame.
## Returns success(count) or the first failing path.
func load_all(tree: SceneTree, paths: PackedStringArray, threaded: bool = DotPlatform.has_threads()) -> DotResult:
	frames_yielded = 0
	loaded.clear()
	slowest.clear()
	remaining = PackedStringArray()
	peak_per_frame = 0
	peak_frame_msec = 0
	var total := paths.size()
	var started := Time.get_ticks_msec()

	if threaded:
		return await _load_threaded(tree, paths)

	var done := 0
	var slice_start := Time.get_ticks_msec()
	var in_slice := 0

	for i in total:
		var path := paths[i]
		if deadline_msec > 0 and Time.get_ticks_msec() - started >= deadline_msec:
			remaining = paths.slice(i)
			break
		var t_load := Time.get_ticks_msec()
		var res: Resource = load(path) if ResourceLoader.exists(path) else null
		_note_slow(Time.get_ticks_msec() - t_load, path)
		if res == null:
			return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

		loaded.append(res)
		done += 1
		in_slice += 1
		peak_per_frame = maxi(peak_per_frame, in_slice)
		progress.emit(done, total, path)

		var spent := Time.get_ticks_msec() - slice_start
		peak_frame_msec = maxi(peak_frame_msec, spent)
		if spent >= budget_msec or (max_per_frame > 0 and in_slice >= max_per_frame):
			frames_yielded += 1
			in_slice = 0
			await tree.process_frame
			slice_start = Time.get_ticks_msec()

	return DotResult.success(done)


## Loads [member remaining] in the background, at most [param budget] msec per frame, appending to [member loaded].
## Failures are skipped: a script that fails here fails again, with its own error, where it is used.
func load_rest(tree: SceneTree, budget: int = 3) -> void:
	var todo := remaining
	remaining = PackedStringArray()
	var slice_start := Time.get_ticks_msec()
	for path in todo:
		if ResourceLoader.exists(path):
			var res: Resource = load(path)
			if res != null:
				loaded.append(res)
		if Time.get_ticks_msec() - slice_start >= budget:
			await tree.process_frame
			slice_start = Time.get_ticks_msec()


func _note_slow(ms: int, path: String) -> void:
	if slowest.size() >= SLOWEST_KEPT and ms <= int(slowest[-1][0]):
		return
	slowest.append([ms, path])
	slowest.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	if slowest.size() > SLOWEST_KEPT:
		slowest.resize(SLOWEST_KEPT)


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


## The global-class scripts the sources at [param paths] name, not yet cached, in class-list order.
## Load them first: compiling one pack script otherwise compiles every addon class it names in one frame
## (244, 3.2 s in a browser). [param read_from] maps each path to the file to read (a pack not yet mounted).
static func named_class_scripts(paths: PackedStringArray, read_from: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var classes := ProjectSettings.get_global_class_list()
	var by_name := {}
	for entry in classes:
		by_name[str(entry["class"])] = str(entry["path"])

	var own := {}
	for path in paths:
		own[path] = true

	var named := {}
	var words := RegEx.create_from_string("\\b[A-Z][A-Za-z0-9_]+\\b")
	for i in range(paths.size()):
		var source := read_from[i] if read_from.size() == paths.size() else paths[i]
		for found in words.search_all(FileAccess.get_file_as_string(source)):
			var script_path: String = by_name.get(found.get_string(), "")
			if script_path != "" and not own.has(script_path):
				named[script_path] = true

	var out := PackedStringArray()
	for entry in classes:
		var script_path := str(entry["path"])
		if named.has(script_path) and not ResourceLoader.has_cached(script_path):
			out.append(script_path)
	return out
