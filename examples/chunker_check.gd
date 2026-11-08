extends Node

## DotCloudChunker: determinism, shift stability (delta reuse), size bounds, plan, verified assembly, hostile blocks.
## Run: godot --headless --path . res://examples/chunker_check.tscn

var _fail := 0
var _n := 0


func _ok(c: bool, what: String) -> void:
	_n += 1
	if not c:
		_fail += 1
		print("FAIL: ", what)


func _rand(size: int, seed_: int) -> PackedByteArray:
	var r := RandomNumberGenerator.new()
	r.seed = seed_
	var b := PackedByteArray()
	b.resize(size)
	for i in size:
		b[i] = r.randi() & 0xFF
	return b


func _ready() -> void:
	var avg := 4096
	var mn := 1024
	var mx := 16384
	var a := _rand(600000, 7)
	var cuts := DotCloudChunker.cut(a, avg, mn, mx)
	var total := 0
	var bounds := true
	for i in cuts.size():
		total += cuts[i][1]
		if cuts[i][1] > mx or (i < cuts.size() - 1 and cuts[i][1] < mn):
			bounds = false
	_ok(total == a.size() and bounds, "cuts cover input within min/max")
	_ok(cuts.size() > 60 and cuts.size() < 400, "chunk count near size/avg (%d)" % cuts.size())
	_ok(DotCloudChunker.cut(a, avg, mn, mx) == cuts, "deterministic")
	_ok(DotCloudChunker.cut(PackedByteArray()).is_empty(), "empty input")

	var blk_a := DotCloudChunker.chunk_block(a, avg, mn, mx)
	_ok(DotCloudChunker.validate_block(blk_a, a.size()) == "", "own block validates")

	# New version: 500 bytes inserted near the start, 100 bytes changed in the middle.
	var b := a.slice(0, 3000)
	b.append_array(_rand(500, 99))
	b.append_array(a.slice(3000))
	for i in 100:
		b[300000 + i] ^= 0x5A
	var blk_b := DotCloudChunker.chunk_block(b, avg, mn, mx)
	var have := {}
	var store := {}
	for c in cuts:
		var bytes := a.slice(c[0], c[0] + c[1])
		var h := DotCloudChunker.sha256_hex(bytes)
		have[h] = true
		store[h] = bytes
	var plan := DotCloudChunker.plan(blk_b, have)
	_ok(plan["fetch_bytes"] < b.size() / 10, "delta fetches under 10%% of the file (%d of %d)" % [plan["fetch_bytes"], b.size()])
	_ok(plan["fetch_bytes"] + plan["reuse_bytes"] == b.size(), "plan accounts for all bytes")

	var newc := {}
	for c in DotCloudChunker.cut(b, avg, mn, mx):
		var bytes := b.slice(c[0], c[0] + c[1])
		newc[DotCloudChunker.sha256_hex(bytes)] = bytes
	var pool := store.duplicate()
	for e in plan["fetch"]:
		pool[e[0]] = newc[e[0]]
	var r := DotCloudChunker.assemble(blk_b, pool, DotCloudChunker.sha256_hex(b))
	_ok(r["ok"] and r["data"] == b, "assemble rebuilds the new file")
	_ok(not DotCloudChunker.assemble(blk_b, pool, DotCloudChunker.sha256_hex(a))["ok"], "wrong file hash refused")
	var bad := pool.duplicate()
	var victim: String = plan["fetch"][0][0]
	var tampered: PackedByteArray = bad[victim].duplicate()
	tampered[0] ^= 1
	bad[victim] = tampered
	_ok(not DotCloudChunker.assemble(blk_b, bad, DotCloudChunker.sha256_hex(b))["ok"], "tampered chunk refused")
	var missing := pool.duplicate()
	missing.erase(victim)
	_ok(not DotCloudChunker.assemble(blk_b, missing, DotCloudChunker.sha256_hex(b))["ok"], "missing chunk refused")

	_ok(DotCloudChunker.validate_block("x", 1) != "", "non-object rejected")
	_ok(DotCloudChunker.validate_block({"algo": "nope", "list": [], "max": 1}, 1) != "", "unknown algo rejected")
	_ok(DotCloudChunker.validate_block(blk_a, a.size() + 1) != "", "size sum mismatch rejected")
	var huge := blk_a.duplicate(true)
	huge["list"][0][1] = 999999999
	_ok(DotCloudChunker.validate_block(huge, a.size()) != "", "oversize chunk rejected")
	var badhash := blk_a.duplicate(true)
	badhash["list"][0][0] = "ABC"
	_ok(DotCloudChunker.validate_block(badhash, a.size()) != "", "bad hash rejected")

	print("chunker_check: %d checks, %d failed" % [_n, _fail])
	get_tree().quit(1 if _fail > 0 else 0)
