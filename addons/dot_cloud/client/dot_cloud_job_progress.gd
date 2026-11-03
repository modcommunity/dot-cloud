class_name DotCloudJobProgress
extends RefCounted

## One progress model for a download job made of many packs (a game, its weapons, forty map packs).
## Totals are registered up front from the manifests; progress is SET, never added, so a retried or
## repeated report cannot count a byte twice and a lower report cannot move the bar back.

signal changed(snapshot: Dictionary)

## Seconds of history the rate and ETA are averaged over.
const RATE_WINDOW_SEC := 5.0

## Replaceable in a test so rate and ETA are exact.
var now_ms: Callable = func() -> int: return Time.get_ticks_msec()
var label := ""

var _packs: Dictionary = {}  # key -> {total_bytes, total_files, done_bytes, done_files, files, finished}
var _order: PackedStringArray = PackedStringArray()
var _samples: Array = []  # [ms, cumulative done bytes]
var _current := ""


## Registers a pack's expected work. Calling again for a known key only raises its totals.
func add_pack(key: String, total_bytes: int, total_files: int = 0) -> void:
	if not _packs.has(key):
		_packs[key] = {"total_bytes": 0, "total_files": 0, "done_bytes": 0, "done_files": 0, "files": {}, "finished": false}
		_order.append(key)
	var p: Dictionary = _packs[key]
	p["total_bytes"] = maxi(int(p["total_bytes"]), total_bytes)
	p["total_files"] = maxi(int(p["total_files"]), total_files)
	if total_bytes <= 0 and total_files <= 0:
		p["finished"] = true
	_touch()


## Pack-level report: [param done_bytes] of the pack so far (what a downloader's own progress says).
func set_pack_done(key: String, done_bytes: int, done_files: int = 0) -> void:
	if not _packs.has(key):
		return
	var p: Dictionary = _packs[key]
	p["done_bytes"] = maxi(int(p["done_bytes"]), done_bytes)
	p["done_files"] = maxi(int(p["done_files"]), done_files)
	_current = key
	_touch()


## File-level report for parallel transfers: the bytes of [param file_id] so far, replacing any earlier value.
func set_file(key: String, file_id: String, bytes: int) -> void:
	if not _packs.has(key):
		return
	var files: Dictionary = (_packs[key] as Dictionary)["files"]
	files[file_id] = maxi(int(files.get(file_id, 0)), bytes)
	_current = key
	_touch()


func finish_pack(key: String) -> void:
	if _packs.has(key):
		(_packs[key] as Dictionary)["finished"] = true
		_touch()


## The job is over: whatever did not finish stays at what it reached, and the last snapshot says so.
func finish_all() -> void:
	changed.emit(snapshot())


## The key of the pack reported on last.
func current() -> String:
	return _current


func pack_count() -> int:
	return _packs.size()


func _pack_done_bytes(p: Dictionary) -> int:
	if bool(p["finished"]):
		return int(p["total_bytes"])
	var by_files := 0
	for b: int in (p["files"] as Dictionary).values():
		by_files += b
	return mini(maxi(int(p["done_bytes"]), by_files), int(p["total_bytes"]))


## Everything a bar and a caption need.
func snapshot() -> Dictionary:
	var total_bytes := 0
	var done_bytes := 0
	var total_files := 0
	var done_files := 0
	var packs_done := 0
	for key in _order:
		var p: Dictionary = _packs[key]
		total_bytes += int(p["total_bytes"])
		done_bytes += _pack_done_bytes(p)
		total_files += int(p["total_files"])
		done_files += int(p["total_files"]) if bool(p["finished"]) else mini(int(p["done_files"]), int(p["total_files"]))
		if bool(p["finished"]):
			packs_done += 1

	var fraction := 0.0
	if total_bytes > 0:
		fraction = clampf(float(done_bytes) / float(total_bytes), 0.0, 1.0)
	elif not _packs.is_empty():
		fraction = float(packs_done) / float(_packs.size())

	var rate := _rate()
	var eta := -1.0
	if rate > 1.0 and total_bytes > done_bytes:
		eta = float(total_bytes - done_bytes) / rate

	return {
		"label": label,
		"fraction": fraction,
		"done_bytes": done_bytes,
		"total_bytes": total_bytes,
		"done_files": done_files,
		"total_files": total_files,
		"done_packs": packs_done,
		"total_packs": _packs.size(),
		"bytes_per_sec": rate,
		"eta_sec": eta,
		"current": _current,
	}


func _rate() -> float:
	if _samples.size() < 2:
		return 0.0
	var span := float(int(_samples[-1][0]) - int(_samples[0][0])) / 1000.0
	if span <= 0.001:
		return 0.0
	return float(int(_samples[-1][1]) - int(_samples[0][1])) / span


func _touch() -> void:
	var s := snapshot_basic()
	var ms: int = now_ms.call()
	_samples.append([ms, s])
	var cutoff := ms - int(RATE_WINDOW_SEC * 1000.0)
	while _samples.size() > 2 and (int(_samples[1][0]) < cutoff or _samples.size() > 256):
		_samples.pop_front()
	changed.emit(snapshot())


func snapshot_basic() -> int:
	var done := 0
	for key in _order:
		done += _pack_done_bytes(_packs[key])
	return done


## One line for a caption: "12 MB / 340 MB, 3/41 packs (4 MB/s, 1m 20s left)".
func text() -> String:
	var s := snapshot()
	var out := "%s / %s, %d/%d packs" % [
		DotPaths.format_bytes(int(s["done_bytes"])), DotPaths.format_bytes(int(s["total_bytes"])),
		int(s["done_packs"]), int(s["total_packs"]),
	]
	var rate := float(s["bytes_per_sec"])
	if rate > 1.0:
		out += " (%s/s" % DotPaths.format_bytes(int(rate))
		if float(s["eta_sec"]) >= 0.0:
			out += ", %s left" % DotCloudDownloader._format_duration(float(s["eta_sec"]))
		out += ")"
	return out


func describe() -> Dictionary:
	var d := snapshot()
	d["packs"] = _order.duplicate()
	return d
