extends Node

## Published mirrors (API 13) against real sockets (an origin, a good mirror, a bad one): the signed list,
## ordering, fallback to the origin, resume, the opt-out, and prefetch.
## Run: godot --headless --path . res://examples/mirror_demo.tscn

const TestServer := preload("res://examples/http_test_server.gd")

const WORK := "user://dot_cloud_mirror_demo"
const DEAD_BASE := "http://127.0.0.1:1"
const ALICE := "alice/map"
const BOB := "bob/level"
const CAROL := "carol/big"
const VERSION := "1.0.0"

## Every check this suite runs, including the one that compares against it.
const CHECKS := 67

var _failures := 0
var _checks := 0
var _sections_entered := 0
var _sections_completed := 0

var _platform: Dictionary = {}
var _alice_key: Dictionary = {}
var _origin: Node = null
var _good: Node = null
var _bad: Node = null
var _payload: DotCloudFile = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	print("dot-cloud published mirrors")
	DotPaths.remove_tree(WORK)

	var k1 := DotCloudSignature.generate_keypair(2048)
	var k2 := DotCloudSignature.generate_keypair(2048)
	if not k1.ok or not k2.ok:
		_check("keygen", false)
		_finish()
		return
	_platform = k1.value
	_alice_key = k2.value

	var origin_dir := WORK.path_join("origin")
	for spec: Array in [[ALICE, 256 * 1024], [BOB, 0], [CAROL, 256 * 1024]]:
		var published := _publish(str(spec[0]), int(spec[1]), origin_dir)
		if not published.ok:
			_check("publish %s" % spec[0], false, str(published.error))
			_finish()
			return
	DotPaths.write_text(origin_dir.path_join("_site/avatars/a.txt"), "avatar\n")

	var alice_manifest := _read_manifest(origin_dir, ALICE)
	_payload = _largest(alice_manifest)

	_copy_tree(origin_dir, WORK.path_join("m_good"))
	_copy_tree(origin_dir, WORK.path_join("m_bad"))
	_origin = _serve("Origin", origin_dir)
	_good = _serve("Good", WORK.path_join("m_good"))
	_bad = _serve("Bad", WORK.path_join("m_bad"))
	if _origin == null or _good == null or _bad == null:
		_check("test servers listen", false)
		_finish()
		return

	_test_parse()
	_test_bases()
	await _test_corrupt_mirror()
	await _test_dead_mirror()
	await _test_resume_from_mirror()
	await _test_opt_out()
	await _test_prefetch()
	await _test_rollback()

	_check("every section ran to completion", _sections_completed == _sections_entered,
		"%d/%d" % [_sections_completed, _sections_entered])
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("%d checks, %d failed" % [_checks, _failures])
	_finish()




