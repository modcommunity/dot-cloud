extends Node

## Content that depends on other content (dot-cloud API 15): a shared store published once, packs naming it.
##
## Covered: the list in the signed payload and a tampered version failing the signature, a pack acquiring its store
## first, a second pack skipping the store it shares, a store missing from every source refusing the pack before it
## mounts, a loop refused instead of awaited, the manifest's own refusals, and the CLI-less parser.
##
## [codeblock]
## godot --headless --path . res://examples/dependency_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_dependency_demo"
const CHECKS := 41
const SECTIONS := 7

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0
var _keys: Dictionary = {}
var _ready_keys: PackedStringArray = PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	print("dot-cloud dependencies (API 15)")
	DotPaths.remove_tree(WORK)
	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		print("keygen failed: %s" % keys.error)
		_finish(1)
		return
	_keys = keys.value
	_publish("lib_store", "1", {"pbr/a.bin": "albedo of a\n", "pbr/b.bin": "albedo of b\n"}, [])
	_publish("map_a", "1", {"map.txt": "map a\n"}, [{"id": "lib_store", "version": "1"}])
	_publish("map_b", "1", {"map.txt": "map b\n"}, [{"id": "lib_store", "version": "1"}])

	await _section_payload()
	await _section_shared_store()
	await _section_missing()
	await _section_loop()
	await _section_manifest_rules()
	await _section_nested()
	_section_vram_tags()

	_check("every section finished", _sections_started == SECTIONS and _sections_finished == SECTIONS, "%d of %d" % [_sections_finished, SECTIONS])
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("")
	print("%d checks, %d failed" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


func _section_payload() -> void:
	_begin("payload")
	var m := _read("map_a", "1")
	_check("dependency parsed", m != null and m.dependencies.size() == 1 and m.dependencies[0]["id"] == "lib_store")
	if m == null:
		return
	var text := m.raw_bytes.get_string_from_utf8()
	_check("dependency in the signed payload", text.contains('"dependencies"'))
	var forged := text.replace('"version": "1"\n\t\t}\n\t],\n\t"files"', '"version": "2"\n\t\t}\n\t],\n\t"files"').to_utf8_buffer()
	_check("forged text differs", forged != m.raw_bytes)
	_check("forged dependency refused", not DotCloudSignature.verify(forged, m.signature, str(_keys["public"])).ok)
	_check("store has none", _read("lib_store", "1").dependencies.is_empty())
	_check("none writes no key", not _read("lib_store", "1").to_dict().has("dependencies"))
	_end()


func _section_shared_store() -> void:
	_begin("shared store")
	var client := _client("shared")
	_ready_keys.clear()
	client.content_ready.connect(func(m: DotCloudManifest, _p: String) -> void: _ready_keys.append(m.key()))
	var a := await client.ensure(&"map_a", "1")
	_check("map a mounts", a.ok, str(a.error) if not a.ok else "")
	_check("store mounted first", _ready_keys.size() == 2 and _ready_keys[0] == "lib_store@1", str(_ready_keys))
	_check("store file readable", FileAccess.file_exists("res://dot_cloud/lib_store/1/pbr/a.bin"))
	_check("dependency_prefix answers", client.dependency_prefix(&"lib_store", "1") == "res://dot_cloud/lib_store/1")
	var b := await client.ensure(&"map_b", "1")
	_check("map b mounts", b.ok, str(b.error) if not b.ok else "")
	_check("store not fetched again", _ready_keys.size() == 3 and _ready_keys[2] == "map_b@1", str(_ready_keys))
	client.queue_free()
	_end()


func _section_missing() -> void:
	_begin("missing store")
	_publish("map_c", "1", {"map.txt": "map c\n"}, [{"id": "lib_store", "version": "9"}])
	var client := _client("missing")
	var got := await client.ensure(&"map_c", "1")
	_check("pack refused", not got.ok)
	_check("says what it needed", not got.ok and str(got.error).contains("lib_store@9"), str(got.error) if not got.ok else "")
	_check("pack not mounted", not client.is_mounted(&"map_c", "1") and not FileAccess.file_exists("res://dot_cloud/map_c/1/map.txt"))
	client.queue_free()
	_end()


func _section_loop() -> void:
	_begin("loop")
	_publish("loop_a", "1", {"a.txt": "a\n"}, [{"id": "loop_b", "version": "1"}])
	_publish("loop_b", "1", {"b.txt": "b\n"}, [{"id": "loop_a", "version": "1"}])
	var client := _client("loop")
	var got := await client.ensure(&"loop_a", "1")
	_check("loop refused, not awaited", not got.ok)
	_check("neither mounted", not client.is_mounted(&"loop_a", "1") and not client.is_mounted(&"loop_b", "1"))
	client.queue_free()
	_end()


func _section_manifest_rules() -> void:
	_begin("manifest rules")
	var base := {"content_id": "x", "version": "1", "files": []}
	var ok := base.duplicate()
	ok["dependencies"] = [{"id": "owner/store", "version": "3"}]
	_check("owner/name accepted", DotCloudManifest.from_dict(ok).ok)
	for bad: Array in [
		[{"id": "", "version": "1"}], [{"id": "x", "version": "1"}], [{"id": "../up", "version": "1"}],
		[{"id": "s", "version": ""}], [{"id": "s", "version": "1/2"}], [{"id": "A B", "version": "1"}], ["text"],
	]:
		var d := base.duplicate()
		d["dependencies"] = bad
		_check("refused %s" % JSON.stringify(bad), not DotCloudManifest.from_dict(d).ok)
	var many := base.duplicate()
	many["dependencies"] = []
	for i in 9:
		many["dependencies"].append({"id": "s%d" % i, "version": "1"})
	_check("more than eight refused", not DotCloudManifest.from_dict(many).ok)
	_end()


func _section_nested() -> void:
	_begin("nested")
	_publish("deep_top", "1", {"t.txt": "t\n"}, [{"id": "map_a", "version": "1"}])
	var client := _client("nested")
	_ready_keys.clear()
	client.content_ready.connect(func(m: DotCloudManifest, _p: String) -> void: _ready_keys.append(m.key()))
	var got := await client.ensure(&"deep_top", "1")
	_check("chain mounts", got.ok, str(got.error) if not got.ok else "")
	_check("deepest first", _ready_keys.size() == 3 and _ready_keys[0] == "lib_store@1" and _ready_keys[2] == "deep_top@1", str(_ready_keys))
	client.queue_free()
	_end()


func _section_vram_tags() -> void:
	_begin("vram tags")
	var s3 := DotCloudPublisher.vram_platforms("_imported/albedo.webp-ab.s3tc.ctex")
	var etc := DotCloudPublisher.vram_platforms("_imported/albedo.webp-ab.etc2.ctex")
	_check("s3tc is desktop and web", s3.has("linux") and s3.has("windows") and s3.has("web") and not s3.has("android"))
	_check("etc2 is mobile and web", etc.has("android") and etc.has("ios") and etc.has("web") and not etc.has("linux"))
	_check("plain ctex is for all", DotCloudPublisher.vram_platforms("_imported/x.ctex").is_empty())
	_check("an ordinary file is for all", DotCloudPublisher.vram_platforms("pbr/a.bin").is_empty())
	_end()


func _publish(id: String, version: String, files: Dictionary, deps: Array) -> void:
	var src := WORK.path_join("src_" + id)
	for path: String in files:
		DotPaths.write_text(src.path_join(path), str(files[path]))
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = version
	pub.signing_key_pem = str(_keys["private"])
	pub.signing_key_id = "demo"
	for d: Dictionary in deps:
		pub.dependencies.append(d)
	var res := pub.publish(src, _published(id, version))
	_check("publish %s@%s" % [id, version], res.ok, str(res.error) if not res.ok else "")


func _published(id: String, version: String) -> String:
	return WORK.path_join("published").path_join(id).path_join(version)


func _read(id: String, version: String) -> DotCloudManifest:
	var bytes := DotPaths.read_bytes(_published(id, version).path_join("manifest.json"))
	if not bytes.ok:
		return null
	var parsed := DotCloudManifest.from_json_bytes(bytes.value)
	return parsed.value if parsed.ok else null


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
	# The default template looks for <base>/<id>/<version>/manifest.json: one search dir holds every pack.
	client.local_search_dirs = PackedStringArray([WORK.path_join("published")])
	client.allow_netchan_fallback = false
	add_child(client)
	return client


func _begin(name: String) -> void:
	_sections_started += 1
	print("")
	print("[%s]" % name)


func _end() -> void:
	_sections_finished += 1


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("  %s %s%s" % [label.rpad(34), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])


func _finish(code: int) -> void:
	await get_tree().process_frame
	get_tree().quit(code)
