extends Node

## A scene delivered in a pack, with its script, actually running.
##
## [b]This is the case the whole delivery path exists for and nothing had ever run
## it.[/b] Every other suite here publishes DATA -- a texture, a blob, a manifest --
## and the one scene any of them publishes carries no script, which is exactly the
## half that was broken:
##
##     mount: true   scene exists: true
##     ERROR: Attempt to open script 'res://s.gd' … 'File not found'
##
## Godot writes a scene's script reference as an ABSOLUTE `res://` path, and a pack
## mounts at `res://<mount_root>/<id>/<version>/`. So the scene loads and its script
## is simply gone -- no error at mount, none at load, and none until something calls a
## method on it. [DotCloudPublisher] rewrites those references now, and this is the
## check that says so.
##
## [codeblock]
## godot --headless --path . res://examples/delivered_scene_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_delivered_scene"

var _failures := 0
var _checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_line("[b]a delivered scene, with its script[/b]")

	DotPaths.remove_tree(WORK)

	var src := WORK.path_join("source")
	var out := WORK.path_join("published")

	# --- a game-shaped source tree: a scene in one directory, its script in another
	DotPaths.ensure_dir(src.path_join("game"))
	DotPaths.ensure_dir(src.path_join("scenes"))

	DotPaths.write_text(src.path_join("game/thing.gd"), """extends Node

func who() -> String:
	return "DELIVERED"
""")

	# Written the way Godot writes one: the script named by absolute res:// path.
	DotPaths.write_text(src.path_join("scenes/world.tscn"), """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://game/thing.gd" id="1"]

[node name="World" type="Node"]
script = ExtResource("1")
""")

	# --- publish
	var keys := DotCloudSignature.generate_keypair(2048)
	_check(keys.ok, "a signing key pair is generated")
	if not keys.ok:
		_done()
		return

	var pair: Dictionary = keys.value

	var pub := DotCloudPublisher.new()
	pub.content_id = "delivered_scene"
	pub.version = "1.0.0"
	pub.entry_scene = "scenes/world.tscn"
	pub.signing_key_pem = str(pair["private"])

	var published := pub.publish(src, out)
	_check(published.ok, "the pack publishes", str(published.error) if not published.ok else "")
	if not published.ok:
		_done()
		return

	var info: Dictionary = published.value
	_check(
		int(info.get("rewritten", 0)) == 1,
		"one text resource had its paths rewritten",
		"rewritten=%s" % str(info.get("rewritten", 0))
	)

	# The staging tree must not survive into something somebody uploads.
	_check(
		not DirAccess.dir_exists_absolute(out.path_join(".rewritten")),
		"and the staging tree is gone from the published directory"
	)

	# --- acquire and mount
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = WORK.path_join("cache")
	cloud.config.trusted_keys = {"test": str(pair["public"])}
	cloud.config_file = ""
	# [b]Deliberately NOT told where the content is.[/b] The published directory holds the
	# manifest AND its objects, so naming the manifest names the objects too -- and this
	# demo used to hand the directory over in `local_search_dirs`, which meant it passed
	# whether or not the client could work that out for itself. It could not: a server
	# whose `game.yml` pointed at `dist/<id>/manifest.json` read the manifest off the disk
	# and then asked the network for all 140 files beside it, failing with "140 missing"
	# on a box that had every one of them. Left empty here so this suite is the thing that
	# says so.
	add_child(cloud)

	var got: Variant = await cloud.acquire(out.path_join("manifest.json"))
	_check(got is DotResult and (got as DotResult).ok, "the client acquires and mounts it",
		"" if got is DotResult and (got as DotResult).ok else str((got as DotResult).error))

	_check(
		cloud.local_search_dirs.has(out),
		"having worked out for itself that the objects are beside the manifest",
		"local_search_dirs=%s" % str(cloud.local_search_dirs)
	)

	# --- the whole point
	var scene_path := "res://dot_cloud/delivered_scene/1.0.0/scenes/world.tscn"
	_check(ResourceLoader.exists(scene_path), "the scene is at the mounted path")

	var packed: PackedScene = load(scene_path)
	_check(packed != null, "and it loads")

	if packed != null:
		var node := packed.instantiate()
		_check(node.get_script() != null, "WITH ITS SCRIPT, which is the bug this proves fixed")
		if node.get_script() != null:
			_check(node.call("who") == "DELIVERED", "and the script actually runs")
		node.free()

	_done()


func _check(ok: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail
	_line("  %s %s%s" % ["ok  " if ok else "FAIL", what, suffix])


func _done() -> void:
	_line("")
	_line("%d passed, %d failed" % [_checks - _failures, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
