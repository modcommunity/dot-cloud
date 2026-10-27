extends Node

## DotCloudLock and DotCloudClient.ensure_locked: the CDN precedence and download-list rules of fetch_lock.sh, then a real mount from a lock.
## Run: godot --headless --path . res://examples/lock_demo.tscn

const WORK := "user://dot_cloud_lock_demo"
const CHECKS := 35
const SECTIONS := 4

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0
var _keys: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	print("dot-cloud lock file")
	DotPaths.remove_tree(WORK)
	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		_finish(1)
		return
	_keys = keys.value
	_section_bases()
	_section_lists()
	await _section_mount()
	_section_parser()
	_check("every section finished", _sections_started == SECTIONS and _sections_finished == SECTIONS, "%d of %d" % [_sections_finished, SECTIONS])
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


func _bases(doc: Dictionary, opts: Dictionary, env_file: String = "") -> Array:
	return Array(DotCloudLock.resolve_bases(doc, opts, env_file))


func _section_bases() -> void:
	_begin("cdn precedence")
	var doc := {"origin": "https://dev.example/content", "mirrors": ["https://m.example/c/"]}
	var envf := WORK.path_join("bootstrap.env")
	DotPaths.write_text(envf, "# c\nDOT_CDN_URL=\"https://envfile.example\"\n")
	_check("lock origin then mirrors", _bases(doc, {"environment": {}}) == ["https://dev.example/content", "https://m.example/c"])
	_check("default dotgames.org", _bases({}, {"environment": {}}) == ["https://dotgames.org/content"])
	_check("env file beats lock", _bases(doc, {"environment": {}}, envf) == ["https://envfile.example/content"])
	_check("DOT_CDN_URL beats env file", _bases(doc, {"environment": {"DOT_CDN_URL": "https://e.example/content"}}, envf) == ["https://e.example/content"])
	_check("--cdn beats DOT_CDN_URL", _bases(doc, {"cdn": "https://c.example", "environment": {"DOT_CDN_URL": "https://e.example"}}, envf) == ["https://c.example/content"])
	_check("DOT_PACKS_FROM beats cdn", _bases(doc, {"cdn": "https://c.example", "environment": {"DOT_PACKS_FROM": "/srv/packs"}}) == ["/srv/packs"])
	_check("--from beats everything", _bases(doc, {"from": "https://f.example/x/", "cdn": "https://c.example", "environment": {"DOT_PACKS_FROM": "/srv"}}) == ["https://f.example/x"])
	_check("none fetches nothing", _bases(doc, {"environment": {"DOT_PACKS_FROM": "none"}}).is_empty())
	_end()


func _lock_dir(tag: String, packs: Array) -> String:
	var dir := WORK.path_join(tag)
	DotPaths.write_text(dir.path_join("content.lock.json"), JSON.stringify({"format": 1, "origin": "https://o.example/content", "packs": packs}))
	return dir


func _load(dir: String, opts: Dictionary = {}) -> DotCloudLock:
	opts["environment"] = {}
	opts["env_file"] = ""
	return DotCloudLock.load_file(dir.path_join("content.lock.json"), opts).value


func _ids(lock: DotCloudLock) -> Array:
	return lock.packs.map(func(p: Dictionary) -> String: return p["id"])


func _section_lists() -> void:
	_begin("cfg/content lists")
	var packs := [
		{"id": "o/zz-a", "version": "1", "manifest_sha256": "x", "into": "", "kind": "pack"},
		{"id": "o/zz-b", "version": "1", "manifest_sha256": "x", "into": "", "kind": "pack"},
		{"id": "o/zz-c", "version": "1", "manifest_sha256": "x", "into": ".stores", "kind": "store"},
	]
	_check("no cfg: all wanted", _ids(_load(_lock_dir("l0", packs))).size() == 3)
	var d1 := _lock_dir("l1", packs)
	DotPaths.write_text(d1.path_join("cfg/content/games.yml"), "merge: true\nremove: [o/zz-a]\n")
	_check("remove: drops a pack", _ids(_load(d1)) == ["o/zz-b", "o/zz-c"])
	var d2 := _lock_dir("l2", packs)
	DotPaths.write_text(d2.path_join("cfg/content/zz-b/disabled"), "")
	_check("disabled file drops it", _ids(_load(d2)) == ["o/zz-a", "o/zz-c"])
	var d3 := _lock_dir("l3", packs)
	DotPaths.write_text(d3.path_join("cfg/content/games.yml"), "entries:\n  - pack: o/zz-b\n  - repo: game-x\n")
	_check("pack: entries name the packs", _ids(_load(d3)) == ["o/zz-b", "o/zz-c"], str(_ids(_load(d3))))
	var d4 := _lock_dir("l4", packs)
	DotPaths.write_text(d4.path_join("cfg/content/games.yml"), "merge: true\nentries: [o/zz-b]\n")
	_check("merge: true names nothing", _ids(_load(d4)).size() == 3)
	DotPaths.write_text(d4.path_join("cfg/server/content/addons.yml"), "remove:\n  - zz-c\n")
	_check("server layer remove by name half", _ids(_load(d4)) == ["o/zz-a", "o/zz-b"])
	_check("--only keeps matches", _ids(_load(_lock_dir("l5", packs), {"only": ["zz-*"], "skip": ["store"]})) == ["o/zz-a", "o/zz-b"])
	var l := _load(d1)
	_check("skipped says why", l.skipped.size() == 1 and l.skipped[0]["why"] == "removed in cfg/content")
	_check("no lock: nothing pinned", DotCloudLock.load_file(WORK.path_join("none.json")).value.packs.is_empty())
	_check("bad format refused", not DotCloudLock.load_file(_write("bad.json", '{"format": 2}')).ok)
	_end()