func _test_parse() -> void:
	_sections_entered += 1
	print("[section] signed list")
	var keys := _trusted()
	var now := int(Time.get_unix_time_from_system())
	var three := [
		_mirror("m1", "https://m1.example", ["alice/*"], true),
		_mirror("m2", "https://m2.example", ["*"], false),
		_mirror("m3", "https://m3.example/", ["bob/level"], true),
	]
	var good := DotCloudMirrorList.parse_signed(_signed(_list("https://cdn.example", three)), keys, now)
	_check("a signed list is accepted", good.ok, "" if good.ok else str(good.error))
	if good.ok:
		var list: DotCloudMirrorList = good.value
		_check("with every mirror", list.mirrors.size() == 3, str(list.mirrors.size()))
		_check("a trailing slash is trimmed", str(list.mirrors[2]["base_url"]) == "https://m3.example")

	var env: Dictionary = JSON.parse_string(_signed(_list("https://cdn.example", three)).get_string_from_utf8())
	env["payload"] = DotHash.base64url_encode(JSON.stringify(_list("https://evil.example", three)).to_utf8_buffer())
	var tampered := DotCloudMirrorList.parse_signed(JSON.stringify(env).to_utf8_buffer(), keys, now)
	_check("a tampered payload is refused", not tampered.ok and tampered.code() == DotError.CODE_INTEGRITY,
		"" if tampered.ok else tampered.code())

	var stale := _list("https://cdn.example", three)
	stale["expires_at"] = now - 10
	_check("an expired list is refused", not DotCloudMirrorList.parse_signed(_signed(stale), keys, now).ok)

	var scoped := DotCloudMirrorList.parse_signed(
		_signed(_list("https://cdn.example", three), str(_alice_key["private"]), "alice"), keys, now)
	_check("a key scoped to alice/* cannot sign it", not scoped.ok and scoped.code() == DotError.CODE_FORBIDDEN,
		"" if scoped.ok else scoped.code())

	var bare := JSON.stringify(_list("https://cdn.example", three)).to_utf8_buffer()
	_check("an unsigned list is refused", not DotCloudMirrorList.parse_signed(bare, keys, now).ok)

	var wrong := _list("https://cdn.example", three)
	wrong["kind"] = "dot_cloud_prefetch"
	_check("the wrong kind is refused", not DotCloudMirrorList.parse_signed(_signed(wrong), keys, now).ok)
	var newer := _list("https://cdn.example", three)
	newer["format"] = 2
	_check("a newer format is refused", not DotCloudMirrorList.parse_signed(_signed(newer), keys, now).ok)

	var mixed := [
		_mirror("ftp", "ftp://m.example", ["*"], false),
		_mirror("user", "https://u:p@m.example", ["*"], false),
		_mirror("query", "https://m.example/?x=1", ["*"], false),
		_mirror("frag", "https://m.example/#x", ["*"], false),
		"not an object",
		_mirror("ok", "https://ok.example", ["*"], false),
	]
	var some := DotCloudMirrorList.parse_signed(_signed(_list("https://cdn.example", mixed)), keys, now)
	_check("bad mirror urls are dropped one by one", some.ok
		and (some.value as DotCloudMirrorList).mirrors.size() == 1
		and (some.value as DotCloudMirrorList).dropped.size() == 5,
		"" if not some.ok else str((some.value as DotCloudMirrorList).describe()))
	_check("an origin with user info is refused",
		not DotCloudMirrorList.parse_signed(_signed(_list("https://u@cdn.example", three)), keys, now).ok)

	var many := []
	for i in 65:
		many.append(_mirror("m%d" % i, "https://m%d.example" % i, ["*"], false))
	_check("more than 64 mirrors is refused",
		not DotCloudMirrorList.parse_signed(_signed(_list("https://cdn.example", many)), keys, now).ok)

	var chunked := DotCloudFile.from_dict({
		"path": "a.bin", "sha256": "ab".repeat(32), "size": 3,
		"chunks": {"algo": "fastcdc-v1", "avg": 1048576, "min": 262144, "max": 4194304, "list": [["ab".repeat(32), 3]]},
	})
	_check("a file entry with chunks still parses", chunked.ok, "" if chunked.ok else str(chunked.error))
	_sections_completed += 1


func _test_bases() -> void:
	_sections_entered += 1
	print("[section] pack_bases, alternatives, order")
	var list := _parsed([
		_mirror("m1", "https://m1.example", ["alice/*"], true),
		_mirror("m2", "https://m2.example", ["*"], false),
		_mirror("m3", "https://m3.example", ["bob/level"], true),
	], "https://cdn.example")
	if list == null:
		_check("list parsed", false)
		return
	_check("pack_bases matches owner/*", Array(list.pack_bases(ALICE)) == ["https://m1.example/content", "https://m2.example/content"],
		str(list.pack_bases(ALICE)))
	_check("pack_bases matches an exact id", Array(list.pack_bases(BOB)) == ["https://m2.example/content", "https://m3.example/content"],
		str(list.pack_bases(BOB)))
	_check("only * carries other packs", Array(list.pack_bases("carol/x")) == ["https://m2.example/content"])
	_check("alternatives are on avatar mirrors only",
		Array(list.alternatives("https://cdn.example/_site/avatars/a.png"))
			== ["https://m1.example/_site/avatars/a.png", "https://m3.example/_site/avatars/a.png"],
		str(list.alternatives("https://cdn.example/_site/avatars/a.png")))
	_check("a lookalike host has no alternatives", list.alternatives("https://cdn.example.evil/x").is_empty())

	var src := DotCloudSourceHttp.new()
	src.base_urls = PackedStringArray(["https://cdn.example/content"])
	src.mirror_list = list
	var m := DotCloudManifest.new()
	m.content_id = ALICE
	m.version = VERSION
	m.mirrors = PackedStringArray(["https://cdn.example/content/alice/map/1.0.0"])
	var order := Array(src.bases_for(m))
	_check("published mirrors first, the origin last", order == [
		"https://m1.example/content/alice/map/1.0.0", "https://m2.example/content/alice/map/1.0.0",
		"https://cdn.example/content/alice/map/1.0.0", "https://cdn.example/content",
	], str(order))
	src._note_base_failure("https://m1.example/content/alice/map/1.0.0")
	src._note_base_failure("https://m1.example/content/alice/map/1.0.0")
	order = Array(src.bases_for(m))
	_check("a base that failed twice is tried last, not removed",
		order.size() == 4 and order[3] == "https://m1.example/content/alice/map/1.0.0", str(order))
	_sections_completed += 1


