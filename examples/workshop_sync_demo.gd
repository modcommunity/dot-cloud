extends Node

## The Workshop's sync client against a fake site: [DotCloudWorkshop] fetching a list, caching it,
## mounting what survives the device's rules, and refusing everything an online session is.
##
## The packs are real: published with [DotCloudPublisher], signed, served over HTTP by
## [code]http_test_server.gd[/code], verified and mounted by a real [DotCloudClient]. Only the
## site is fake ([code]workshop_backbone.gd[/code]). Each refusal is armed -- the check beside it
## shows the unguarded path doing the thing -- so a test that cannot fail shows up.
##
## [codeblock]
## godot --headless --path . res://examples/workshop_sync_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_workshop_sync_demo"
const GAME := "gamemann/game-playground"
const CHECKS := 90
const ACCEPTS := {"kinds": ["map", "prop", "script"], "map_kinds": ["sandbox"]}

var _failures := 0
var _checks := 0
var _key_pem := ""
var _cloud: DotCloudClient
var _index: DotContentIndex
var _content: Node
var _bb: Node
var _ws: DotCloudWorkshop
var _token := "tok-alice"
var _world := {"mode": "ok", "revision": "w1:one", "items": [], "removed": [], "account": "acct-alice"}
var _packs := {}
var _failed_signals: Array = []
var _progress: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("[b]the Workshop sync client against a fake site[/b]")
	DotPaths.remove_tree(WORK)

	var keys := DotCloudSignature.generate_keypair(2048)
	_check(keys.ok, "a signing key pair is generated")
	if not keys.ok:
		_done()
		return
	_key_pem = str((keys.value as Dictionary)["private"])

	_index = DotContentIndex.new()
	DotRegistry.register(DotContentIndex.SERVICE, _index)
	_index.set_session(&"solo")

	_content = preload("res://examples/http_test_server.gd").new()
	add_child(_content)
	_content.root = WORK.path_join("pub")
	_content.start(0)

	_bb = preload("res://examples/workshop_backbone.gd").new()
	add_child(_bb)
	_bb.handler = _site
	_bb.start()

	_cloud = DotCloudClient.new()
	_cloud.name = "Cloud"
	_cloud.config = DotCloudConfig.new()
	_cloud.config.cache_dir = WORK.path_join("cache")
	_cloud.config.trusted_keys = {
		"tmc": {"key": str((keys.value as Dictionary)["public"]), "content_ids": ["ws_*"]},
		"other": {"key": str((keys.value as Dictionary)["public"]), "content_ids": ["ws_*"]},
	}
	_cloud.config_file = ""
	_cloud.register_service = false
	add_child(_cloud)

	_ws = DotCloudWorkshop.new()
	_ws.name = "Workshop"
	_ws.cloud = _cloud
	_ws.config = DotCloudWorkshopConfig.new()
	_ws.config.workshop_backbone_url = _bb.base_url()
	_ws.config.workshop_timeout_sec = 1.0
	_ws.config_file = ""
	_ws.cache_dir = WORK.path_join("workshop")
	_ws.token_fn = func() -> String: return _token
	_ws.force_metered = 0
	_ws.pack_failed.connect(func(id: String, _v: String, _e: DotError) -> void: _failed_signals.append(id))
	_ws.progress.connect(func(d: int, t: int, bd: int, bt: int, cur: String) -> void:
		_progress.append([d, t, bd, bt, cur]))
	add_child(_ws)

	_make_pack("ws_a", "map")
	_make_pack("ws_b", "prop")
	_make_pack("ws_e", "map")
	_make_pack("ws_off", "map")
	_make_pack("ws_code", "script", true)
	_make_pack("ws_m1", "map")
	_make_pack("ws_m2", "map")
	_make_pack("ws_q", "map", false, 1)
	_make_pack("ws_wrongkey", "map", false, 0, "other")

	await _check_first_sync_and_cache()
	await _check_unchanged()
	await _check_removal()
	await _check_offline()
	await _check_broken_pack()
	await _check_device_and_policy()
	await _check_metered_and_quota()
	await _check_guest_and_disabled()
	await _check_online_refused()
	await _check_scope_write()
	_check_reporting()

	_done()


