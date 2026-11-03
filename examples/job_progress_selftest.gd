extends Node

## DotCloudJobProgress: the aggregate maths of a many-pack job, on a fake clock.
## Run: godot --headless --path . res://examples/job_progress_selftest.tscn

const CHECKS := 35
const SECTIONS := 6

var _failures := 0
var _checks := 0
var _started := 0
var _finished := 0
var _t := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_totals()
	_partial()
	_parallel()
	_retries()
	_rate()
	_unpack()
	_check("every section finished", _started == SECTIONS and _finished == SECTIONS, "%d of %d" % [_finished, SECTIONS])
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


func _job() -> DotCloudJobProgress:
	_t = 0
	var j := DotCloudJobProgress.new()
	j.now_ms = func() -> int: return _t
	return j


func _totals() -> void:
	_begin("totals known up front")
	var j := _job()
	j.add_pack("game@1", 600, 6)
	j.add_pack("map-a@1", 300, 3)
	j.add_pack("map-b@1", 100, 1)
	var s := j.snapshot()
	_check("total bytes is the sum", s["total_bytes"] == 1000)
	_check("total files and packs", s["total_files"] == 10 and s["total_packs"] == 3)
	_check("nothing done yet", s["done_bytes"] == 0 and s["fraction"] == 0.0 and s["eta_sec"] == -1.0)
	j.add_pack("map-a@1", 300, 3)
	_check("registering a pack twice does not double the total", j.snapshot()["total_bytes"] == 1000)
	j.add_pack("cached@1", 0, 0)
	s = j.snapshot()
	_check("an already cached pack counts as done and adds nothing", s["done_packs"] == 1 and s["total_bytes"] == 1000)
	_end()


func _partial() -> void:
	_begin("partial progress")
	var j := _job()
	j.add_pack("a", 600, 6)
	j.add_pack("b", 400, 4)
	j.set_pack_done("a", 150, 1)
	var s := j.snapshot()
	_check("a quarter of the first pack is 15 percent of the job", is_equal_approx(s["fraction"], 0.15) and s["done_bytes"] == 150)
	j.finish_pack("a")
	s = j.snapshot()
	_check("finishing a pack credits all its bytes", s["done_bytes"] == 600 and s["done_packs"] == 1 and s["done_files"] == 6)
	j.set_pack_done("b", 9999, 99)
	s = j.snapshot()
	_check("a report past the total is clamped", s["done_bytes"] == 1000 and s["fraction"] == 1.0 and s["done_files"] == 10)
	j.set_pack_done("nope", 5)
	_check("an unknown pack is ignored", j.snapshot()["done_bytes"] == 1000)
	_check("text names bytes and packs", j.text().contains("1/2 packs"), j.text())
	_end()


func _parallel() -> void:
	_begin("parallel transfers")
	var j := _job()
	j.add_pack("a", 1000, 3)
	j.set_file("a", "f1", 100)
	j.set_file("a", "f2", 250)
	j.set_file("a", "f3", 50)
	_check("simultaneous files add up", j.snapshot()["done_bytes"] == 400)
	j.set_file("a", "f2", 300)
	_check("a file's report replaces its earlier one", j.snapshot()["done_bytes"] == 450)
	j.add_pack("b", 500, 1)
	j.set_file("b", "f1", 200)
	_check("the same file id in another pack is separate", j.snapshot()["done_bytes"] == 650)
	j.set_file("a", "f1", 5000)
	_check("files cannot push a pack past its total", j.snapshot()["done_bytes"] == 1200, str(j.snapshot()["done_bytes"]))
	_end()


func _retries() -> void:
	_begin("retries are not double counted")
	var j := _job()
	j.add_pack("a", 1000, 2)
	j.set_file("a", "f1", 400)
	j.set_file("a", "f1", 400)
	_check("the same report twice counts once", j.snapshot()["done_bytes"] == 400)
	j.set_file("a", "f1", 0)
	_check("a restart from byte zero does not move the bar back", j.snapshot()["done_bytes"] == 400)
	j.set_file("a", "f1", 400)
	_check("and the resumed bytes are not added again", j.snapshot()["done_bytes"] == 400)
	j.set_pack_done("a", 400, 0)
	_check("a pack-level report of the same bytes does not stack on file reports", j.snapshot()["done_bytes"] == 400)
	j.set_pack_done("a", 0, 0)
	_check("a downloader that restarts its own counters changes nothing", j.snapshot()["done_bytes"] == 400)
	j.finish_pack("a")
	j.set_file("a", "f1", 1000)
	_check("a finished pack stays at its total", j.snapshot()["done_bytes"] == 1000)
	_end()


func _rate() -> void:
	_begin("rate and ETA")
	var j := _job()
	j.add_pack("a", 10000, 10)
	_t = 0
	j.set_pack_done("a", 0)
	_t = 1000
	j.set_pack_done("a", 1000)
	_t = 2000
	j.set_pack_done("a", 2000)
	var s := j.snapshot()
	_check("1000 B/s over two seconds", is_equal_approx(s["bytes_per_sec"], 1000.0), str(s["bytes_per_sec"]))
	_check("8000 B left at 1000 B/s is 8 s", is_equal_approx(s["eta_sec"], 8.0), str(s["eta_sec"]))
	_t = 30000
	j.set_pack_done("a", 2000)
	s = j.snapshot()
	_check("a stall decays the rate once the window has passed", s["bytes_per_sec"] < 1.0, str(s["bytes_per_sec"]))
	var seen := []
	j.changed.connect(func(x: Dictionary) -> void: seen.append(x))
	j.set_pack_done("a", 3000)
	_check("changed carries the snapshot", seen.size() == 1 and seen[0]["done_bytes"] == 3000)
	_check("describe lists the packs", j.describe()["packs"] == PackedStringArray(["a"]))
	_end()


func _unpack() -> void:
	_begin("unpack phase")
	var j := _job()
	j.add_pack("a", 1000, 1)
	j.add_pack("b", 3000, 1)
	j.note_unpacked()
	_check("an unpack tick before the phase is ignored", j.snapshot()["unpack_done"] == 0)
	_check("downloading is the first phase", j.snapshot()["phase"] == "download")
	j.set_pack_done("a", 1000)
	j.set_pack_done("b", 3000)
	var before: float = float(j.snapshot()["done_bytes"]) / float(j.snapshot()["total_bytes"])
	j.begin_unpack()
	var s := j.snapshot()
	_check("the phase flips to unpack", s["phase"] == "unpack")
	_check("the count defaults to the pack count", s["unpack_total"] == 2 and s["unpack_done"] == 0, str(s))
	j.note_unpacked()
	s = j.snapshot()
	_check("each mount ticks the count", s["unpack_done"] == 1)
	_check("the byte fraction does not move", float(s["done_bytes"]) / float(s["total_bytes"]) == before)
	j.note_unpacked()
	j.note_unpacked()
	_check("the count never passes the total", j.snapshot()["unpack_done"] <= j.snapshot()["unpack_total"], str(j.snapshot()))
	var k := _job()
	k.add_pack("a", 100, 1)
	k.begin_unpack(5)
	_check("an explicit total is honoured", k.snapshot()["unpack_total"] == 5)
	_end()


func _begin(name: String) -> void:
	_started += 1
	print("\n[%s]" % name)


func _end() -> void:
	_finished += 1


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("  %s %s%s" % [label.rpad(64), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])