func _test_corrupt_mirror() -> void:
	_sections_entered += 1
	print("[section] corrupt mirror")
	_publish_list([_mirror("bad", _bad.base_url(), ["*"], false)])
	var obj := "/content/alice/map/1.0.0/objects/%s" % _payload.object_path()
	_bad.corrupt_paths = PackedStringArray([obj])
	_clear_logs()
	var client := await _client("corrupt", true)
	if client == null:
		return
	_check("the mirror list loaded", client.mirror_list() != null and client.mirror_list().mirrors.size() == 1)
	var res := await client.ensure(StringName(ALICE), VERSION)
	_check("acquired despite the corrupt mirror", res.ok, "" if res.ok else str(res.error))
	_check("the mirror was asked first", _served(_bad, "GET " + obj))
	_check("the origin served the object", _served(_origin, "GET " + obj))
	_check("the object committed verified", client.store.has(_payload.sha256))
	_check("the manifest never came from the mirror", not _served_part(_bad, "manifest.json"))
	_bad.corrupt_paths = PackedStringArray()
	_drop(client)
	_sections_completed += 1


func _test_dead_mirror() -> void:
	_sections_entered += 1
	print("[section] dead mirror")
	_publish_list([_mirror("dead", DEAD_BASE, ["*"], false)])
	_clear_logs()
	var client := await _client("dead", true)
	if client == null:
		return
	var src := _http_source(client)
	src.failure_threshold = 1
	var res := await client.ensure(StringName(ALICE), VERSION)
	_check("acquired from the origin", res.ok, "" if res.ok else str(res.error))
	_check("the dead mirror did not trip the source breaker", src.is_available(), str(src.health()))
	var h := src.health()
	var dead_base := DEAD_BASE + "/content/alice/map/1.0.0"
	_check("the dead mirror is demoted", (h["cooling_bases"] as Array).has(dead_base), str(h["cooling_bases"]))
	var manifest := client.manifest_for(DotCloudClient.content_key_for(StringName(ALICE), VERSION))
	var order := src.bases_for(manifest) if manifest != null else PackedStringArray()
	_check("and is now tried after the origin", not order.is_empty() and order[order.size() - 1] == dead_base, str(order))
	_check("every object came from the origin", _object_lines(_origin) >= manifest.unique_hashes().size() if manifest != null else false)
	_drop(client)
	_sections_completed += 1


func _test_resume_from_mirror() -> void:
	_sections_entered += 1
	print("[section] resume from a mirror")
	_publish_list([_mirror("good", _good.base_url(), ["alice/*"], true)])
	var client := await _client("resume", true)
	if client == null:
		return
	var whole := FileAccess.get_file_as_bytes(WORK.path_join("origin/content/alice/map/1.0.0/objects/%s" % _payload.object_path()))
	DotPaths.write_bytes(client.store.partial_path(_payload.sha256), whole.slice(0, whole.size() / 2))
	_clear_logs()
	var res := await client.ensure(StringName(ALICE), VERSION)
	var obj := "/content/alice/map/1.0.0/objects/%s" % _payload.object_path()
	_check("acquired with a partial present", res.ok, "" if res.ok else str(res.error))
	_check("the mirror was asked for a range", _served_prefix(_good, "GET %s (range" % obj), str(_good.log))
	_check("the origin was not asked for it", not _served_part(_origin, obj))
	_check("the resumed object verified", client.store.has(_payload.sha256))
	_check("the mirror sent less than the object", _good.bytes_sent < whole.size(), "%d of %d" % [_good.bytes_sent, whole.size()])
	var avatar: String = _origin.base_url() + "/_site/avatars/a.txt"
	_check("mirror_alternatives names the avatar mirror",
		Array(client.mirror_alternatives(avatar)) == [_good.base_url() + "/_site/avatars/a.txt"],
		str(client.mirror_alternatives(avatar)))
	_drop(client)
	_sections_completed += 1


