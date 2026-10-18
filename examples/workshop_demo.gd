extends Node

## The Workshop's half of dot-cloud: a pack that says what it provides, and a mount that
## puts it in the index for the right session.
##
## Publishes fixture packs (a map, a weapon and a prop; a pack carrying a script; an addon
## overlay; packs that reuse UIDs), mounts them through [method DotCloudClient.ensure_for_session]
## and reads the answer back from [DotContentIndex]. Each refusal is armed: the check beside it
## states what the unguarded path does, so a test that cannot fail shows up.
##
## [codeblock]
## godot --headless --path . res://examples/workshop_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_workshop_demo"
const CHECKS := 56

var _failures := 0
var _checks := 0
var _key_pem := ""
var _pub_pem := ""
var _cloud: DotCloudClient
var _index: DotContentIndex


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("[b]the Workshop: provides, the code scan, session-tagged mounts[/b]")
	DotPaths.remove_tree(WORK)

	var keys := DotCloudSignature.generate_keypair(2048)
	_check(keys.ok, "a signing key pair is generated")
	if not keys.ok:
		_done()
		return
	_key_pem = str((keys.value as Dictionary)["private"])
	_pub_pem = str((keys.value as Dictionary)["public"])

	# A fresh index of this test's own, which is what the registry name is for.
	_index = DotContentIndex.new()
	DotRegistry.register(DotContentIndex.SERVICE, _index)
	_index.set_session(&"solo")

	_cloud = DotCloudClient.new()
	_cloud.name = "Cloud"
	_cloud.config = DotCloudConfig.new()
	_cloud.config.cache_dir = WORK.path_join("cache")
	_cloud.config.trusted_keys = {"test": {"key": _pub_pem, "content_ids": ["ws_*"]}}
	_cloud.config_file = ""
	add_child(_cloud)

	_check_publish_validation()
	await _check_mount_and_sessions()
	await _check_undeclared_code()
	await _check_root_overlay()
	await _check_uid_policy()
	_check_scan_alone()

	_done()


# --- fixtures ---------------------------------------------------------------

func _write(dir: String, rel: String, text: String) -> void:
	DotPaths.write_text(dir.path_join(rel), text)


func _publish(src: String, id: String, version: String = "1.0.0", pub_setup: Callable = Callable()) -> DotResult:
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = version
	pub.signing_key_pem = _key_pem
	if pub_setup.is_valid():
		pub_setup.call(pub)
	return pub.publish(src, WORK.path_join("out_%s_%s" % [id, version]))


func _manifest_url(id: String, version: String = "1.0.0") -> String:
	return WORK.path_join("out_%s_%s" % [id, version]).path_join("manifest.json")


const DATA_PROVIDES := {
	"schema": 1, "title": "Fixture pack", "kinds": ["map", "weapon", "prop"], "games": "*",
	"categories": [{"id": "fx", "name": "Fixtures"}],
	"entries": [
		{"kind": "map", "id": "arena_one", "name": "Arena One", "scene": "maps/one.tscn",
			"map_kind": "sandbox", "thumbnail": "maps/one_thumb.bin", "category": "fx"},
		{"kind": "weapon", "id": "blaster", "name": "Blaster", "def": "weapons/blaster.tres", "slot": 2},
		{"kind": "prop", "id": "crate", "name": "Crate", "scene": "props/crate.tscn", "tags": ["wood"]},
	],
}


func _data_source(dir: String, provides: Dictionary = DATA_PROVIDES) -> void:
	_write(dir, "maps/one.tscn", "[gd_scene format=3]\n\n[node name=\"One\" type=\"Node3D\"]\n")
	_write(dir, "maps/one_thumb.bin", "thumb")
	_write(dir, "weapons/blaster.tres", "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n")
	_write(dir, "props/crate.tscn", "[gd_scene format=3]\n\n[node name=\"Crate\" type=\"Node3D\"]\n")
	_write(dir, "provides.json", JSON.stringify(provides))


# --- sections ---------------------------------------------------------------

