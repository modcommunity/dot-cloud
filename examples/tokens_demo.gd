extends Node

## A pack whose scripts ship as binary tokens (DotCloudPublisher.script_tokens_dir) mounts,
## loads and runs, and the default publish still ships text.
## Run: godot --headless --path . res://examples/tokens_demo.tscn

const WORK := "user://dot_cloud_tokens"
const CHECKS := 18

var _failures := 0
var _checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_line("[b]a pack with tokenized scripts[/b]")
	DotPaths.remove_tree(WORK)
	var work := ProjectSettings.globalize_path(WORK)

	# A small project of its own: the tokenizer needs a real project to export.
	var proj := work.path_join("project")
	DotPaths.write_text(proj.path_join("project.godot"), "config_version=5\n[application]\nconfig/name=\"tok\"\n")
	DotPaths.write_text(proj.path_join("game/thing.gd"), "extends Node\n\nfunc who() -> String:\n\treturn \"TOKENIZED\"\n")
	DotPaths.write_text(proj.path_join("scenes/world.tscn"), """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://game/thing.gd" id="1"]

[node name="World" type="Node"]
script = ExtResource("1")
""")

	var tokens := work.path_join("tokens")
	var code := OS.execute("godot", ["--headless", "--path", proj, "--import"], [], true)
	var ran: Array = []
	var tool_path := ProjectSettings.globalize_path("res://addons/dot_cloud/publish/tokenize_scripts.sh")
	code = OS.execute("bash", [tool_path, proj, tokens], ran, true)
	_check(code == 0, "tokenize_scripts.sh succeeds", str(ran))
	_check(FileAccess.file_exists(tokens.path_join("game/thing.gdc")), "and writes game/thing.gdc")
	_check(not FileAccess.file_exists(proj.path_join("export_presets.cfg")), "and leaves no preset in the project")

	var keys := DotCloudSignature.generate_keypair(2048)
	_check(keys.ok, "a signing key pair is generated")
	if not keys.ok or code != 0:
		_done()
		return
	var pair: Dictionary = keys.value

	var plain := _publish(proj, work.path_join("out_plain"), "tok_plain", str(pair["private"]), "")
	_check(plain.has("game/thing.gd") and not plain.has("game/thing.gdc"), "by default the script ships as text")

	var out := work.path_join("out_tok")
	var toks := _publish(proj, out, "tok_pack", str(pair["private"]), tokens)
	_check(toks.has("game/thing.gdc") and toks.has("game/thing.gd.remap"), "with tokens it ships .gdc and .gd.remap")
	_check(not toks.has("game/thing.gd"), "and not the text")
	_check(not DirAccess.dir_exists_absolute(out.path_join(".tokens")), "the staging directory is not left in the output")

	DotPaths.write_text(tokens.path_join("engine.txt"), "4.0.0.stable.official.000000000\n")
	var stale := _publish(proj, work.path_join("out_stale"), "tok_stale", str(pair["private"]), tokens)
	_check(stale.has("game/thing.gd") and not stale.has("game/thing.gdc"), "tokens from another engine build fall back to text")
	DotPaths.write_text(tokens.path_join("engine.txt"), DotCloudPublisher.engine_stamp())

	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = WORK.path_join("cache")
	cloud.config.trusted_keys = {"test": {"key": str(pair["public"]), "content_ids": ["tok_*"]}}
	cloud.config_file = ""
	add_child(cloud)
	var got: Variant = await cloud.acquire(out.path_join("manifest.json"))
	_check(got is DotResult and (got as DotResult).ok, "the client acquires and mounts it")

	var warmed: DotCloudSliceLoader = await cloud.warm_content(get_tree(), PackedStringArray(cloud.acquired_keys()), true)
	var compiled := warmed.loaded.filter(func(r: Resource) -> bool: return r is Script)
	_check(not compiled.is_empty(), "warm_content compiles the tokenized script", str(warmed.loaded.size()))

	var packed: PackedScene = load("res://dot_cloud/tok_pack/1.0.0/scenes/world.tscn")
	_check(packed != null, "the scene loads")
	if packed != null:
		var node := packed.instantiate()
		_check(node.get_script() != null, "with its script")
		_check(node.get_script() != null and node.call("who") == "TOKENIZED", "which runs")
		node.free()

	_done()


func _publish(src: String, out: String, id: String, key: String, tokens: String) -> Dictionary:
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = "1.0.0"
	pub.entry_scene = "scenes/world.tscn"
	pub.signing_key_pem = key
	pub.script_tokens_dir = tokens
	var res := pub.publish(src, out)
	_check(res.ok, "%s publishes" % id, str(res.error) if not res.ok else "")
	var paths := {}
	var bytes := DotPaths.read_bytes(out.path_join("manifest.json"))
	if res.ok and bytes.ok:
		var m := DotCloudManifest.from_json_bytes(bytes.value)
		if m.ok:
			for entry in (m.value as DotCloudManifest).files:
				paths[entry.path] = true
	return paths


func _check(ok: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	_line("  %s %s%s" % ["ok  " if ok else "FAIL", what, (" (%s)" % detail) if detail != "" else ""])


func _done() -> void:
	_check(_checks + 1 == CHECKS, "every check ran", "%d of %d" % [_checks + 1, CHECKS])
	_line("%d passed, %d failed" % [_checks - _failures, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