func _write(name: String, text: String) -> String:
	var path := WORK.path_join(name)
	DotPaths.write_text(path, text)
	return path


func _section_mount() -> void:
	_begin("ensure_locked")
	var src := WORK.path_join("src")
	DotPaths.write_text(src.path_join("a.txt"), "locked a\n")
	DotPaths.write_text(WORK.path_join("src2/b.txt"), "locked b\n")
	var pub_root := WORK.path_join("published")
	_publish("lk_a", "1", src, pub_root)
	_publish("lk_b", "1", WORK.path_join("src2"), pub_root)
	var sha_a := str(DotHash.sha256_file(pub_root.path_join("lk_a/1/manifest.json")).value)
	var sha_b := str(DotHash.sha256_file(pub_root.path_join("lk_b/1/manifest.json")).value)
	var packs := [
		{"id": "lk_a", "version": "1", "manifest_sha256": sha_a, "kind": "pack"},
		{"id": "lk_s", "version": "1", "manifest_sha256": "0", "into": ".stores/x", "kind": "store"},
		{"id": "lk_gone", "version": "1", "manifest_sha256": "0", "kind": "pack", "optional": true},
	]
	var dir := _lock_dir("m1", packs)
	var client := _client("m1")
	var got := await client.ensure_locked(dir.path_join("content.lock.json"), {"from": pub_root, "environment": {}, "env_file": ""})
	_check("lock mounts", got.ok, str(got.error) if not got.ok else "")
	_check("mounted the pack", got.ok and got.value["mounted"] == ["lk_a@1"], str(got.value) if got.ok else "")
	_check("file readable", FileAccess.file_exists("res://dot_cloud/lk_a/1/a.txt"))
	_check("store and missing optional skipped", got.ok and got.value["skipped"].size() == 2)
	_check("none fetches nothing", (await client.ensure_locked(dir.path_join("content.lock.json"), {"from": "none"})).value["mounted"].is_empty())
	client.queue_free()
	# Armed: a wrong pin is refused, a right one from the second base mounts.
	var bad := _lock_dir("m2", [{"id": "lk_b", "version": "1", "manifest_sha256": "f".repeat(64), "kind": "pack"}])
	var c2 := _client("m2")
	var r2 := await c2.ensure_locked(bad.path_join("content.lock.json"), {"from": pub_root, "environment": {}, "env_file": ""})
	_check("wrong manifest pin refused", not r2.ok and not c2.is_mounted(&"lk_b", "1"))
	c2.queue_free()
	var ok := _lock_dir("m3", [{"id": "lk_b", "version": "1", "manifest_sha256": sha_b, "kind": "pack"}])
	var c3 := _client("m3")
	var r3 := await c3.ensure_locked(ok.path_join("content.lock.json"), {"environment": {}, "env_file": "", "cdn": ""})
	_check("unreachable lock origin fails", not r3.ok)
	var r4 := await c3.ensure_locked(ok.path_join("content.lock.json"), {"from": pub_root, "environment": {}, "env_file": ""})
	_check("right pin mounts", r4.ok and c3.is_mounted(&"lk_b", "1"))
	DotPaths.write_text(ok.path_join("cfg/content/lk_b/disabled"), "")
	var r5 := await c3.ensure_locked(ok.path_join("content.lock.json"), {"from": pub_root, "environment": {}, "env_file": ""})
	_check("disabled skipped", r5.ok and r5.value["mounted"].is_empty() and r5.value["skipped"].size() == 1)
	c3.queue_free()
	_end()


func _section_parser() -> void:
	_begin("yml subset")
	var l := DotCloudLock.parse_list("merge: true # c\nremove: [dot-voice, a/b@1]\nentries:\n  - dot-core\n  - dot-vote@v0.2.1\n  - repo: game-arena\n    pin: v1\n  - pack: o/p@1.2.0\n")
	_check("merge", l["merge"] == true)
	_check("flow remove", l["remove"] == [["repo", "dot-voice"], ["pack", "a/b"]])
	_check("block entries", l["entries"] == [["repo", "dot-core"], ["repo", "dot-vote"], ["repo", "game-arena"], ["pack", "o/p"]], str(l["entries"]))
	_check("dotenv", DotCloudLock.parse_dotenv(_write("e.env", "A=1\n#B=2\nC = 'x y'\n")) == {"A": "1", "C": "x y"})
	_end()


func _publish(id: String, version: String, src: String, pub_root: String) -> void:
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = version
	pub.signing_key_pem = str(_keys["private"])
	pub.signing_key_id = "demo"
	var res := pub.publish(src, pub_root.path_join(id).path_join(version))
	_check("publish %s" % id, res.ok, str(res.error) if not res.ok else "")


func _client(tag: String) -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_" + tag)
	config.require_signed_manifests = true
	config.trusted_keys = {"demo": str(_keys["public"])}
	var client := DotCloudClient.new()
	client.name = "Cloud_" + tag
	client.config = config
	client.config_file = ""
	client.register_service = false
	client.allow_netchan_fallback = false
	add_child(client)
	return client


func _begin(name: String) -> void:
	_sections_started += 1
	print("\n[%s]" % name)


func _end() -> void:
	_sections_finished += 1


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("  %s %s%s" % [label.rpad(36), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])


func _finish(code: int) -> void:
	await get_tree().process_frame
	get_tree().quit(code)