func _test_opt_out() -> void:
	_sections_entered += 1
	print("[section] use_mirrors = false")
	_publish_list([_mirror("good", _good.base_url(), ["*"], true)])
	_clear_logs()
	var client := await _client("optout", false)
	if client == null:
		return
	var res := await client.ensure(StringName(ALICE), VERSION)
	_check("acquired", res.ok, "" if res.ok else str(res.error))
	_check("the mirror was never contacted", _good.log.is_empty(), str(_good.log))
	_check("the origin served the objects", _object_lines(_origin) > 0)
	_check("no alternatives are offered", client.mirror_alternatives(_origin.base_url() + "/_site/avatars/a.txt").is_empty())
	_check("the source has no mirror list", _http_source(client).mirror_list == null)
	var loaded := await client.load_mirror_list()
	_check("load_mirror_list is a successful no-op", loaded.ok and loaded.value == null)
	_drop(client)

	var broken := await _client("broken", true, _origin.base_url() + "/content/nope.json")
	if broken != null:
		var again := await broken.load_mirror_list()
		_check("a missing list fails without breaking the client", not again.ok and broken.mirror_list() == null)
		var still := await broken.ensure(StringName(ALICE), VERSION)
		_check("and delivery still works from the origin", still.ok, "" if still.ok else str(still.error))
		_drop(broken)
	_sections_completed += 1


func _test_rollback() -> void:
	_sections_entered += 1
	print("[section] an older signed list never replaces a newer one")
	var now := int(Time.get_unix_time_from_system())
	var keys := _trusted()
	var old := _list("https://cdn.example", [])
	old["issued_at"] = now - 600
	_check("a list older than the newest seen is refused", not DotCloudMirrorList.parse_signed(_signed(old), keys, now, now - 60).ok)
	_check("the same issue time is accepted again", DotCloudMirrorList.parse_signed(_signed(old), keys, now, now - 600).ok)

	var mirrors := [_mirror("good", _good.base_url(), ["*"], true)]
	_publish_list(mirrors, now)
	var client := await _client("rollback", true)
	if client == null:
		return
	var first := await client.load_mirror_list("", false)
	_check("the current list loads", first.ok and client.mirror_list() != null and client.mirror_list().issued_at == now)
	_publish_list(mirrors, now - 600)
	var replay := await client.load_mirror_list("", false)
	_check("a replayed older list is refused and the newer one stays", not replay.ok and client.mirror_list().issued_at == now)
	_drop(client)
	var fresh := await _client("rollback", true)
	if fresh == null:
		return
	replay = await fresh.load_mirror_list("", false)
	_check("a restarted client still refuses it (the newest is kept on disk)", not replay.ok)
	_publish_list(mirrors, now + 5)
	var newer := await fresh.load_mirror_list("", false)
	_check("a newer list is taken", newer.ok and fresh.mirror_list().issued_at == now + 5)
	_drop(fresh)
	_sections_completed += 1


