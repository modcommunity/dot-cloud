extends Node

## Content that depends on other content (API 15): the signed list and its tamper check, store-first acquire,
## a shared store skipped, a missing store or a loop refused before mount, and the CLI-less parser.
## Run: godot --headless --path . res://examples/dependency_demo.tscn

const WORK := "user://dot_cloud_dependency_demo"
const CHECKS := 98
const SECTIONS := 11

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
	await _section_concurrent()
	await _section_collection()
	await _section_parallel()
	await _section_two_phase()
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
	var many := {"content_id": "x", "version": "1", "files": [{"path": "a.txt", "sha256": "0".repeat(64), "size": 1}], "dependencies": []}
	for i in 9:
		many["dependencies"].append({"id": "s%d" % i, "version": "1"})
	_check("more than eight refused for a pack with files", not DotCloudManifest.from_dict(many).ok)
	var coll := base.duplicate()
	coll["dependencies"] = []
	for i in 40:
		coll["dependencies"].append({"id": "s%d" % i, "version": "1"})
	_check("a collection (no files) may list forty", DotCloudManifest.from_dict(coll).ok)
	for i in 100:
		coll["dependencies"].append({"id": "t%d" % i, "version": "1"})
	_check("a collection is still capped", not DotCloudManifest.from_dict(coll).ok)
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


func _section_collection() -> void:
	_begin("collection")
	var pub := DotCloudPublisher.new()
	pub.content_id = "all_maps"
	pub.version = "1"
	pub.signing_key_pem = str(_keys["private"])
	pub.signing_key_id = "demo"
	for id in ["map_a", "map_b"]:
		pub.dependencies.append({"id": id, "version": "1"})
	var src := WORK.path_join("src_all_maps")
	DirAccess.make_dir_recursive_absolute(src)
	var res := pub.publish(src, _published("all_maps", "1"))
	_check("an empty source publishes as a collection", res.ok, str(res.error) if not res.ok else "")
	var client := _client("collection")
	var last: Array = [{}]
	client.job_progress_changed.connect(func(s: Dictionary) -> void: last[0] = s)
	var got := await client.ensure(&"all_maps", "1")
	_check("the collection mounts every map", got.ok and client.dependency_prefix(&"map_a", "1") != "" and client.dependency_prefix(&"map_b", "1") != "", str(got.error) if not got.ok else "")
	_check("one job covered both maps and the store", int(last[0].get("total_packs", 0)) == 3 and int(last[0].get("done_packs", 0)) == 3, str(last[0]))
	client.queue_free()
	_end()


