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
	# [b]Scoped to content ids this pack is NOT one of, first.[/b] A trusted key used to
	# mean "trusted for everything there is", which with one key is a distinction without
	# a difference -- and the moment a deployment adds a second publisher it is the hole
	# that lets them sign a manifest claiming somebody else's game. The signature below is
	# genuinely valid; what is being checked is that a valid signature from the wrong key
	# is still refused.
	cloud.config.trusted_keys = {
		"test": {"key": str(pair["public"]), "content_ids": ["somebody_else_*"]}
	}
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

	var refused: Variant = await cloud.acquire(out.path_join("manifest.json"))
	_check(
		refused is DotResult and not (refused as DotResult).ok,
		"a key scoped to other content cannot vouch for this pack",
		"it mounted anyway" if refused is DotResult and (refused as DotResult).ok else ""
	)
	_check(
		not ResourceLoader.exists("res://dot_cloud/delivered_scene/1.0.0/scenes/world.tscn"),
		"and nothing of it was mounted"
	)

	# The same key, now entitled to this id. A glob because a publisher's namespace is a
	# prefix in every deployment that has ever had one.
	cloud.config.trusted_keys = {
		"test": {"key": str(pair["public"]), "content_ids": ["delivered_*"]}
	}

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

	_check_imported_outputs(str(pair["private"]))

	_done()


## [b]A pack published from a project ROOT carried no imported outputs at all.[/b]
##
## [member DotCloudPublisher.include_imported] exists because a `.png` or a `.glb` is not
## a loadable resource -- the editor imports it into `.godot/imported/` and the `.import`
## marker beside it redirects every load there. The publisher handled the case it was
## written against (an imported map, published from a SUBDIRECTORY of a project) and
## returned empty for a source that IS the project root, on the grounds that the file
## walk had already found them. It never had:
## [method DotPaths.list_files_recursive] goes through [method DirAccess.list_dir_begin],
## which skips hidden entries, and `.godot` is hidden.
##
## So every delivered game shipped its markers and none of its textures or meshes, and
## said nothing until a CLIENT tried to draw one -- a different process, a different log,
## and a dedicated server that neither drew anything nor cared.
##
## Built by hand rather than by importing something, because the trap is in the file
## WALK: a fixture the engine imported would be a fixture this suite could only find the
## same way the publisher does.
func _check_imported_outputs(key_pem: String) -> void:
	_line("")
	_line("[b]a pack carries the imported form of its assets[/b]")

	var root := WORK.path_join("project")
	var ctex := ".godot/imported/tile.png-abc123.ctex"

	DotPaths.ensure_dir(root.path_join("textures"))
	DotPaths.ensure_dir(root.path_join(".godot/imported"))
	DotPaths.ensure_dir(root.path_join("screenshots"))

	DotPaths.write_text(root.path_join("project.godot"), "config_version=5\n")
	DotPaths.write_text(root.path_join("textures/tile.png"), "not really a png")
	DotPaths.write_text(root.path_join("textures/tile.png.import"),
		"[remap]\n\npath=\"res://%s\"\n" % ctex)
	DotPaths.write_text(root.path_join(ctex), "the imported form")

	# An asset in a directory the publisher was told to skip. Its marker used to be kept
	# whatever the exclusions said -- markers were decided before them -- and once a marker
	# is in the pack the output it names follows it in.
	DotPaths.write_text(root.path_join("screenshots/shot.png"), "not really a png")
	DotPaths.write_text(root.path_join("screenshots/shot.png.import"),
		"[remap]\n\npath=\"res://.godot/imported/shot.png-def456.ctex\"\n")
	DotPaths.write_text(root.path_join(".godot/imported/shot.png-def456.ctex"), "excluded")

	var landed := "_imported/tile.png-abc123.ctex"
	var from_root := _publish_paths(root, WORK.path_join("pub_root"), "from_root", key_pem)

	_check(from_root.has(landed),
		"published from the project root, the pack carries the .ctex the marker names",
		", ".join(PackedStringArray(from_root.keys())))
	_check(not from_root.has(ctex),
		"under a plain directory, because a web export cannot read `.godot/` out of a pack")
	_check(from_root.has("textures/tile.png.import"),
		"and the marker that redirects the load to it")

	# The marker has to point at where the output LANDED. Rewriting it to
	# `<mount>/.godot/imported/…` would name a file the pack does not contain, which is a
	# texture that silently does not load -- the exact failure include_imported exists to
	# prevent, reintroduced by the fix for it.
	#
	# Read out of the published OBJECT rather than off the staging tree: staging is
	# deleted on the way out, and reading what was actually published is the better
	# question anyway.
	var marker := _published_text(
		WORK.path_join("pub_root"), from_root.get("textures/tile.png.import", "")
	)
	_check(
		marker.contains("res://dot_cloud/from_root/1.0.0/" + landed),
		"and the marker points at where the output landed, not at where it came from",
		marker.strip_edges()
	)
	_check(not from_root.has(".godot/imported/shot.png-def456.ctex"),
		"and nothing from a directory the publisher was told to skip")
	_check(not from_root.has("screenshots/shot.png.import"),
		"including that directory's markers, which used to be kept regardless")

	# The shape that was already working, kept working: every imported map is published
	# this way and it is the only shape the publisher was ever exercised in.
	var from_sub := _publish_paths(
		root.path_join("textures"), WORK.path_join("pub_sub"), "from_sub", key_pem
	)

	_check(from_sub.has(landed),
		"published from a subdirectory, the output still comes with it",
		", ".join(PackedStringArray(from_sub.keys())))


## Publish [param source] and return the manifest's file paths as a set.
func _publish_paths(
	source: String, out: String, id: String, key_pem: String
) -> Dictionary:
	var pub := DotCloudPublisher.new()
	pub.content_id = id
	pub.version = "1.0.0"
	pub.signing_key_pem = key_pem
	pub.exclude_dirs.append("screenshots")

	var res := pub.publish(source, out)
	if not res.ok:
		_check(false, "%s publishes" % id, str(res.error))
		return {}

	var bytes := DotPaths.read_bytes(out.path_join("manifest.json"))
	if not bytes.ok:
		_check(false, "%s's manifest reads back" % id, str(bytes.error))
		return {}

	var manifest := DotCloudManifest.from_json_bytes(bytes.value)
	if not manifest.ok:
		_check(false, "%s's manifest parses" % id, str(manifest.error))
		return {}

	var paths := {}
	for entry in (manifest.value as DotCloudManifest).files:
		paths[entry.path] = entry.sha256
	return paths


## The bytes a published pack actually holds for one file, as text.
func _published_text(out: String, sha: String) -> String:
	if sha == "":
		return ""
	return FileAccess.get_file_as_string(
		out.path_join("objects").path_join(sha.substr(0, 2)).path_join(sha)
	)


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
