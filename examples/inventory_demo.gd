extends Control

## The downloaded-content inventory: what the store lists, pinning against eviction, deleting, "keep this game's content", the quota hint, and the postMessage bridge's message handling. No network.
##
## [codeblock]
## godot --headless --path . res://examples/inventory_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_inventory_demo"
const OBJ := 1024
const SECTIONS := 7
const CHECKS := 73

@onready var _output: RichTextLabel = $Output

var _entered := 0
var _completed := 0
var _failures := 0
var _checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	_line("[b]dot-cloud inventory[/b]")
	DotPaths.remove_tree(WORK)

	await _section_inventory()
	await _section_pin_eviction()
	await _section_delete()
	await _section_game_pin()
	await _section_quota()
	await _section_bridge()
	await _section_review()

	_check("every section ran to its last line", _completed == _entered and _entered == SECTIONS,
		"%d of %d" % [_completed, SECTIONS])
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	_line("[b]%d checks, %d failed[/b]" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


func _section_inventory() -> void:
	_section("[b]1. record and list[/b]")
	var store := await _open("a", 0)
	var h1 := _put(store, 1)
	var h2 := _put(store, 2)
	store.record_pack(_manifest("arena", "1.0.0", "game", "arena", [h1, h2]))
	store.record_pack(_manifest("map-x", "2.0.0", "map", "arena", [h2]))
	store.record_pack(_manifest("odd", "1.0.0", "bogus-kind", "", [h1]))

	var inv := store.inventory()
	_check("three packs listed", inv.size() == 3, str(inv.size()))
	var arena := _find(inv, "arena")
	_check("fields present", arena.has_all(["id", "version", "kind", "game", "bytes", "last_used", "pinned"]))
	_check("bytes sum the objects", int(arena.get("bytes", 0)) == 2 * OBJ, str(arena.get("bytes")))
	_check("shared object counted per pack", int(_find(inv, "map-x").get("bytes", 0)) == OBJ)
	_check("kind kept", arena.get("kind") == "game" and _find(inv, "map-x").get("kind") == "map")
	_check("unknown kind falls back to game", _find(inv, "odd").get("kind") == "game")
	_check("game defaults to the id", _find(inv, "odd").get("game") == "odd")
	_check("platform flair is app headless", arena.get("platform") == "app")
	_check("not pinned by default", arena.get("pinned") == false)

	store.close()
	var again := await _open("a", 0)
	_check("inventory survives a restart", again.inventory().size() == 3)

	# The browser may evict objects behind our back; a pack with none left is not listed.
	DirAccess.remove_absolute(again.path_for(h1))
	DirAccess.remove_absolute(again.path_for(h2))
	again.close()
	var rebuilt := await _open("a", 0)
	_check("a pack with no objects left is dropped", rebuilt.inventory().is_empty(), str(rebuilt.inventory().size()))
	rebuilt.close()
	_done()


func _section_pin_eviction() -> void:
	_section("[b]2. a pinned pack is skipped by eviction[/b]")
	var store := await _open("b", 3 * OBJ)
	var hp := _put(store, 10)
	var hu := _put(store, 11)
	var hn := _put(store, 12)
	store.record_pack(_manifest("keep", "1", "game", "keep", [hp]))
	store.record_pack(_manifest("drop", "1", "game", "drop", [hu, hn]))
	var pinned := store.set_pinned("keep", true)
	_check("pin ok", pinned.ok)
	_check("pin unknown id fails", store.set_pinned("nope", true).error.code == DotError.CODE_INVALID)

	# The pinned object is the oldest, so plain LRU would take it first.
	var freed := store.prune(2 * OBJ)
	_check("prune ok", freed.ok, str(freed.error) if not freed.ok else "")
	_check("pinned object survives", store.has(hp))
	_check("unpinned went", not store.has(hu) and not store.has(hn))

	store.set_pinned("keep", false)
	var hz := _put(store, 13)
	var hy := _put(store, 14)
	store.record_pack(_manifest("other", "1", "game", "other", [hz, hy]))
	store.prune(2 * OBJ)
	_check("unpinned pack can be evicted", not store.has(hp))
	store.close()
	_done()


func _section_delete() -> void:
	_section("[b]3. delete[/b]")
	var store := await _open("c", 0)
	var hs := _put(store, 20)
	var ha := _put(store, 21)
	var hb := _put(store, 22)
	store.record_pack(_manifest("a", "1", "game", "a", [hs, ha]))
	store.record_pack(_manifest("b", "1", "map", "a", [hs, hb]))
	store.in_use_fn = func(key: String) -> bool: return key == "b@1"

	var busy := store.delete("b")
	_check("mounted pack refused", not busy.ok and busy.error.code == DotError.CODE_STATE)
	_check("refused delete changed nothing", store.has(hb) and store.inventory().size() == 2)
	_check("unknown id fails", store.delete("zzz").error.code == DotError.CODE_INVALID)

	var del := store.delete("a")
	_check("delete ok", del.ok)
	_check("frees only unshared objects", int(del.value) == OBJ, str(del.value))
	_check("own object gone", not store.has(ha))
	_check("shared object kept", store.has(hs))
	_check("record gone", _find(store.inventory(), "a").is_empty())

	store.in_use_fn = Callable()
	var clear := store.clear_unpinned()
	_check("clear_unpinned frees the rest", clear.ok and int(clear.value) == 2 * OBJ, str(clear.value))
	_check("store empty", store.object_count() == 0 and store.inventory().is_empty())

	var hk := _put(store, 23)
	store.record_pack(_manifest("k", "1", "game", "k", [hk]))
	store.set_pinned("k", true)
	store.clear_unpinned()
	_check("clear_unpinned spares pinned", store.has(hk))
	_check("clear_all takes everything", store.clear_all().ok and store.inventory().is_empty() and store.object_count() == 0)
	store.close()
	_done()


func _section_game_pin() -> void:
	_section("[b]4. keep a game's content[/b]")
	var store := await _open("d", 0)
	var h1 := _put(store, 30)
	store.record_pack(_manifest("g", "1", "game", "g", [h1]))
	var r := store.set_game_pinned("g", true)
	_check("pin_game ok, counted", r.ok and int(r.value) == 1)
	_check("existing pack pinned", _find(store.inventory(), "g").get("pinned") == true)

	var h2 := _put(store, 31)
	store.record_pack(_manifest("g-map", "1", "map", "g", [h2]))
	_check("later pack starts pinned", _find(store.inventory(), "g-map").get("pinned") == true)
	var other := _put(store, 32)
	store.record_pack(_manifest("x", "1", "game", "x", [other]))
	_check("other games unaffected", _find(store.inventory(), "x").get("pinned") == false)
	store.close()

	var again := await _open("d", 0)
	_check("game pin persists", again.packs.pinned_games.has("g"))
	again.set_game_pinned("g", false)
	_check("unpin game clears the list", not again.packs.pinned_games.has("g"))
	_check("describe reports packs", int(again.describe().get("packs", -1)) == 3)
	again.close()
	_done()


func _section_quota() -> void:
	_section("[b]5. quota report[/b]")
	var store := await _open("e", 0)
	store.free_bytes_provider = func() -> int: return 10 * 1024 * 1024 * 1024
	var ok := await store.quota_report()
	_check("plenty free: no cause", ok["quota_cause"] == "" and int(ok["free"]) > 0)

	store.free_bytes_provider = func() -> int: return 5 * 1024 * 1024
	store.embedded = 0
	var near := await store.quota_report()
	_check("little free: near-full", near["quota_cause"] == "near-full", str(near["quota_cause"]))
	store.embedded = 1
	var part := await store.quota_report()
	_check("little free, embedded: partitioned", part["quota_cause"] == "partitioned", str(part["quota_cause"]))

	store.free_bytes_provider = func() -> int: return -1
	var unk := await store.quota_report()
	_check("unknown free: unreadable", unk["quota_cause"] == "unreadable", str(unk["quota_cause"]))
	store.close()
	_done()


func _section_bridge() -> void:
	_section("[b]6. bridge messages[/b]")
	var store := await _open("f", 0)
	var h1 := _put(store, 40)
	var h2 := _put(store, 41)
	store.record_pack(_manifest("p", "1", "game", "p", [h1]))
	store.record_pack(_manifest("q", "1", "map", "p", [h2]))
	var site := "https://moddingcommunity.com"
	var bridge := DotCloudInventoryBridge.new(store, PackedStringArray([site]))

	_check("is_request recognises the protocol", DotCloudInventoryBridge.is_request({"dot": "dot-inventory", "op": "list"}))
	_check("is_request ignores other traffic", not DotCloudInventoryBridge.is_request({"type": "resize"}) and not DotCloudInventoryBridge.is_request("x"))

	var denied := await bridge.handle({"dot": "dot-inventory", "op": "list", "id": 1}, "https://evil.example")
	_check("unlisted origin gets no reply", denied.is_empty())
	var star := DotCloudInventoryBridge.new(store, PackedStringArray(["*"]))
	_check("star is never honoured", (await star.handle({"dot": "dot-inventory", "op": "list", "id": 1}, "*")).is_empty())
	_check("empty origin refused", (await bridge.handle({"op": "list"}, "")).is_empty())

	var list := await bridge.handle({"dot": "dot-inventory", "op": "list", "id": 7}, site)
	_check("list ok, id echoed", list["ok"] == true and list["id"] == 7 and list["op"] == "list")
	_check("list carries packs", (list["value"]["packs"] as Array).size() == 2)

	var pin := await bridge.handle({"dot": "dot-inventory", "op": "pin", "id": 8, "pack": "p", "pinned": true}, site)
	_check("pin ok", pin["ok"] == true and _find(store.inventory(), "p").get("pinned") == true)
	var badpin := await bridge.handle({"dot": "dot-inventory", "op": "pin", "id": 9, "pack": "p"}, site)
	_check("pin without flag is invalid", badpin["ok"] == false and badpin["error"]["code"] == DotError.CODE_INVALID)

	var game := await bridge.handle({"dot": "dot-inventory", "op": "pin_game", "id": 10, "game": "p", "pinned": true}, site)
	_check("pin_game ok", game["ok"] == true and store.packs.pinned_games.has("p"))

	var unknown := await bridge.handle({"dot": "dot-inventory", "op": "format_disk", "id": 11}, site)
	_check("unknown op invalid", unknown["ok"] == false and unknown["error"]["code"] == DotError.CODE_INVALID)
	var future := await bridge.handle({"dot": "dot-inventory", "op": "list", "id": 12, "v": 99}, site)
	_check("unknown version refused", future["ok"] == false and future["error"]["code"] == DotError.CODE_VERSION)

	var del := await bridge.handle({"dot": "dot-inventory", "op": "delete", "id": 13, "pack": "q", "force": true}, site)
	_check("delete ok", del["ok"] == true and not store.has(h2))
	var nodel := await bridge.handle({"dot": "dot-inventory", "op": "delete", "id": 14}, site)
	_check("delete needs a pack", nodel["ok"] == false)

	var quota := await bridge.handle({"dot": "dot-inventory", "op": "quota", "id": 15}, site)
	_check("quota has a cause field", quota["ok"] == true and quota["value"].has("quota_cause"))

	var clear := await bridge.handle({"dot": "dot-inventory", "op": "clear", "id": 16}, site)
	_check("clear spares pinned", clear["ok"] == true and store.has(h1))

	var hit := [false]
	bridge.clear_all_fn = func() -> DotResult:
		hit[0] = true
		return DotResult.success(0)
	var all := await bridge.handle({"dot": "dot-inventory", "op": "clear_all", "id": 17}, site)
	_check("clear_all uses the host hook", all["ok"] == true and hit[0])
	var json := JSON.stringify(list)
	_check("replies are JSON-safe", json != "" and JSON.parse_string(json) is Dictionary)
	store.close()
	_done()


func _section_review() -> void:
	_section("[b]7. review fixes[/b]")
	var store := await _open("r", 0)
	var h1 := _put(store, 50)
	var h2 := _put(store, 51)
	store.record_pack(_manifest("pa", "1", "game", "pa", [h1]))
	store.record_pack(_manifest("pa", "2", "game", "pa", [h2]))
	store.set_pinned("pa", true)
	var r := store.delete("pa", "1")
	_check("delete of a pinned pack refused", not r.ok and r.error.code == DotError.CODE_STATE and store.has(h1))
	var all_versions := store.delete("pa")
	_check("delete without version refused when pinned", not all_versions.ok and store.inventory().size() == 2)
	_check("force deletes a pinned pack", store.delete("pa", "1", true).ok and not store.has(h1))

	store.set_game_pinned("pa", true)
	store.set_pinned("pa", false)
	store.record_pack(_manifest("pa", "2", "game", "pa", [h2]))
	_check("re-record keeps an unpin", _find(store.inventory(), "pa").get("pinned") == false)

	var long_id := "g".repeat(DotCloudPackBook.MAX_GAME_ID + 1)
	_check("overlong game id refused", store.set_game_pinned(long_id, true).error.code == DotError.CODE_INVALID)
	for i in range(DotCloudPackBook.MAX_PINNED_GAMES):
		store.set_game_pinned("cap%d" % i, true)
	_check("pinned_games is capped", store.packs.pinned_games.size() <= DotCloudPackBook.MAX_PINNED_GAMES
		and not store.set_game_pinned("one-too-many", true).ok)

	var book_path := store.packs.path
	var good := "a".repeat(64)
	DotPaths.write_json(book_path, {"version": DotCloudPackBook.VERSION, "pinned_games": [], "packs": {
		"x@1": {"id": "x", "version": "1", "hashes": [good, "zz", 5, "../../etc"]}}}, false)
	var book := DotCloudPackBook.new(book_path)
	book.load_file()
	_check("bad hashes dropped on load", (book.records["x@1"]["hashes"] as Array) == [good])

	var site := "https://moddingcommunity.com"
	var bridge := DotCloudInventoryBridge.new(store, PackedStringArray([site, "null"]))
	_check("origin null refused", (await bridge.handle({"dot": "dot-inventory", "op": "list", "id": 1}, "null")).is_empty())
	var odd := await bridge.handle({"dot": "dot-inventory", "op": "list", "id": 2, "v": [1]}, site)
	_check("array version answered with an error", odd.get("ok") == false)
	var odd2 := await bridge.handle({"dot": "dot-inventory", "op": "list", "id": 3, "v": {"a": 1}}, site)
	_check("dictionary version answered with an error", odd2.get("ok") == false)

	store.record_pack(_manifest("bp", "1", "map", "bp", [h2]))
	store.set_pinned("bp", true)
	var nb := await bridge.handle({"dot": "dot-inventory", "op": "delete", "id": 4, "pack": "bp"}, site)
	_check("bridge delete of pinned refused", nb["ok"] == false and nb["error"]["code"] == DotError.CODE_STATE)
	var fb := await bridge.handle({"dot": "dot-inventory", "op": "delete", "id": 5, "pack": "bp", "force": true}, site)
	_check("bridge delete with force ok", fb["ok"] == true)

	var pck_dir := store.config.cache_dir.path_join("packs")
	DirAccess.make_dir_recursive_absolute(pck_dir)
	var f := FileAccess.open(pck_dir.path_join("m.pck"), FileAccess.WRITE)
	f.store_8(1)
	f.close()
	store.clear_all()
	_check("clear_all removes mounter pck copies", not FileAccess.file_exists(pck_dir.path_join("m.pck")))
	store.close()
	_done()


func _open(sub: String, limit: int) -> DotCloudStore:
	var cfg := DotCloudConfig.new()
	cfg.cache_dir = WORK.path_join(sub)
	cfg.cache_bytes = limit
	var store := DotCloudStore.new(cfg)
	var opened: DotResult = await store.open()
	if not opened.ok:
		_line("FAILED opening store %s: %s" % [sub, str(opened.error)])
		_finish(1)
	return store


func _put(store: DotCloudStore, seed_byte: int) -> String:
	var b := PackedByteArray()
	b.resize(OBJ)
	for i in range(OBJ):
		b[i] = (seed_byte * 7 + i) % 251
	var h := DotHash.sha256_bytes(b)
	var res := store.put_bytes(b, h)
	if not res.ok:
		_line("FAILED put_bytes: %s" % str(res.error))
	return h


func _manifest(id: String, version: String, kind: String, game: String, hashes: Array) -> DotCloudManifest:
	var m := DotCloudManifest.new()
	m.content_id = id
	m.version = version
	m.metadata = {"kind": kind}
	if game != "" and game != id:
		m.metadata["game"] = game
	for h in hashes:
		var f := DotCloudFile.new()
		f.path = "f_%s" % str(h).substr(0, 8)
		f.sha256 = h
		f.size = OBJ
		m.files.append(f)
	return m


func _find(inv: Array[Dictionary], id: String) -> Dictionary:
	for e in inv:
		if e["id"] == id:
			return e
	return {}


func _finish(code: int = 0) -> void:
	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(code)


func _section(title: String) -> void:
	_entered += 1
	_line(title)


func _done() -> void:
	_completed += 1


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	_line("  %s %s%s" % [label.rpad(44), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
