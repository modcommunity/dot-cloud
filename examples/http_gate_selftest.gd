extends Node

## DotCloudSourceHttp.download: more downloads than DotHttp's pool never fail with "Too many concurrent HTTP requests".
## Run: godot --headless --path . res://examples/http_gate_selftest.tscn

const POOL := 16
const CHECKS := 6

var _failures := 0
var _checks := 0


## Refuses past the pool the way DotHttp does, and records the peak.
class PoolStub extends DotHttp:
	var active := 0
	var peak := 0

	func download_to_file(_url: String, _dest: String, _from: int = 0, _headers: Dictionary = {}, _max: int = 0) -> DotResult:
		if active >= POOL:
			return DotResult.fail(DotError.CODE_STATE, "Too many concurrent HTTP requests.")
		active += 1
		peak = maxi(peak, active)
		for _i in 3:
			await get_tree().process_frame
		active -= 1
		return DotResult.success(true)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run(12, "default cap")
	await _run(15, "highest cap")
	var stub := PoolStub.new()
	add_child(stub)
	var s := DotCloudSourceHttp.new()
	s.http = stub
	s.max_in_flight = 1
	var done := [0]
	for i in 5:
		_one(s, done)
	while done[0] < 5:
		await get_tree().process_frame
	_check("a cap of one runs the downloads in turn", stub.peak == 1, str(stub.peak))
	_check("every check ran", _checks + 1 == CHECKS, str(_checks))
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _one(s: DotCloudSourceHttp, done: Array) -> void:
	await s.download("http://x/y", "user://x", 0)
	done[0] += 1


func _run(cap: int, label: String) -> void:
	var stub := PoolStub.new()
	add_child(stub)
	var s := DotCloudSourceHttp.new()
	s.http = stub
	s.max_in_flight = cap
	var results: Array[DotResult] = []
	var done := [0]
	var launch := func() -> void:
		var r := await s.download("http://x/y", "user://x", 0)
		results.append(r)
		done[0] += 1
	for i in 60:
		launch.call()
	while done[0] < 60:
		await get_tree().process_frame
	var failed := results.filter(func(r: DotResult) -> bool: return not r.ok).size()
	_check("%s: 60 simultaneous downloads, none refused by the pool" % label, failed == 0, "%d failed" % failed)
	_check("%s: never more than %d at once" % [label, cap], stub.peak <= cap, str(stub.peak))


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	print("  %s  %s%s" % ["ok  " if passed else "FAIL", label, "" if passed or detail == "" else " (" + detail + ")"])
	if not passed:
		_failures += 1