func _check_publish_validation() -> void:
	_line("")
	_line("[b]publish-time validation of provides.json[/b]")

	var src := WORK.path_join("src_data")
	_data_source(src)
	var ok := _publish(src, "ws_data")
	_check(ok.ok, "a fixture pack with a map, a weapon and a prop publishes", str(ok.error) if not ok.ok else "")
	if not ok.ok:
		return
	var manifest: DotCloudManifest = (ok.value as Dictionary)["manifest"]
	_check(manifest.provides.get("entries", []).size() == 3, "the manifest carries all three entries")
	_check(manifest.provides.get("runs_code") == false, "runs_code is computed, and false for data")

	# The manifest that comes back off the disk is the signed one: provides survives the
	# round trip through the payload, which is what the client will read.
	var read := DotCloudManifest.from_json_bytes(FileAccess.get_file_as_bytes(_manifest_url("ws_data")))
	_check(read.ok and (read.value as DotCloudManifest).provides.get("title") == "Fixture pack", "and survives the signed round trip")

	var missing := DATA_PROVIDES.duplicate(true)
	missing["entries"][0]["scene"] = "maps/nowhere.tscn"
	var s1 := WORK.path_join("src_missing")
	_data_source(s1, missing)
	var r1 := _publish(s1, "ws_missing")
	_check(not r1.ok and r1.error.code == DotError.CODE_INVALID, "an entry naming a file the pack lacks is refused", str(r1.error) if not r1.ok else "published")

	var climb := DATA_PROVIDES.duplicate(true)
	climb["entries"][0]["scene"] = "../outside.tscn"
	var s2 := WORK.path_join("src_climb")
	_data_source(s2, climb)
	_check(not _publish(s2, "ws_climb").ok, "a path with .. is refused")

	var absolute := DATA_PROVIDES.duplicate(true)
	absolute["entries"][0]["scene"] = "res://maps/one.tscn"
	var s3 := WORK.path_join("src_abs")
	_data_source(s3, absolute)
	_check(not _publish(s3, "ws_abs").ok, "and so is a res:// path")

	var wrong_kind := DATA_PROVIDES.duplicate(true)
	wrong_kind["kinds"] = ["map"]
	var s4 := WORK.path_join("src_kinds")
	_data_source(s4, wrong_kind)
	_check(not _publish(s4, "ws_kinds").ok, "an entry whose kind is not in 'kinds' is refused")

	var dupe := DATA_PROVIDES.duplicate(true)
	dupe["entries"].append({"kind": "prop", "id": "crate", "name": "Again", "scene": "props/crate.tscn"})
	var s5 := WORK.path_join("src_dupe")
	_data_source(s5, dupe)
	_check(not _publish(s5, "ws_dupe").ok, "two entries with one kind and id are refused")

	# Additive-only: a newer schema, a kind this build does not know and a field it does
	# not know are all fine for the client's reader.
	var norm := DotCloudProvides.normalize({
		"schema": 7, "future_key": 1,
		"entries": [{"kind": "hologram", "id": "h", "name": "H", "future": true}, "junk", {"kind": "map"}],
	})
	_check(int(norm["schema"]) == 7 and norm["entries"].size() == 1, "the client's reader keeps a newer schema and an unknown kind, and drops junk")

	var plain := WORK.path_join("src_plain")
	_write(plain, "data.txt", "no provides here")
	var rp := _publish(plain, "ws_plain")
	_check(rp.ok and (rp.value as Dictionary)["manifest"].provides.is_empty(), "a pack with no provides.json publishes as before, with none")