func _section_parallel() -> void:
	_begin("parallel")
	var deps: Array = []
	var total := 0
	for i in 12:
		var id := "par_%d" % i
		var body := ("pack %d\n" % i).repeat(40)
		total += body.length()
		_publish(id, "1", {"data.txt": body}, [])
		deps.append({"id": id, "version": "1"})
	_collection("par_all", deps)
	var client := _client("parallel", true)
	client.config.parallel_packs = 3
	var snaps: Array = []
	client.job_progress_changed.connect(func(s: Dictionary) -> void: snaps.append(s))
	var got := await client.ensure(&"par_all", "1")
	_check("twelve packs mount", got.ok and client.is_mounted(&"par_11", "1"), str(got.error) if not got.ok else "")
	_check("the cap of 3 held", client.pool.peak <= 3, "peak %d" % client.pool.peak)
	_check("packs did overlap", client.pool.peak >= 2, "peak %d" % client.pool.peak)
	_check("manifests resolved within the cap", client.resolve_peak >= 2 and client.resolve_peak <= 3, "resolve peak %d" % client.resolve_peak)
	var registered := -1
	for i in snaps.size():
		if int(snaps[i]["total_packs"]) == 12 and registered < 0:
			registered = i
	_check("all 12 packs known before the first byte", registered >= 0 and int(snaps[registered]["done_bytes"]) == 0, str(registered))
	_check("downloaders made: no more than the cap", client.pool.size() <= 3, str(client.pool.size()))
	var mono := true
	var prev := -1
	for s: Dictionary in snaps:
		var d := int(s["done_bytes"])
		mono = mono and d >= prev and d <= int(s["total_bytes"])
		prev = d
	_check("progress never moved back or past total", mono and snaps.size() > 1, "%d snapshots" % snaps.size())
	var last: Dictionary = snaps[-1] if not snaps.is_empty() else {}
	_check("the job ends at 12 of 12 packs", int(last.get("done_packs", 0)) == 12 and int(last.get("total_packs", 0)) == 12, str(last))
	_check("bytes sum to the payloads", int(last.get("total_bytes", 0)) >= total and int(last.get("done_bytes", 0)) == int(last.get("total_bytes", -1)), str(last))
	client.queue_free()

	var one := _client("parallel_one", true)
	one.config.parallel_packs = 1
	var seq := await one.ensure(&"par_all", "1")
	_check("a cap of 1 is still correct", seq.ok and one.pool.peak == 1 and one.pool.size() == 1, "peak %d" % one.pool.peak)
	_check("a cap of 1 resolves one manifest at a time", one.resolve_peak == 1, "resolve peak %d" % one.resolve_peak)
	one.queue_free()

	var bad_deps := deps.duplicate()
	bad_deps.insert(4, {"id": "par_missing", "version": "1"})
	bad_deps.insert(9, {"id": "par_missing2", "version": "1"})
	_collection("par_bad", bad_deps)
	var broke := _client("parallel_bad", true)
	broke.config.parallel_packs = 4
	var t0 := Time.get_ticks_msec()
	var failed := await broke.ensure(&"par_bad", "1")
	_check("a missing dependency fails the collection", not failed.ok)
	_check("and does not hang", Time.get_ticks_msec() - t0 < 20000, "%d ms" % (Time.get_ticks_msec() - t0))
	_check("the error names the dependency", failed.error != null and failed.error.message.contains("par_missing@1"), str(failed.error))
	_check("the cap held while failing", broke.pool == null or broke.pool.peak <= 4)
	_check("resolve cap held with failing manifests", broke.resolve_peak <= 4 and broke.resolve_peak >= 2, "resolve peak %d" % broke.resolve_peak)
	_check("first failure in list order is named", failed.error != null and failed.error.message.contains("par_missing@1") and not failed.error.message.contains("par_missing2"), str(failed.error))
	_check("a later acquire still works", (await broke.ensure(&"par_3", "1")).ok)
	broke.queue_free()
	_end()


func _section_two_phase() -> void:
	_begin("two phase")
	var deps: Array = [{"id": "map_a", "version": "1"}, {"id": "map_b", "version": "1"}]
	var client := _client("two_phase", true)
	var snaps: Array = []
	client.job_progress_changed.connect(func(s: Dictionary) -> void: snaps.append(s))
	client.begin_job()
	var reg := await client.job_register(deps)
	_check("packs register before any download", reg.ok, str(reg.error) if not reg.ok else "")
	var total := int(snaps[-1].get("total_bytes", 0)) if not snaps.is_empty() else 0
	var from := snaps.size()
	_check("the total is known up front", total > 0, str(total))
	var dl := await client.job_download()
	_check("the download pass succeeds", dl.ok and dl.value.is_empty(), str(dl.error) if not dl.ok else str(dl.value))
	_check("nothing is mounted by the download pass", not client.is_mounted(&"map_a", "1") and not client.is_mounted(&"map_b", "1"))
	var last: Dictionary = snaps[-1] if not snaps.is_empty() else {}
	_check("the total did not grow while downloading", int(last.get("total_bytes", -1)) == total and int(last.get("done_bytes", -1)) == total, str(last))
	var mono := true
	var prev := -1
	for s: Dictionary in snaps.slice(from):
		var d := int(s["done_bytes"])
		mono = mono and d >= prev and int(s["total_bytes"]) == total
		prev = d
	_check("the total never moved and progress never went back", mono, "%d snapshots" % snaps.size())
	client.job_begin_unpack()
	_check("the unpack phase announces itself", str(snaps[-1].get("phase", "")) == "unpack", str(snaps[-1]))
	for id in ["map_a", "map_b"]:
		var got := await client.ensure(StringName(id), "1")
		_check("%s mounts from the store" % id, got.ok, str(got.error) if not got.ok else "")
	last = snaps[-1]
	_check("unpack counted every pack", int(last.get("unpack_done", 0)) == int(last.get("unpack_total", -1)) and int(last.get("unpack_total", 0)) >= 2, str(last))
	_check("the bytes did not move while unpacking", int(last.get("done_bytes", -1)) == total, str(last))
	client.end_job()
	client.queue_free()
	_end()