# --- the fake site ---------------------------------------------------------

func _site(method: String, path: String, query: Dictionary, headers: Dictionary, body: String) -> Dictionary:
	var auth := str(headers.get("authorization", ""))
	if path == "/api/app/v1/workshop/scope":
		var parsed: Variant = JSON.parse_string(body)
		var req: Dictionary = parsed if parsed is Dictionary else {}
		if req.has("all") and auth == "Bearer tok-game":
			return {"status": 403, "json": {"error": "game_scope"}}
		return {"status": 200, "json": {"subscriptionId": req.get("subscriptionId", ""), "scope": "listed", "games": [GAME], "revision": "w1:after"}}
	if method != "GET" or path != "/api/app/v1/workshop":
		return {"status": 404, "json": {}}
	if auth == "Bearer tok-bad":
		return {"status": 401, "json": {"error": "unauthorized"}}
	match str(_world["mode"]):
		"hang":
			return {"hang": true}
		"503":
			return {"status": 503, "json": {"error": "down"}}
	if str(query.get("since", "")) == str(_world["revision"]):
		return {"status": 200, "json": {"revision": _world["revision"], "unchanged": true, "full": false, "items": [], "removed": []}}
	return {"status": 200, "json": {
		"game": {"contentId": GAME, "accepts": ACCEPTS}, "account": _world["account"],
		"revision": _world["revision"], "unchanged": false, "full": true,
		"items": _world["items"], "removed": _world["removed"],
	}}


func _make_pack(id: String, kind: String, code: bool = false, pad: int = 0, key_id: String = "tmc") -> void:
	var dir := WORK.path_join("src_" + id)
	var entries: Array = []
	match kind:
		"map":
			DotPaths.write_text(dir.path_join("maps/m.tscn"), "[gd_scene format=3]\n\n[node name=\"M\" type=\"Node3D\"]\n")
			entries.append({"kind": "map", "id": "m", "name": id + " map", "scene": "maps/m.tscn", "map_kind": "sandbox"})
		"prop":
			DotPaths.write_text(dir.path_join("props/p.tscn"), "[gd_scene format=3]\n\n[node name=\"P\" type=\"Node3D\"]\n")
			entries.append({"kind": "prop", "id": "p", "name": id + " prop", "scene": "props/p.tscn"})
		"script":
			DotPaths.write_text(dir.path_join("hooks/h.gd"), "extends Node\n")
			entries.append({"kind": "script", "id": "h", "name": id + " hook", "script": "hooks/h.gd", "hook": "playground"})
	if pad > 0:
		DotPaths.write_text(dir.path_join("pad.bin"), "x".repeat(4096))
	DotPaths.write_text(dir.path_join("provides.json"), JSON.stringify({
		"schema": 1, "title": id, "kinds": [kind], "games": "*", "entries": entries}))
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = "1.0.0"
	pub.signing_key_pem = _key_pem
	pub.signing_key_id = key_id
	var out: String = str(_content.root).path_join(id)
	var res := pub.publish(dir, out)
	_check(res.ok, "fixture pack %s publishes" % id, str(res.error) if not res.ok else "")
	_packs[id] = {"bytes": 100 + pad * 4096, "kind": kind, "code": code, "key": key_id}


func _item(id: String, approved: bool = true, manifest_url: String = "") -> Dictionary:
	var p: Dictionary = _packs[id]
	return {
		"subscriptionId": "sub-" + id, "assetId": 1, "name": id, "scope": "all", "autoUpdate": true,
		"pack": {
			"contentId": id, "version": "1.0.0",
			"manifestUrl": manifest_url if manifest_url != "" else "%s/%s/manifest.json" % [_content.base_url(), id],
			"bytes": p["bytes"], "kinds": [p["kind"]], "runsCode": p["code"], "approved": approved, "keyId": p["key"],
		},
	}