func _check_mount_and_sessions() -> void:
	_line("")
	_line("[b]a subscription mounts solo; online never sees it[/b]")

	var got := await _cloud.ensure_for_session(
		&"ws_data", "1.0.0", &"solo", &"subscription",
		{"uid_policy": "add_only", "allow_root": false, "manifest_url": _manifest_url("ws_data")}
	)
	_check(got.ok, "the fixture pack mounts as a solo subscription", str(got.error) if not got.ok else "")
	if not got.ok:
		return

	_check(_index.entries(&"map").size() == 1, "the index lists the map")
	_check(_index.entries(&"weapon").size() == 1, "the weapon")
	_check(_index.entries(&"prop").size() == 1, "and the prop")
	var m := _index.entry("ws_data@1.0.0:map/arena_one")
	_check(m != null and m.name == "Arena One" and m.source == &"subscription", "typed fields, source subscription")
	_check(m != null and ResourceLoader.exists(m.path("scene")), "the map's scene path resolves onto the mount", m.path("scene") if m != null else "")
	_check(m != null and FileAccess.file_exists(m.path("thumbnail")), "and so does its thumbnail")
	_check(m != null and m.pack_title == "Fixture pack" and m.category == "fx", "pack title and category carried")
	var w := _index.entry("ws_data@1.0.0:weapon/blaster")
	_check(w != null and w.raw.get("slot") == 2 and ResourceLoader.exists(w.path("def")), "the weapon keeps its slot and its def resolves")

	# Online: the same process, the same mount, nothing visible.
	_index.set_session(&"online")
	_check(_index.entries(&"map").size() == 0 and _index.entries(&"weapon").size() == 0 and _index.entries(&"prop").size() == 0, "an online consumer sees none of it")
	_check(_index.entries(&"map", &"solo").size() == 1, "armed: the entries are still there for the solo session")

	# A subscription is never mounted for an online session, even by a caller that asks.
	var denied := await _cloud.ensure_for_session(&"ws_data", "1.0.0", &"online", &"subscription")
	_check(not denied.ok and denied.error.code == DotError.CODE_FORBIDDEN, "a subscription mount for an online session is refused")
	_check(_index.entries(&"map").size() == 0, "and left nothing visible online")

	# A server requiring the same id and version reuses the mount and gains the tag.
	var reused := await _cloud.ensure_for_session(&"ws_data", "1.0.0", &"online", &"server", {"manifest_url": _manifest_url("ws_data")})
	_check(reused.ok and _index.entries(&"map").size() == 1, "the same id@version required by a server is tagged online without a second mount")
	_check(_index.packs().size() == 1 and _index.packs(&"solo").size() == 1, "one pack record, both sessions")

	# Online content that was never solo does not leak into solo.
	var src := WORK.path_join("src_server")
	_data_source(src)
	var pub := _publish(src, "ws_server", "1.0.0")
	var srv := await _cloud.ensure_for_session(&"ws_server", "1.0.0", &"online", &"server", {"manifest_url": _manifest_url("ws_server")})
	_check(pub.ok and srv.ok, "a server's pack mounts online")
	_check(_index.entries(&"map").size() == 2, "online lists the server's map and the reused one")
	_index.set_session(&"solo")
	_check(_index.entries(&"map").size() == 1 and _index.entry("ws_server@1.0.0:map/arena_one").has_session(&"online"), "solo does not list the server's pack")

	# A plain ensure tags with session_tag.
	var plain_src := WORK.path_join("src_plain_tag")
	_data_source(plain_src)
	_publish(plain_src, "ws_plain_tag")
	_cloud.session_tag = &"solo"
	var plain := await _cloud.ensure(&"ws_plain_tag", "1.0.0", PackedStringArray(), _manifest_url("ws_plain_tag"))
	_cloud.session_tag = &"online"
	_check(plain.ok and _index.entries(&"map").size() == 2, "a plain ensure is tagged with session_tag")
	_check(_index.entry("ws_plain_tag@1.0.0:map/arena_one").source == &"game", "and takes source game when solo")

	var lines := _cloud.describe_lines()
	var joined := "\n".join(lines)
	_check(joined.contains("ws_data@1.0.0") and joined.contains("map x1") and joined.contains("weapon x1"), "describe_lines lists what each pack provided", joined.substr(0, 600))


func _code_provides() -> Dictionary:
	return {"schema": 1, "title": "Code", "kinds": ["map"], "entries": [
		{"kind": "map", "id": "m", "name": "M", "scene": "maps/m.tscn"}]}


func _code_source(dir: String) -> void:
	_write(dir, "maps/m.tscn", "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://maps/m.gd\" id=\"1\"]\n\n[node name=\"M\" type=\"Node3D\"]\nscript = ExtResource(\"1\")\n")
	_write(dir, "maps/m.gd", "extends Node3D\n")
	_write(dir, "provides.json", JSON.stringify(_code_provides()))