func _collection(id: String, deps: Array) -> void:
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = "1"
	pub.signing_key_pem = str(_keys["private"])
	pub.signing_key_id = "demo"
	for d: Dictionary in deps:
		pub.dependencies.append(d)
	var src := WORK.path_join("src_" + id)
	DirAccess.make_dir_recursive_absolute(src)
	var res := pub.publish(src, _published(id, "1"))
	_check("publish collection %s" % id, res.ok, str(res.error) if not res.ok else "")


func _section_concurrent() -> void:
	_begin("concurrent")
	var res: Array = []
	var done := [0]
	var fire := func(c: DotCloudClient, id: StringName) -> void:
		res.append(await c.ensure(id, "1"))
		done[0] += 1
	var same := _client("conc_same")
	fire.call(same, &"map_a")
	fire.call(same, &"map_a")
	while done[0] < 2:
		await get_tree().process_frame
	_check("same pack twice: first ok", res[0].ok, str(res[0].error) if not res[0].ok else "")
	_check("same pack twice: second joins, not circular", res[1].ok, str(res[1].error) if not res[1].ok else "")
	same.queue_free()

	var two := _client("conc_two")
	res.clear()
	done[0] = 0
	fire.call(two, &"map_a")
	fire.call(two, &"map_b")
	while done[0] < 2:
		await get_tree().process_frame
	_check("shared dependency: a ok", res[0].ok, str(res[0].error) if not res[0].ok else "")
	_check("shared dependency: b ok", res[1].ok, str(res[1].error) if not res[1].ok else "")
	_check("both mounted", two.is_mounted(&"map_a", "1") and two.is_mounted(&"map_b", "1"))
	two.queue_free()

	var cyc := _client("conc_cycle")
	res.clear()
	done[0] = 0
	fire.call(cyc, &"loop_a")
	fire.call(cyc, &"map_b")
	while done[0] < 2:
		await get_tree().process_frame
	_check("cycle still refused beside another acquisition", not res[0].ok)
	_check("neighbour unaffected by the cycle", res[1].ok, str(res[1].error) if not res[1].ok else "")
	cyc.queue_free()
	_end()


func _section_vram_tags() -> void:
	_begin("vram tags")
	var s3 := DotCloudPublisher.vram_platforms("_imported/albedo.webp-ab.s3tc.ctex")
	var etc := DotCloudPublisher.vram_platforms("_imported/albedo.webp-ab.etc2.ctex")
	_check("s3tc is desktop and web", s3.has("linux") and s3.has("windows") and s3.has("web") and not s3.has("android"))
	_check("etc2 is mobile and web", etc.has("android") and etc.has("ios") and etc.has("web") and not etc.has("linux"))
	_check("baked s3tc.res is desktop", "linux" in DotCloudPublisher.vram_platforms("pbr/a/albedo.s3tc.res") and not "android" in DotCloudPublisher.vram_platforms("pbr/a/albedo.s3tc.res"))
	_check("baked etc2.res is mobile", "android" in DotCloudPublisher.vram_platforms("pbr/a/albedo.etc2.res") and not "linux" in DotCloudPublisher.vram_platforms("pbr/a/albedo.etc2.res"))
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


var _server: Node = null


## [param http] serves the published packs over the test server, so manifest fetches really overlap (a local read never yields).
func _client(tag: String, http := false) -> DotCloudClient:
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
	if http:
		if _server == null:
			_server = preload("res://examples/http_test_server.gd").new()
			_server.root = ProjectSettings.globalize_path(WORK.path_join("published"))
			add_child(_server)
			_server.start(0)
		client.local_search_dirs = PackedStringArray()
		client.http_base_urls = PackedStringArray([_server.base_url()])
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