func _test_prefetch() -> void:
	_sections_entered += 1
	print("[section] prefetch")
	var client := await _client("prefetch", false)
	if client == null:
		return
	client.config.prefetch_max_bytes = 64 * 1024
	client.config.prefetch_max_packs = 2
	var bob_manifest := _read_manifest(WORK.path_join("origin"), BOB)
	var bob_bytes := 0
	for h in bob_manifest.unique_hashes():
		for f in bob_manifest.files:
			if f.sha256 == h:
				bob_bytes += f.size
				break
	var doc := _prefetch_doc([[BOB, VERSION], [CAROL, VERSION], [ALICE, VERSION]])
	var res := await client.prefetch(doc)
	_check("prefetch succeeded", res.ok, "" if res.ok else str(res.error))
	if res.ok:
		var v: Dictionary = res.value
		_check("one pack fetched, two skipped (bytes, pack cap)",
			int(v["packs_fetched"]) == 1 and int(v["packs_skipped"]) == 2, str(v))
		_check("bytes counts what was fetched", int(v["bytes"]) == bob_bytes, "%d vs %d" % [int(v["bytes"]), bob_bytes])
		_check("avatar_library is passed through", str(v["avatar_library"]) == "https://site.example/lib")
	var bob_in := true
	for h in bob_manifest.unique_hashes():
		bob_in = bob_in and client.store.has(h) and client.store.ref_count(h) == 0
	_check("the pack's objects are in the store, unreferenced", bob_in)
	_check("the over-budget pack was not fetched", not client.store.has(_largest(_read_manifest(WORK.path_join("origin"), CAROL)).sha256))
	_check("nothing was mounted", client.acquired_keys().is_empty() and not client.is_mounted(StringName(BOB), VERSION))

	var bad_kind := doc.duplicate(true)
	bad_kind["kind"] = "dot_cloud_mirrors"
	_check("the wrong kind is refused", not (await client.prefetch(bad_kind)).ok)
	_check("a traversal id is refused", not (await client.prefetch(_prefetch_doc([["../x", VERSION]]))).ok)
	_check("a traversal version is refused", not (await client.prefetch(_prefetch_doc([[BOB, "../.."]]))).ok)
	var no_packs := doc.duplicate(true)
	no_packs.erase("packs")
	_check("a document without packs is refused", not (await client.prefetch(no_packs)).ok)
	_drop(client)

	var roomy := await _client("prefetch2", false)
	if roomy == null:
		return
	var carol := await roomy.prefetch(_prefetch_doc([[CAROL, VERSION]]))
	_check("a pack within budget is fetched", carol.ok and int(carol.value["packs_fetched"]) == 1,
		"" if carol.ok else str(carol.error))
	_clear_logs()
	var mounted := await roomy.ensure(StringName(CAROL), VERSION)
	_check("the later join mounts it", mounted.ok, "" if mounted.ok else str(mounted.error))
	_check("without downloading an object again", _object_lines(_origin) == 0, str(_origin.log))
	_drop(roomy)
	_sections_completed += 1




func _trusted() -> Dictionary:
	return {
		"platform": str(_platform["public"]),
		"alice": {"key": str(_alice_key["public"]), "content_ids": ["alice/*"]},
	}


func _mirror(id: String, base: String, packs: Array, avatars: bool) -> Dictionary:
	return {"id": id, "base_url": base, "operator": "op-" + id, "regions": ["eu"], "packs": packs, "avatars": avatars}


func _list(origin: String, mirrors: Array) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	return {
		"format": 1, "kind": "dot_cloud_mirrors", "issued_at": now, "expires_at": now + 3600,
		"origin": origin, "mirrors": mirrors,
	}


func _signed(d: Dictionary, pem: String = "", key_id: String = "platform") -> PackedByteArray:
	var bytes := JSON.stringify(d).to_utf8_buffer()
	var sig := DotCloudSignature.sign(bytes, pem if pem != "" else str(_platform["private"]))
	return DotCloudEnvelope.wrap(bytes, str(sig.value), key_id).to_utf8_buffer()


func _parsed(mirrors: Array, origin: String) -> DotCloudMirrorList:
	var res := DotCloudMirrorList.parse_signed(_signed(_list(origin, mirrors)), _trusted(), int(Time.get_unix_time_from_system()))
	return res.value if res.ok else null


## Writes the signed list into the origin and both mirror roots (rank probes each mirror's copy).
func _publish_list(mirrors: Array, issued_at: int = 0) -> void:
	var d := _list(_origin.base_url(), mirrors)
	if issued_at > 0:
		d["issued_at"] = issued_at
	var bytes := _signed(d)
	for dir in ["origin", "m_good", "m_bad"]:
		DotPaths.write_bytes(WORK.path_join(dir).path_join("content/mirrors.json"), bytes)