func _check_undeclared_code() -> void:
	_line("")
	_line("[b]code the manifest did not declare[/b]")

	var src := WORK.path_join("src_code")
	_code_source(src)
	var honest := _publish(src, "ws_code")
	var honest_manifest: DotCloudManifest = (honest.value as Dictionary)["manifest"] if honest.ok else null
	_check(honest_manifest != null and honest_manifest.provides.get("runs_code") == true, "a pack with a script publishes with runs_code true, whatever the author wrote")

	# The same files under a manifest that says they are data: re-signed by the test key, so
	# the signature is valid and only the scan can notice.
	var forged_dir := WORK.path_join("out_ws_forged_1.0.0")
	DotPaths.ensure_dir(forged_dir)
	var again := _publish(src, "ws_forged")
	var parsed := DotCloudManifest.from_json_bytes(FileAccess.get_file_as_bytes(_manifest_url("ws_forged")))
	var m: DotCloudManifest = parsed.value
	var prov := m.provides.duplicate(true)
	prov["runs_code"] = false
	m.provides = prov
	var payload := m.payload_bytes()
	var sig := DotCloudSignature.sign(payload, _key_pem)
	var wrapped := DotCloudEnvelope.wrap(payload, str(sig.value), "test")
	DotPaths.write_bytes(_manifest_url("ws_forged"), wrapped.to_utf8_buffer())

	var refused := await _cloud.ensure_for_session(&"ws_forged", "1.0.0", &"solo", &"subscription", {"manifest_url": _manifest_url("ws_forged")})
	_check(again.ok and not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN, "the client refuses it as forbidden", str(refused.error) if not refused.ok else "mounted")
	_check(not ResourceLoader.exists("res://dot_cloud/ws_forged/1.0.0/maps/m.tscn"), "and nothing of it was mounted")
	_check(_index.entry("ws_forged@1.0.0:map/m") == null, "or indexed")

	# Armed: the honest version of the same files mounts, so the refusal was the scan and not
	# some other problem with the fixture.
	var ok := await _cloud.ensure_for_session(&"ws_code", "1.0.0", &"solo", &"subscription", {"manifest_url": _manifest_url("ws_code")})
	_check(ok.ok and _index.entry("ws_code@1.0.0:map/m") != null, "armed: the declared version mounts and indexes", str(ok.error) if not ok.ok else "")
	var rc := _index.describe_lines()
	_check("\n".join(rc).contains("runs code"), "and describe_lines says it runs code")


func _check_root_overlay() -> void:
	_line("")
	_line("[b]an addon overlay is not taken from a subscription[/b]")

	var src := WORK.path_join("src_overlay")
	_write(src, "addons/ws_thing/plugin.cfg", "[plugin]\nname=\"x\"\nscript=\"p.gd\"\n")
	_write(src, "addons/ws_thing/p.gd", "extends Node\n")
	_write(src, "provides.json", JSON.stringify({"schema": 1, "title": "Overlay", "kinds": ["addon"],
		"entries": [{"kind": "addon", "id": "thing", "name": "Thing", "dir": "addons/ws_thing"}]}))
	var pub := _publish(src, "ws_overlay")
	_check(pub.ok, "an addon pack publishes", str(pub.error) if not pub.ok else "")

	var refused := await _cloud.ensure_for_session(&"ws_overlay", "1.0.0", &"solo", &"subscription", {"allow_root": false, "manifest_url": _manifest_url("ws_overlay")})
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN, "allow_root false refuses it as forbidden")
	_check(not _cloud.is_mounted(&"ws_overlay", "1.0.0"), "and it is not mounted")

	var missing_dir := WORK.path_join("src_overlay_bad")
	_write(missing_dir, "x.txt", "x")
	_write(missing_dir, "provides.json", JSON.stringify({"schema": 1, "kinds": ["addon"],
		"entries": [{"kind": "addon", "id": "thing", "name": "Thing", "dir": "addons/nothing"}]}))
	_check(not _publish(missing_dir, "ws_overlay_bad").ok, "an addon entry naming a directory the pack lacks is refused at publish")


func _uid_source(dir: String, uids: Dictionary) -> void:
	_write(dir, "project.godot", "config_version=5\n")
	for name: String in uids:
		_write(dir, "tex/%s.png" % name, "not a png %s" % name)
		_write(dir, "tex/%s.png.import" % name, "[remap]\n\npath=\"res://.godot/imported/%s.ctex\"\nuid=\"%s\"\n" % [name, uids[name]])
		_write(dir, ".godot/imported/%s.ctex" % name, "imported %s" % name)


