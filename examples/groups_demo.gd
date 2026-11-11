extends Node

## Download groups from the source's `groups.json` (a course's meshes beside the pack's core files).
##
## Covered here: both shapes of the file, the groups written into the manifest entries, a file in no rule
## left ungrouped, a file in two groups, the merge with `DotCloudPublisher.group_rules`, the `.import`
## marker following its asset, a client given only a group fetching that group's files, a mounted pack
## topped up with one group and then every group (`ensure_groups_at`, `"*"`), and the publisher's refusals
## (a pattern matching nothing, an empty group, the name `*`, a non-pack path, a malformed file).
##
## [codeblock]
## godot --headless --path . res://examples/groups_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_groups_demo"

## Every check this suite runs, the closing count included. See docs/testing.md.
const CHECKS := 45
const SECTIONS := 5

const GROUPS_JSON := '{"course_a": ["worlds/course_a.*"], "course_b": ["worlds/course_b.*"], "worlds/shared/": "course_a"}'

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0
var _keys: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	print("dot-cloud groups")
	DotPaths.remove_tree(WORK)
	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		print("keygen failed: %s" % keys.error)
		_finish(1)
		return
	_keys = keys.value

	_section_published()
	await _section_mounted()
	await _section_job()
	_section_merge()
	_section_refusals()

	_check(
		"every section finished",
		_sections_started == SECTIONS and _sections_finished == SECTIONS,
		"%d started, %d finished, of %d" % [_sections_started, _sections_finished, SECTIONS]
	)
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("")
	print("%d checks, %d failed" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


func _section_published() -> void:
	_begin("published groups")
	var dir := WORK.path_join("src_ok")
	_write_source(dir, GROUPS_JSON)
	var res := _publisher().publish(dir, WORK.path_join("out_ok"))
	_check("publish", res.ok, str(res.error) if not res.ok else "")
	if not res.ok:
		_end()
		return
	var groups := _groups_of(WORK.path_join("out_ok"))
	_check("course_a json grouped", groups.get("worlds/course_a.json", []) == ["course_a"], str(groups.get("worlds/course_a.json")))
	_check("course_a bin grouped", groups.get("worlds/course_a.bin", []) == ["course_a"])
	_check("course_b glob grouped", groups.get("worlds/course_b.json", []) == ["course_b"])
	_check("course_b bin grouped", groups.get("worlds/course_b.bin", []) == ["course_b"])
	_check("prefix form grouped", groups.get("worlds/shared/sky.res", []) == ["course_a"])
	_check("courses ungrouped", not groups.has("courses/a.json"))
	_check("cfg ungrouped", not groups.has("cfg/game.yml"))
	_check("groups.json ships ungrouped", groups.has("groups.json") == false)
	_check("a name prefix does not leak", not groups.has("worlds/course_ab.json"))

	var manifest := _manifest(WORK.path_join("out_ok"))
	var a_only := PackedStringArray()
	if manifest != null:
		for f in manifest.files:
			if f.groups.is_empty() or f.in_groups(PackedStringArray(["course_a"])):
				a_only.append(f.path)
	_check("course_a client skips course_b", manifest != null and "worlds/course_a.json" in a_only and not "worlds/course_b.json" in a_only)
	_check("course_a client keeps core files", "courses/a.json" in a_only and "cfg/game.yml" in a_only)
	_end()


## A client mounts the core files, then one group on a "map change", then every group, as one host would.
func _section_mounted() -> void:
	_begin("mounted groups")
	var manifest := _manifest(WORK.path_join("out_ok"))
	_check("manifest read", manifest != null)
	if manifest == null:
		_end()
		return
	var prefix := manifest.mount_prefix()
	var client := _make_client(WORK.path_join("out_ok"))
	var first := await client.acquire_manifest(manifest)
	_check("core mounted", first.ok and FileAccess.file_exists(prefix.path_join("courses/a.json")), str(first.error) if not first.ok else "")
	_check("ungrouped ask mounts no group", not FileAccess.file_exists(prefix.path_join("worlds/course_a.json")))
	_check("a group not yet covered", not client.mounter.covers(manifest, PackedStringArray(["course_a"])))

	var topped := await client.ensure_groups_at(prefix.path_join("worlds"), PackedStringArray(["course_a"]))
	_check("top-up answers the prefix", topped.ok and str(topped.value) == prefix, str(topped.error) if not topped.ok else str(topped.value))
	_check("topped-up group readable", FileAccess.file_exists(prefix.path_join("worlds/course_a.json")) and FileAccess.file_exists(prefix.path_join("worlds/shared/sky.res")))
	_check("other group still absent", not FileAccess.file_exists(prefix.path_join("worlds/course_b.json")))
	_check("the group is now covered", client.mounter.covers(manifest, PackedStringArray(["course_a"])))

	var elsewhere := await client.ensure_groups_at("res://not_acquired/x", PackedStringArray(["course_b"]))
	_check("unacquired path is a no-op", elsewhere.ok and str(elsewhere.value) == "" and not FileAccess.file_exists(prefix.path_join("worlds/course_b.json")))

	var all := await client.acquire_manifest(manifest, PackedStringArray([DotCloudFile.ALL_GROUPS]))
	_check("every group mounted", all.ok and FileAccess.file_exists(prefix.path_join("worlds/course_b.bin")), str(all.error) if not all.ok else "")
	client.queue_free()
	_end()


## An outer job counts and downloads the groups it is given (API 23), and none otherwise.
func _section_job() -> void:
	_begin("job totals")
	var manifest := _manifest(WORK.path_join("out_ok"))
	if manifest == null:
		_check("manifest read", false)
		_end()
		return
	var core: Dictionary = await _job_total(manifest, PackedStringArray(), "job_core")
	var one: Dictionary = await _job_total(manifest, PackedStringArray(["course_a"]), "job_one")
	var r_all: Dictionary = await _job_total(manifest, PackedStringArray([DotCloudFile.ALL_GROUPS]), "job_all")
	var t_core: int = int(core["total"])
	var t_one: int = int(one["total"])
	var t_all: int = int(r_all["total"])
	_check("no groups, the total is the ungrouped files", t_core > 0, str(t_core))
	_check("one group adds its files", t_one > t_core, "%d vs %d" % [t_one, t_core])
	_check("every group adds the rest", t_all > t_one, "%d vs %d" % [t_all, t_one])
	_check("the download moved every counted byte", int(r_all["done"]) == t_all, "%s of %d" % [r_all["done"], t_all])
	_check("a grouped file is in the store after an all-groups job", bool(r_all["stored"]))
	_check("a plain job leaves a grouped file out of the store", not bool(core["stored"]))
	_check("the job drops its groups when it ends", bool(r_all["cleared"]))
	_end()


## Registers [param manifest] in a job of its own with [param groups], downloads, and reports totals.
func _job_total(manifest: DotCloudManifest, groups: PackedStringArray, cache: String) -> Dictionary:
	var client := _make_client(WORK.path_join("out_ok"), cache)
	await client.start()
	var snaps: Array = []
	client.job_progress_changed.connect(func(s: Dictionary) -> void: snaps.append(s))
	client.begin_job()
	await client.job_register_manifest(manifest, groups)
	var total := int(snaps[-1].get("total_bytes", 0)) if not snaps.is_empty() else 0
	await client.job_download()
	var done := int(snaps[-1].get("done_bytes", 0)) if not snaps.is_empty() else 0
	var stored := false
	for f in manifest.files:
		if f.path == "worlds/course_b.bin":
			stored = client.store.has(f.sha256)
	client.end_job()
	var cleared: bool = client._job_groups.is_empty()
	client.queue_free()
	return {"total": total, "done": done, "stored": stored, "cleared": cleared}


func _section_merge() -> void:
	_begin("merge with group_rules")
	var dir := WORK.path_join("src_merge")
	_write_source(dir, GROUPS_JSON)
	var pub := _publisher()
	pub.group_rules = {"worlds/course_a.": "hd", "courses/": "meta"}
	var res := pub.publish(dir, WORK.path_join("out_merge"))
	_check("publish", res.ok, str(res.error) if not res.ok else "")
	if not res.ok:
		_end()
		return
	var groups := _groups_of(WORK.path_join("out_merge"))
	var a: Array = Array(groups.get("worlds/course_a.json", []))
	a.sort()
	_check("both group sources apply", a == ["course_a", "hd"], str(a))
	_check("code rule alone applies", groups.get("courses/a.json", []) == ["meta"])
	_check("file rule alone applies", groups.get("worlds/course_b.json", []) == ["course_b"])
	var again := _publisher().publish(dir, WORK.path_join("out_merge2"))
	_check("no group_rules still groups", again.ok and _groups_of(WORK.path_join("out_merge2")).get("worlds/course_a.json", []) == ["course_a"])
	_end()


func _section_refusals() -> void:
	_begin("refusals")
	_check("pattern matching nothing", _refused('{"course_z": ["worlds/course_z."]}'))
	_check("prefix form matching nothing", _refused('{"nowhere/": "g"}'))
	_check("empty group list", _refused('{"course_a": []}'))
	_check("empty group name", _refused('{"worlds/": ""}'))
	_check("group named *", _refused('{"*": ["worlds/"]}'))
	_check("res:// pattern", _refused('{"g": ["res://worlds/"]}'))
	_check("absolute pattern", _refused('{"g": ["/worlds/"]}'))
	_check("wrong value type", _refused('{"g": 3}'))
	_check("not an object", _refused('["worlds/"]'))
	_end()


# Helpers

func _refused(groups: String) -> bool:
	var dir := WORK.path_join("src_bad")
	DotPaths.remove_tree(dir)
	_write_source(dir, groups)
	var res := _publisher().publish(dir, WORK.path_join("out_bad"))
	return not res.ok


func _make_client(published: String, cache: String = "cache") -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join(cache)
	config.require_signed_manifests = true
	config.trusted_keys = {"demo": str(_keys["public"])}
	config.side = "both"
	var client := DotCloudClient.new()
	client.name = "Cloud_groups"
	client.config = config
	client.config_file = ""
	client.register_service = false
	client.local_search_dirs = PackedStringArray([published])
	client.allow_netchan_fallback = false
	add_child(client)
	return client


func _publisher() -> DotCloudPublisher:
	var pub := DotCloudPublisher.new()
	pub.content_id = "groups_demo"
	pub.version = "1.0.0"
	pub.signing_key_pem = str(_keys["private"])
	pub.signing_key_id = "demo"
	return pub


func _manifest(out: String) -> DotCloudManifest:
	var bytes := DotPaths.read_bytes(out.path_join("manifest.json"))
	if not bytes.ok:
		return null
	var parsed := DotCloudManifest.from_json_bytes(bytes.value)
	return parsed.value if parsed.ok else null


func _groups_of(out: String) -> Dictionary:
	var by_path := {}
	var manifest := _manifest(out)
	if manifest == null:
		return by_path
	for f in manifest.files:
		if not f.groups.is_empty():
			by_path[f.path] = Array(f.groups)
	return by_path


func _write_source(dir: String, groups: String) -> void:
	var files := {
		"courses/a.json": "{}\n",
		"cfg/game.yml": "game: demo\n",
		"worlds/course_a.json": "{\"a\": 1}\n",
		"worlds/course_a.bin": "AAAA",
		"worlds/course_b.json": "{\"b\": 1}\n",
		"worlds/course_b.bin": "BBBB",
		"worlds/course_ab.json": "{}\n",
		"worlds/shared/sky.res": "sky",
		"groups.json": groups + "\n",
	}
	for path: String in files:
		DotPaths.write_text(dir.path_join(path), str(files[path]))


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