func _list_requests() -> int:
	var n := 0
	for r in _bb.requests:
		if r["path"] == "/api/app/v1/workshop":
			n += 1
	return n


func _last_request() -> Dictionary:
	return _bb.requests[_bb.requests.size() - 1] if not _bb.requests.is_empty() else {}


func _ids(entries: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for e in entries:
		out.append(str((e as Dictionary)["content_id"]))
	out.sort()
	return out


func _reasons(entries: Array) -> String:
	var parts := PackedStringArray()
	for e in entries:
		parts.append("%s:%s" % [e["content_id"], e["reason"]])
	parts.sort()
	return ",".join(parts)


# --- sections --------------------------------------------------------------

func _check_first_sync_and_cache() -> void:
	_line("")
	_line("[b]first sync[/b]")
	_world["items"] = [_item("ws_a"), _item("ws_b")]
	var before := _index.entries(&"map").size()
	var res := await _ws.sync(GAME)
	_check(res.ok, "sync succeeds", str(res.error) if not res.ok else "")
	if not res.ok:
		return
	var s: Dictionary = res.value
	_check(_ids(s["mounted"]) == PackedStringArray(["ws_a", "ws_b"]), "both packs mount", str(s["mounted"]))
	_check(not s["guest"] and not s["offline"] and not s["from_cache"] and s["revision"] == "w1:one", "a fresh answer from the site, revision recorded")
	var req := _last_request()
	_check(req.get("headers", {}).get("authorization") == "Bearer tok-alice", "the bearer came from token_fn")
	_check(req.get("query", {}).get("game") == GAME and not req.get("query", {}).has("since"), "the request names the game and, with no cache, no since")
	_check(req.get("query", {}).get("platform") == DotCloudWorkshop.client_platform() and DotCloudWorkshop.client_platform() in ["web", "desktop", "mobile"], "the request names the platform, from DotPlatform", str(req.get("query", {}).get("platform")))
	_check(_index.entries(&"map").size() == before + 1 and _index.entries(&"prop").size() == 1, "the index offers the map and the prop to the solo session")
	var e := _index.entry("ws_a@1.0.0:map/m")
	_check(e != null and e.source == &"subscription" and _index.packs(&"solo").size() >= 2, "tagged as a subscription in the solo session")
	_check(not _progress.is_empty() and _progress[_progress.size() - 1][0] == 2 and _progress[_progress.size() - 1][1] == 2, "progress ends at 2 of 2", str(_progress.back()) if not _progress.is_empty() else "")
	_check(not _progress.is_empty() and _progress[0][0] == 0 and _progress[0][4] == "ws_a", "and began at 0, naming the pack")
	var cache_files := DotPaths.list_files_recursive(WORK.path_join("workshop"))
	_check(not cache_files.is_empty(), "the list was cached in user://")
	_check(not _ws.requires_restart_before_online(), "data packs need no restart before an online join")


func _check_unchanged() -> void:
	_line("")
	_line("[b]unchanged revision[/b]")
	# Forced here so the one platform the headless run is not (web) is seen on the wire too.
	_ws.force_platform = "Web"
	var res := await _ws.sync(GAME)
	_ws.force_platform = ""
	var s: Dictionary = res.value
	var req := _last_request()
	_check(req.get("query", {}).get("since") == "w1:one", "the request carries the cached revision as since")
	_check(req.get("query", {}).get("platform") == "web", "force_platform overrides the platform sent, normalised", str(req.get("query", {}).get("platform")))
	_check(s["from_cache"] and not s["offline"] and s["revision"] == "w1:one", "an unchanged answer keeps the cached list, online")
	_check(_ids(s["mounted"]) == PackedStringArray(["ws_a", "ws_b"]), "the cached list's packs are mounted again (already mounted, tagged)")
	_check(_ws.last_list().items().size() == 2, "last_list still holds both items")


func _check_removal() -> void:
	_line("")
	_line("[b]a removal[/b]")
	_world["revision"] = "w1:two"
	_world["items"] = [_item("ws_a")]
	_world["removed"] = [{"subscriptionId": "sub-ws_b", "assetId": 2, "contentId": "ws_b", "reason": "scope"}]
	var res := await _ws.sync(GAME)
	var s: Dictionary = res.value
	_check(_ids(s["mounted"]) == PackedStringArray(["ws_a"]), "the removed pack is not offered to mount")
	_check(_ws.last_list().items().size() == 1 and _ws.last_list().removed().size() == 1, "the new list replaced the cache, with the removal and its reason")
	_check(str(_ws.last_list().removed()[0]["reason"]) == "scope", "the reason is kept for the panel")
	var again := await _ws.sync(GAME)
	_check(again.value["from_cache"] and again.value["revision"] == "w1:two", "the replaced list is what the next launch caches against")


func _check_offline() -> void:
	_line("")
	_line("[b]offline[/b]")
	_world["mode"] = "503"
	var res := await _ws.sync(GAME)
	var s: Dictionary = res.value
	_check(res.ok and s["offline"] and s["from_cache"] and s["revision"] == "w1:two", "a 503 uses the cached list")
	_check(_ids(s["mounted"]) == PackedStringArray(["ws_a"]), "and mounts from it")

	# A site that is simply not there. (A silent one that accepts and never answers froze the
	# whole process in this single-threaded fake, so it is not exercised here.)
	_ws.config.workshop_backbone_url = "http://127.0.0.1:1"
	var started := Time.get_ticks_msec()
	var timed_out := await _ws.sync(GAME)
	var took := Time.get_ticks_msec() - started
	_check(timed_out.ok and timed_out.value["offline"] and timed_out.value["from_cache"], "a refused connection falls back to the cache")
	_check(took < 8000, "promptly", "%d ms" % took)

	var none := await _ws.sync("nobody/never-synced")
	_check(none.ok and none.value["offline"] and not none.value["from_cache"] and none.value["reason"] == "offline_no_cache", "offline with no cache for that game is an empty summary with a reason")
	_check(none.value["mounted"].is_empty(), "nothing mounted")

	_ws.config.workshop_backbone_url = _bb.base_url()
	_ws.account_id = "acct-bob"
	var other := await _ws.sync(GAME)
	_check(other.value["offline"] and not other.value["from_cache"] and other.value["mounted"].is_empty(), "a cached list from another account is not used")
	_ws.account_id = "acct-alice"
	var mine := await _ws.sync(GAME)
	_check(mine.value["from_cache"] and mine.value["mounted"].size() == 1, "armed: the same cache is used for its own account")
	_ws.account_id = ""
	_world["mode"] = "ok"
	_world["revision"] = "w1:three"


func _check_broken_pack() -> void:
	_line("")
	_line("[b]one broken pack among three[/b]")
	_packs["ws_missing"] = {"bytes": 1, "kind": "map", "code": false, "key": "tmc"}
	_world["items"] = [_item("ws_a"), _item("ws_missing"), _item("ws_e")]
	_failed_signals.clear()
	var res := await _ws.sync(GAME)
	var s: Dictionary = res.value
	_check(res.ok, "the sync still succeeds")
	_check(_ids(s["mounted"]) == PackedStringArray(["ws_a", "ws_e"]), "the other two mount", str(s["mounted"]))
	_check(s["failed"].size() == 1 and s["failed"][0]["content_id"] == "ws_missing", "the broken one is reported", str(s["failed"]))
	_check(_failed_signals == ["ws_missing"], "pack_failed fired once for it")

	_world["items"] = [_item("ws_wrongkey")]
	_world["revision"] = "w1:four"
	var wrong := await _ws.sync(GAME)
	_check(wrong.value["failed"].size() == 1 and wrong.value["failed"][0]["code"] == DotError.CODE_FORBIDDEN and wrong.value["mounted"].is_empty(), "a pack signed with a key outside workshop_key_ids is refused", str(wrong.value["failed"]))


func _check_device_and_policy() -> void:
	_line("")
	_line("[b]device overrides and code packs[/b]")
	_world["revision"] = "w1:five"
	_world["items"] = [_item("ws_off"), _item("ws_code", false), _item("ws_e")]
	var off := await _ws.set_device_off("ws_off", true)
	_check(off.ok, "a device switch is saved")
	var s: Dictionary = (await _ws.sync(GAME)).value
	_check(_reasons(s["skipped"]).contains("ws_off:device_off"), "a pack turned off here is skipped as device_off", _reasons(s["skipped"]))
	_check(_reasons(s["skipped"]).contains("ws_code:script_policy"), "an unapproved code pack is skipped under 'approved'")
	_check(_ids(s["mounted"]) == PackedStringArray(["ws_e"]), "and only the plain pack mounts")
	_check(not _cloud.is_mounted(&"ws_code", "1.0.0") and not _cloud.is_mounted(&"ws_off", "1.0.0"), "armed: neither was downloaded or mounted")
	_check(not _ws.requires_restart_before_online(), "nothing ran code")
	var device_file := FileAccess.get_file_as_string(WORK.path_join("workshop/device.json"))
	_check(device_file.contains("ws_off"), "the override lives in device.json on this device")
	_check(not JSON.stringify(_last_request()).contains("ws_off"), "and never reached the site")

	_world["items"] = [_item("ws_code", true)]
	_world["revision"] = "w1:six"
	var approved: Dictionary = (await _ws.sync(GAME)).value
	_check(_ids(approved["mounted"]) == PackedStringArray(["ws_code"]), "an approved code pack mounts", str(approved["failed"]))
	_check(_ws.requires_restart_before_online(), "and an online join must now restart the process")

	_ws.config.workshop_script_packs = "never"
	_world["revision"] = "w1:seven"
	var never: Dictionary = (await _ws.sync(GAME)).value
	_check(_reasons(never["skipped"]).contains("ws_code:script_policy") and never["mounted"].is_empty(), "'never' skips even an approved code pack")
	_ws.config.workshop_script_packs = "approved"
	await _ws.set_device_off("ws_off", false)


func _check_metered_and_quota() -> void:
	_line("")
	_line("[b]metered connections and storage[/b]")
	_ws.force_metered = 1
	_world["items"] = [_item("ws_m1")]
	_world["revision"] = "w1:eight"
	var asked: Array = []
	var ask_answer := [false]
	_ws.ask_fn = func(summary: Dictionary) -> bool:
		asked.append(summary)
		return ask_answer[0]
	var declined: Dictionary = (await _ws.sync(GAME)).value
	_check(asked.size() == 1 and asked[0]["bytes"] > 0 and asked[0]["metered"], "on a metered connection the player is asked once, with the size")
	_check(_reasons(declined["skipped"]) == "ws_m1:metered" and not _cloud.is_mounted(&"ws_m1", "1.0.0"), "declined: skipped as metered and not downloaded")

	ask_answer[0] = true
	var accepted: Dictionary = (await _ws.sync(GAME)).value
	_check(_ids(accepted["mounted"]) == PackedStringArray(["ws_m1"]), "accepted: it mounts")

	_world["revision"] = "w1:nine"
	asked.clear()
	var stored: Dictionary = (await _ws.sync(GAME)).value
	_check(asked.is_empty() and _ids(stored["mounted"]) == PackedStringArray(["ws_m1"]), "nothing to download means nobody is asked")

	_ws.device.set_metered_policy("never")
	_world["items"] = [_item("ws_m2")]
	_world["revision"] = "w1:ten"
	var never: Dictionary = (await _ws.sync(GAME)).value
	_check(asked.is_empty() and _reasons(never["skipped"]) == "ws_m2:metered", "the device's 'never' skips without asking")
	_ws.device.set_metered_policy("allow")
	var allowed: Dictionary = (await _ws.sync(GAME)).value
	_check(asked.is_empty() and _ids(allowed["mounted"]) == PackedStringArray(["ws_m2"]), "the device's 'allow' downloads without asking")
	_ws.device.set_metered_policy("")
	_ws.force_metered = 0
	_ws.ask_fn = Callable()

	_world["items"] = [_item("ws_q")]
	_world["revision"] = "w1:eleven"
	var store := _cloud.store
	var real_limit: int = store._limit_bytes
	store._limit_bytes = store.referenced_bytes() + 100
	var tight: Dictionary = (await _ws.sync(GAME)).value
	_check(_reasons(tight["skipped"]) == "ws_q:quota" and not _cloud.is_mounted(&"ws_q", "1.0.0"), "a pack that does not fit beside what is referenced is skipped as quota")
	store._limit_bytes = real_limit
	var roomy: Dictionary = (await _ws.sync(GAME)).value
	_check(_ids(roomy["mounted"]) == PackedStringArray(["ws_q"]), "armed: with room it mounts")

	_world["items"] = [_item("ws_a"), _item("ws_b")]
	_world["revision"] = "w1:twelve"
	var old_max := _ws.config.workshop_max_packs
	_ws.config.workshop_max_packs = 1
	var capped: Dictionary = (await _ws.sync(GAME)).value
	_check(capped["mounted"].size() == 1 and _reasons(capped["skipped"]) == "ws_b:too_many", "workshop_max_packs caps one launch")
	_ws.config.workshop_max_packs = old_max

	var odd := _item("ws_a")
	(odd["pack"] as Dictionary)["kinds"] = ["weapon"]
	_world["items"] = [odd]
	_world["revision"] = "w1:thirteen"
	var inc: Dictionary = (await _ws.sync(GAME)).value
	_check(_reasons(inc["skipped"]) == "ws_a:incompatible", "a pack whose kinds the game does not accept is incompatible")


func _check_guest_and_disabled() -> void:
	_line("")
	_line("[b]guest, a refused token, and off[/b]")
	var before := _list_requests()
	_token = ""
	var guest := await _ws.sync(GAME)
	_check(guest.ok and guest.value["guest"] and guest.value["reason"] == "guest" and guest.value["mounted"].is_empty(), "no token: a guest summary, nothing mounted")
	_check(_list_requests() == before, "and no request was made")
	_check(_ws.last_list() == null, "nothing is read from the cache for a guest")

	_token = "tok-bad"
	_world["revision"] = "w1:fourteen"
	var cache_before := DotPaths.list_files_recursive(WORK.path_join("workshop")).size()
	var refused := await _ws.sync(GAME)
	_check(refused.value["guest"] and refused.value["mounted"].is_empty(), "a 401 behaves as a guest")
	_check(DotPaths.list_files_recursive(WORK.path_join("workshop")).size() == cache_before - 1, "and drops that game's cached list", "%d files before" % cache_before)
	_token = "tok-alice"

	_ws.config.workshop_enabled = false
	before = _list_requests()
	var off := await _ws.sync(GAME)
	_check(off.ok and off.value["reason"] == "disabled" and off.value["mounted"].is_empty() and _list_requests() == before, "workshop_enabled=false succeeds with nothing and asks nobody")
	_ws.config.workshop_enabled = true

	var empty := await _ws.sync("")
	_check(not empty.ok and empty.error.code == DotError.CODE_INVALID, "an empty game id is a programmer error")
	var lonely := DotCloudWorkshop.new()
	lonely.register_service = false
	add_child(lonely)
	var no_cloud := await lonely.sync(GAME)
	_check(not no_cloud.ok and no_cloud.error.code == DotError.CODE_STATE, "so is no cloud client")
	lonely.queue_free()


func _check_online_refused() -> void:
	_line("")
	_line("[b]never for an online session[/b]")
	var before := _list_requests()
	_index.set_session(&"online")
	var res := await _ws.sync(GAME)
	_check(not res.ok and res.error.code == DotError.CODE_FORBIDDEN and _list_requests() == before, "an online index session is refused before any request")
	_index.set_session(&"solo")
	var link := Node.new()
	DotRegistry.register(&"dot_client_link", link)
	var linked := await _ws.sync(GAME)
	_check(not linked.ok and linked.error.code == DotError.CODE_FORBIDDEN, "so is a registered client link (a join in progress)")
	DotRegistry.unregister(&"dot_client_link")
	link.free()
	_world["revision"] = "w1:fifteen"
	var back := await _ws.sync(GAME)
	_check(back.ok, "armed: solo again, and it runs")


func _check_scope_write() -> void:
	_line("")
	_line("[b]the panel's scope write[/b]")
	var before := _list_requests()
	var res := await _ws.set_scope("sub-ws_a", false)
	var req := _last_request()
	var body: Variant = JSON.parse_string(str(req.get("body", "")))
	_check(res.ok and req.get("path") == "/api/app/v1/workshop/scope" and req.get("method") == "POST", "set_scope POSTs to the scope route")
	_check(body is Dictionary and body.get("subscriptionId") == "sub-ws_a" and body.get("game") == GAME and body.get("on") == false, "with the subscription, this game and the switch", str(body))
	_check(res.ok and res.value["revision"] == "w1:after", "the answer is handed back")
	var res_all := await _ws.set_all_games("sub-ws_a", true)
	_check(res_all.ok, "set_all_games reaches the site with a device token")
	_token = "tok-game"
	var forbidden := await _ws.set_all_games("sub-ws_a", true)
	_check(not forbidden.ok and forbidden.error.code == DotError.CODE_FORBIDDEN, "a game-bound token is refused as forbidden")
	_token = "tok-alice"
	await _ws.sync(GAME)
	_check(not _last_request().get("query", {}).has("since"), "after a write the next sync fetches the whole list (the cached revision is not trusted)")
	_ws.config.workshop_backbone_url = ""
	var nowhere := await _ws.set_scope("sub-ws_a", true)
	_check(not nowhere.ok and nowhere.error.code == DotError.CODE_STATE, "no backbone configured is a state error")
	_ws.config.workshop_backbone_url = _bb.base_url()
	_check(_list_requests() > before, "armed: the list route was used in this section")


func _check_reporting() -> void:
	_line("")
	_line("[b]reporting and layered config[/b]")
	var lines := _ws.describe_lines()
	_check(lines.size() >= 2 and "\n".join(lines).contains("workshop: on"), "describe_lines says what the Workshop holds", "\n".join(lines).substr(0, 200))
	_check(_ws.describe().has("last"), "describe carries the last sync")
	_check(DotRegistry.get_service(DotCloudWorkshop.SERVICE) == _ws, "registered as dot_workshop")
	var cfg := DotCloudWorkshopConfig.new()
	var applied := cfg.apply_dictionary({"workshop_metered": "never", "workshop_key_ids": ["tmc", "x"]})
	_check(cfg.workshop_metered == "never" and cfg.workshop_key_ids.size() == 2 and cfg.validate().ok, "config layers read workshop_* keys")
	cfg.workshop_script_packs = "bogus"
	_check(not cfg.validate().ok, "armed: a bad script policy fails validation", str(applied))


# --- harness ---------------------------------------------------------------

func _check(ok: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	var suffix := "" if detail == "" else " (%s)" % detail
	_line("  %s %s%s" % ["ok  " if ok else "FAIL", what, suffix])


func _done() -> void:
	_check(_checks + 1 == CHECKS, "every check ran", "%d of %d" % [_checks + 1, CHECKS])
	_line("")
	_line("%d passed, %d failed" % [_checks - _failures, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