func _check_uid_policy() -> void:
	_line("")
	_line("[b]a subscription never re-points a UID the process knows[/b]")

	var shared_id := ResourceUID.create_id()
	var host_id := ResourceUID.create_id()
	var fresh_id := ResourceUID.create_id()
	var host_path := "res://examples/workshop_demo.gd"
	ResourceUID.add_id(host_id, host_path)
	var shared_text := ResourceUID.id_to_text(shared_id)

	var ship := func(pub: DotCloudPublisher) -> void: pub.ship_import_sources = true

	# Content already mounted by somebody else (the game's own pack, a server's map) owns the id.
	var s1 := WORK.path_join("src_uid1")
	_uid_source(s1, {"shared": shared_text})
	var p1 := _publish(s1, "ws_uid_game", "1.0.0", ship)
	var m1 := await _cloud.ensure(&"ws_uid_game", "1.0.0", PackedStringArray(), _manifest_url("ws_uid_game"))
	_check(p1.ok and m1.ok, "a game pack mounts and registers its uid", str(m1.error) if not m1.ok else "")
	var owned := ResourceUID.get_id_path(shared_id)
	_check(owned.begins_with("res://dot_cloud/ws_uid_game/"), "which points into the game pack", owned)

	# The subscription reuses both that id and the host's own.
	var s2 := WORK.path_join("src_uid2")
	_uid_source(s2, {"shared": shared_text, "host": ResourceUID.id_to_text(host_id), "fresh": ResourceUID.id_to_text(fresh_id)})
	var p2 := _publish(s2, "ws_uid_sub", "1.0.0", ship)
	var m2 := await _cloud.ensure_for_session(&"ws_uid_sub", "1.0.0", &"solo", &"subscription", {"uid_policy": "add_only", "manifest_url": _manifest_url("ws_uid_sub")})
	_check(p2.ok and m2.ok, "the subscription mounts", str(m2.error) if not m2.ok else "")
	_check(ResourceUID.get_id_path(shared_id) == owned, "the game's uid was not re-pointed")
	_check(ResourceUID.get_id_path(host_id) == host_path, "nor was the host's own")
	_check(ResourceUID.has_id(fresh_id) and ResourceUID.get_id_path(fresh_id).begins_with("res://dot_cloud/ws_uid_sub/"), "an id nobody knew was added")
	var mounts: Array = _cloud.mounter.describe()["mounted"]
	var skipped := -1
	for e: Dictionary in mounts:
		if e["content"] == "ws_uid_sub@1.0.0":
			skipped = int(e["uids_skipped"])
	_check(skipped == 2, "the mount counts two skipped uids", "uids_skipped=%d" % skipped)

	# Armed: the same reuse through a plain mount moves the game's id, which is the damage.
	var s3 := WORK.path_join("src_uid3")
	_uid_source(s3, {"shared": shared_text})
	_publish(s3, "ws_uid_plain", "1.0.0", ship)
	var m3 := await _cloud.ensure(&"ws_uid_plain", "1.0.0", PackedStringArray(), _manifest_url("ws_uid_plain"))
	_check(m3.ok and ResourceUID.get_id_path(shared_id).begins_with("res://dot_cloud/ws_uid_plain/"), "armed: a plain mount does move an id that points into other content")


func _check_scan_alone() -> void:
	_line("")
	_line("[b]the script scan on its own[/b]")
	var files := {
		"a.tscn": "[gd_scene format=3]\n[sub_resource type=\"GDScript\" id=\"1\"]\n",
		"b.tscn": "[gd_scene format=3]\n[ext_resource type=\"Script\" path=\"res://addons/dot_core/x.gd\" id=\"1\"]\n",
		"c.tres": "[gd_resource type=\"Resource\" format=3]\n[ext_resource type=\"Script\" path=\"res://dot_cloud/p/1/s.gd\" id=\"1\"]\n",
		"d.res": "RSRC....GDScript....",
		"e.res": "RSRC....Mesh....",
		"f.txt": "extends Node",
		"g.dll": "MZ",
	}
	var reader := func(p: String) -> PackedByteArray: return str(files.get(p, "")).to_utf8_buffer()
	var verdicts := {}
	for p: String in files:
		var r := DotCloudScriptScan.scan(PackedStringArray([p]), reader)
		verdicts[p] = bool((r.value as Dictionary)["runs_code"])
	_check(verdicts["a.tscn"] and verdicts["c.tres"] and verdicts["d.res"] and verdicts["g.dll"], "a sub-resource script, an in-pack script, a binary class name and a native library all count")
	_check(not verdicts["b.tscn"], "a script that is the host build's copy under res://addons/ does not")
	_check(not verdicts["e.res"] and not verdicts["f.txt"], "and neither do a plain binary resource or a text file")
	var kinds := DotCloudScriptScan.scan(PackedStringArray(), reader, {"entries": [{"kind": "tool", "id": "t"}]})
	_check(bool((kinds.value as Dictionary)["runs_code"]), "an entry of kind tool always runs code")


# --- harness ----------------------------------------------------------------

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
