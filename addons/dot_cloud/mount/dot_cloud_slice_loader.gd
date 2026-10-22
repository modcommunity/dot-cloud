class_name DotCloudSliceLoader
extends RefCounted

## Loads a list of resources a few at a time across frames, so a loading cover keeps animating.

const CHANNEL := "cloud.slice"

## Emitted after each resource; drive the cover's bar from it.
signal progress(done: int, total: int, path: String)

## Longest a frame may spend loading before it yields, when not threaded.
var budget_msec: int = 8

## Frames that passed while the last load_all ran.
var frames_yielded: int = 0


## Loads every path, yielding between slices. Threaded where [param threaded] says so (default:
## the platform can); a browser without threads loads on the main thread, a slice per frame.
## Returns success(count) or the first failing path.
func load_all(tree: SceneTree, paths: PackedStringArray, threaded: bool = DotPlatform.has_threads()) -> DotResult:
	frames_yielded = 0
	var total := paths.size()

	if threaded:
		return await _load_threaded(tree, paths)

	var done := 0
	var slice_start := Time.get_ticks_msec()

	for path in paths:
		if not ResourceLoader.exists(path) or load(path) == null:
			return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

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
		elif load(path) == null:
			return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

	var done := paths.size() - pending.size()

	while not pending.is_empty():
		var still: Array[String] = []

		for path in pending:
			match ResourceLoader.load_threaded_get_status(path):
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					still.append(path)
				ResourceLoader.THREAD_LOAD_LOADED:
					ResourceLoader.load_threaded_get(path)
					done += 1
					progress.emit(done, paths.size(), path)
				_:
					return DotResult.fail(DotError.CODE_IO, "could not load a resource", path)

		pending = still

		if not pending.is_empty():
			frames_yielded += 1
			await tree.process_frame

	return DotResult.success(done)