func _prefetch_doc(packs: Array) -> Dictionary:
	var list := []
	for p: Array in packs:
		list.append({"id": p[0], "version": p[1], "bytes": 0})
	return {
		"format": 1, "kind": "dot_cloud_prefetch", "server_id": 12, "app_id": 3, "packs": list,
		"avatar_library": "https://site.example/lib",
	}


func _client(tag: String, use_mirrors: bool, mirrors_url: String = "") -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_%s" % tag)
	config.trusted_keys = _trusted()
	config.resume_downloads = true
	config.parallel_downloads = 1
	config.file_timeout_sec = 10.0
	config.use_mirrors = use_mirrors
	config.mirrors_url = mirrors_url if mirrors_url != "" else _origin.base_url() + "/content/mirrors.json"
	var client := DotCloudClient.new()
	client.name = "Cloud_%s" % tag
	client.config = config
	client.config_file = ""
	client.register_service = false
	client.http_base_urls = PackedStringArray([_origin.base_url() + "/content"])
	client.allow_netchan_fallback = false
	add_child(client)
	var started := await client.start()
	if not started.ok:
		_check("client %s started" % tag, false, str(started.error))
		client.queue_free()
		return null
	return client


func _drop(client: DotCloudClient) -> void:
	remove_child(client)
	client.queue_free()


func _http_source(client: DotCloudClient) -> DotCloudSourceHttp:
	for s in client.sources:
		if s is DotCloudSourceHttp:
			return s as DotCloudSourceHttp
	return null


func _publish(id: String, big: int, origin_dir: String) -> DotResult:
	var src := WORK.path_join("src_" + id.replace("/", "_"))
	DotPaths.ensure_dir(src)
	if big > 0:
		var bytes := PackedByteArray()
		bytes.resize(big)
		for i in bytes.size():
			bytes[i] = (i * 31 + (i >> 8) + id.length()) & 0xFF
		DotPaths.write_bytes(src.path_join("payload.bin"), bytes)
	DotPaths.write_text(src.path_join("readme.txt"), "pack %s\n" % id)
	DotPaths.write_text(src.path_join("data/config.json"), "{\"id\": \"%s\"}\n" % id)
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = VERSION
	pub.signing_key_pem = str(_platform["private"])
	pub.signing_key_id = "platform"
	return pub.publish(src, origin_dir.path_join("content/%s/%s" % [id, VERSION]))


func _read_manifest(origin_dir: String, id: String) -> DotCloudManifest:
	var bytes := FileAccess.get_file_as_bytes(origin_dir.path_join("content/%s/%s/manifest.json" % [id, VERSION]))
	var res := DotCloudManifest.from_json_bytes(bytes)
	return res.value if res.ok else DotCloudManifest.new()


func _largest(m: DotCloudManifest) -> DotCloudFile:
	var best: DotCloudFile = null
	for f in m.files:
		if best == null or f.size > best.size:
			best = f
	return best


func _copy_tree(from: String, to: String) -> void:
	for rel in DotPaths.list_files_recursive(from):
		var r := str(rel).trim_prefix(from).trim_prefix("/")
		DotPaths.write_bytes(to.path_join(r), FileAccess.get_file_as_bytes(from.path_join(r)))


func _serve(tag: String, root: String) -> Node:
	var srv := TestServer.new()
	srv.name = tag
	srv.root = root
	add_child(srv)
	var started: DotResult = srv.start(0)
	return srv if started.ok else null


func _clear_logs() -> void:
	for s: Node in [_origin, _good, _bad]:
		s.log.clear()
		s.bytes_sent = 0


func _served(srv: Node, line: String) -> bool:
	return Array(srv.log).has(line)


func _served_prefix(srv: Node, prefix: String) -> bool:
	for l in srv.log:
		if str(l).begins_with(prefix):
			return true
	return false


func _served_part(srv: Node, part: String) -> bool:
	for l in srv.log:
		if str(l).contains(part):
			return true
	return false


func _object_lines(srv: Node) -> int:
	var n := 0
	for l in srv.log:
		if str(l).contains("/objects/"):
			n += 1
	return n


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("  %s %s%s" % [label.rpad(52), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])


func _finish() -> void:
	for s: Node in [_origin, _good, _bad]:
		if s != null:
			s.stop()
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)
