extends Node

## Newer addons as packs, laid over the build at the next start.
##
## [b]What this proves, and why it takes four processes.[/b] The overlay only works if it is
## mounted before any addon script is compiled, so the check cannot be made from inside the
## process that built it: this suite builds an overlay, then starts the project again --
## through `addon_boot_probe.tscn`, a main scene exactly like a shell's -- and reads back
## what the new process found. Once for a start that works, once each for the two ways a
## start must refuse the overlay (an earlier start that never arrived, and an overlay made
## for another build), and once with nothing to mount.
##
## The pack is `modcommunity/dot-probe@0.2.0`, published here with a key made for the run:
## a class this build has never heard of, a scene that names its script by absolute path,
## and the API file a probe is taken from. The build's own record says `dot-probe v0.1.0`
## (`res://addons.lock`, written for the run and removed after).
##
## [codeblock]
## godot --headless --path . res://examples/addon_set_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_addon_set_demo"
const LOCK := "res://addons.lock"

## Every check, including the one that compares against it. See docs/testing.md.
const CHECKS := 47

var _failures := 0
var _checks := 0
var _sections := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	print("addon packs over a build")
	_run.call_deferred()


func _run() -> void:
	DotPaths.remove_tree(WORK)
	DotPaths.remove_tree(DotCloudAddonSet.DIR)
	ProjectSettings.set_setting("dot_cloud/addon_overlay", "")
	_write(LOCK, "# for addon_set_demo\ndot-probe\tv0.1.0\ndot-core\tv0.1.5\n")

	_versions()
	_class_list()
	_policy()
	var cloud := await _published_client()

	if cloud != null:
		await _builds(cloud)
		_boots()

	_finish()


# --- 1 ---------------------------------------------------------------------

func _versions() -> void:
	_section("versions compare by number")
	_check(DotCloudAddonSet.compare_versions("0.1.10", "0.1.9") == 1, "0.1.10 is newer than 0.1.9")
	_check(DotCloudAddonSet.compare_versions("v0.1.5", "0.1.5") == 0, "a leading v is the same version")
	_check(DotCloudAddonSet.compare_versions("0.2", "0.2.0") == 0, "a missing part is a zero")
	_check(DotCloudAddonSet.compare_versions("0.1.4", "0.1.5") == -1, "0.1.4 is older than 0.1.5")
	_done()


# --- 1b --------------------------------------------------------------------

## The class list written from script headers, against the one the editor wrote for this
## project. A field that differs is a type check that differs from the editor's.
func _class_list() -> void:
	_section("the class list from headers is the editor's")
	var editor := DotCloudScriptClass.read_cache()
	var scripts := {}

	for root: String in ["res://addons/dot_cloud", "res://addons/dot_core"]:
		for rel in DotPaths.list_files_recursive(root):
			if rel.ends_with(".gd"):
				var path := root.path_join(rel)
				scripts[path] = FileAccess.get_file_as_string(path)

	var mine := {}
	for entry in DotCloudScriptClass.entries_for(scripts):
		mine[str(entry["class"])] = entry

	var compared := 0
	var differ := PackedStringArray()

	for entry in editor:
		var path := str(entry.get("path", ""))
		if not (path.begins_with("res://addons/dot_cloud/") or path.begins_with("res://addons/dot_core/")):
			continue
		compared += 1
		var m: Variant = mine.get(str(entry.get("class", "")))
		if m == null:
			differ.append("%s missing" % entry["class"])
			continue
		for key in ["base", "icon", "is_abstract", "is_tool", "language", "path"]:
			if str((m as Dictionary)[key]) != str(entry.get(key)):
				differ.append("%s.%s" % [entry["class"], key])

	_check(compared > 50 and differ.is_empty() and mine.size() == compared,
		"%d classes, every field the editor's" % compared, ", ".join(differ.slice(0, 8)))

	var merged := DotCloudScriptClass.merge(editor, PackedStringArray(["res://addons/dot_cloud"]), [])
	var cfg := ConfigFile.new()
	_check(cfg.parse(DotCloudScriptClass.cache_text(merged)) == OK
		and (cfg.get_value("", "list", []) as Array).size() == editor.size() - mine.keys().filter(func(c): return str(mine[c]["path"]).begins_with("res://addons/dot_cloud/")).size(),
		"and a merge that drops an addon round-trips through the engine's format")
	_done()


# --- 2 ---------------------------------------------------------------------

func _entry(dir: String, id: String, version: String) -> Dictionary:
	return {"dir": dir, "repo": dir.replace("_", "-"), "id": id, "version": version}


func _policy() -> void:
	_section("what a server's list asks for")
	var set := DotCloudAddonSet.new()
	set.namespaces = PackedStringArray(["modcommunity/", "alice/x"])

	var newer: Dictionary = set.plan_for([_entry("dot_probe", "modcommunity/dot-probe", "0.2.0")])
	_check((newer["wanted"] as Dictionary).has("dot_probe"), "a newer version is wanted")

	var same: Dictionary = set.plan_for([_entry("dot_probe", "modcommunity/dot-probe", "v0.1.0")])
	_check((same["wanted"] as Dictionary).is_empty(), "the version this build has is not")

	var older: Dictionary = set.plan_for([_entry("dot_core", "modcommunity/dot-core", "0.1.4")])
	_check((older["wanted"] as Dictionary).is_empty(), "nor an older one: a server never takes a client backwards")

	var unknown: Dictionary = set.plan_for([_entry("dot_newthing", "modcommunity/dot-newthing", "0.1.0")])
	_check((unknown["wanted"] as Dictionary).has("dot_newthing"), "an addon this build does not have is wanted")

	var foreign: Dictionary = set.plan_for([_entry("dot_probe", "mallory/dot-probe", "9.0.0")])
	_check((foreign["wanted"] as Dictionary).is_empty() and (foreign["refused"] as Dictionary).has("dot_probe"),
		"a pack from a namespace this client does not take is refused", str(foreign["refused"]))

	var mislabelled: Dictionary = set.plan_for([{"dir": "dot_probe", "repo": "dot-probe", "id": "modcommunity/dot-net", "version": "9.0.0"}])
	_check((mislabelled["wanted"] as Dictionary).is_empty(), "a repository that is not the pack's own name is refused", str(mislabelled["refused"]))

	var lookalike: Dictionary = set.plan_for([_entry("x", "alice/x-evil", "1.0.0")])
	_check((lookalike["wanted"] as Dictionary).is_empty(), "an exact id does not admit its lookalikes")

	var exact: Dictionary = set.plan_for([_entry("x", "alice/x", "1.0.0")])
	_check((exact["wanted"] as Dictionary).has("x"), "and does admit itself")

	var escape: Dictionary = set.plan_for([
		_entry("../dot_core", "modcommunity/dot-core", "9.0.0"),
		_entry("Dot_UI", "modcommunity/dot-ui", "9.0.0"),
	])
	_check((escape["wanted"] as Dictionary).is_empty() and (escape["refused"] as Dictionary).size() == 2,
		"a directory that is not one plain name is refused", str(escape["refused"]))

	# What is already running counts: the overlay raised dot_probe to 0.2.0 this start.
	DotCloudAddonSet.write_plan({"pack": "user://dot_cloud_addons/overlay-x.pck", "addons": {
		"dot_probe": _entry("dot_probe", "modcommunity/dot-probe", "0.2.0")}})
	ProjectSettings.set_setting("dot_cloud/addon_overlay", "user://dot_cloud_addons/overlay-x.pck")

	var held: Dictionary = set.plan_for([_entry("dot_probe", "modcommunity/dot-probe", "0.2.0")])
	_check((held["wanted"] as Dictionary).is_empty(), "a version the running overlay already has needs nothing")

	var widened: Dictionary = set.plan_for([_entry("dot_newthing", "modcommunity/dot-newthing", "0.1.0")])
	_check((widened["wanted"] as Dictionary).has("dot_probe") and (widened["wanted"] as Dictionary).has("dot_newthing"),
		"and a new set keeps what the overlay raised, rather than taking it backwards")

	ProjectSettings.set_setting("dot_cloud/addon_overlay", "")
	DotCloudAddonSet.forget()
	_check(DotCloudAddonSet.read_plan().is_empty(), "forget() leaves no plan")
	_done()


# --- 3 ---------------------------------------------------------------------

func _published_client() -> DotCloudClient:
	_section("an addon published as a pack")
	var src := WORK.path_join("source")
	DotPaths.ensure_dir(src.path_join("ui"))
	_write(src.path_join("plugin.cfg"), "[plugin]\n\nname=\"Dot Probe\"\nversion=\"0.2.0\"\nscript=\"\"\n")
	_write(src.path_join("dot_probe_api.gd"), "extends RefCounted\n\nconst LEVEL := 2\nconst OLDEST := 1\n")
	_write(src.path_join("dot_probe_thing.gd"), "@tool\nclass_name DotProbeThing\nextends RefCounted\n\nstatic func hello() -> String:\n\treturn \"v2 from the pack\"\n")
	_write(src.path_join("dot_probe_thing.gd.uid"), "uid://b7prob3th1ng\n")
	_write(src.path_join("ui/panel_script.gd"), "extends Node\n\nfunc _init() -> void:\n\tset_meta(\"v\", \"panel v2\")\n")
	_write(src.path_join("ui/panel.tscn"), "[gd_scene format=3]\n\n[ext_resource type=\"Script\" path=\"res://addons/dot_probe/ui/panel_script.gd\" id=\"1\"]\n\n[node name=\"P\" type=\"Node\"]\nscript = ExtResource(\"1\")\n")

	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		_check(false, "a signing key pair is generated", str(keys.error))
		_done()
		return null

	var pair: Dictionary = keys.value
	var pub := DotCloudPublisher.new()
	pub.content_id = "modcommunity/dot-probe"
	pub.version = "0.2.0"
	pub.signing_key_pem = str(pair["private"])
	# An addon references itself by absolute `res://addons/...` paths, which are right where
	# the overlay puts it; a rewrite onto a mount prefix would be wrong here.
	pub.rewrite_resource_paths = false
	# Published the way the site publishes an addon release, which keeps each script's
	# `.uid`; dot-cloud's own default leaves them out.
	pub.exclude_suffixes = PackedStringArray([".import", ".tmp"])

	var origin := WORK.path_join("origin")
	var published := pub.publish(src, origin.path_join("modcommunity/dot-probe/0.2.0"))
	_check(published.ok, "the addon publishes as a pack", str(published.error) if not published.ok else "")

	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = DotCloudConfig.new()
	cloud.config.cache_dir = WORK.path_join("cache")
	cloud.config.trusted_keys = {"test": str(pair["public"])}
	cloud.config_file = ""
	cloud.local_search_dirs = PackedStringArray([origin])
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	add_child(cloud)

	_done()
	return cloud if published.ok else null


func _builds(cloud: DotCloudClient) -> void:
	_section("the overlay is built, and nothing is mounted")
	var set := DotCloudAddonSet.new(cloud)
	var decided := set.plan_for([_entry("dot_probe", "modcommunity/dot-probe", "0.2.0")])
	var built: DotResult = await set.build(decided["wanted"], {"server": "127.0.0.1:1"})
	_check(built.ok, "build() fetches the pack and writes the overlay", str(built.error) if not built.ok else "")

	var plan := DotCloudAddonSet.read_plan()
	_check(str(plan.get("state", "")) == DotCloudAddonSet.STATE_READY, "the plan is ready for the next start")
	_check(FileAccess.file_exists(str(plan.get("pack", ""))), "the overlay is on the disk", str(plan.get("pack", "")))
	_check(str(plan.get("build", "")) == DotCloudAddonSet.build_fingerprint(), "and names the build it was made for")
	_check(str((plan.get("probes", {}) as Dictionary).get("dot_probe", "")) == "res://addons/dot_probe/dot_probe_api.gd",
		"the probe is the addon's API file", str(plan.get("probes", {})))
	_check(str(plan.get("uids", [])).contains("uid://b7prob3th1ng"), "the pack's uids are listed for the boot to register")
	_check(str((plan.get("resume", {}) as Dictionary).get("server", "")) == "127.0.0.1:1", "and where to go back to")
	_check(not ResourceLoader.exists("res://addons/dot_probe/dot_probe_thing.gd"), "nothing of it is in this process")
	_check(not ResourceLoader.exists("res://dot_cloud/modcommunity/dot-probe/0.2.0/plugin.cfg")
		and not FileAccess.file_exists("res://dot_cloud/modcommunity/dot-probe/0.2.0/plugin.cfg"),
		"not even at the pack's own mount prefix")

	# The dot-probe pack, aimed at the directory where this build keeps dot-cloud.
	var plan_before := FileAccess.get_file_as_string(DotCloudAddonSet.PLAN)
	var wrong: DotResult = await set.build({"dot_cloud": {"dir": "dot_cloud", "repo": "dot-probe", "id": "modcommunity/dot-probe", "version": "0.2.0"}}, {})
	_check(not wrong.ok and FileAccess.get_file_as_string(DotCloudAddonSet.PLAN) == plan_before,
		"a pack aimed at a directory holding a different addon is refused, and nothing is written",
		str(wrong.error) if not wrong.ok else "it built")

	var again: DotResult = await set.build(decided["wanted"], {})
	_check(again.ok and str((again.value as Dictionary).get("pack", "")) == str(plan.get("pack", "")),
		"the same set builds the same file, which is reused rather than rewritten")
	_done()


# --- 4 ---------------------------------------------------------------------

## Starts this project again through the boot scene and returns what it reported.
func _start() -> Dictionary:
	var out: Array = []
	OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/addon_boot_probe.tscn",
	], out, true)

	var text := "\n".join(out)

	for line in text.split("\n"):
		if line.begins_with("PROBE "):
			var parsed: Variant = JSON.parse_string(line.substr(6))
			if parsed is Dictionary:
				(parsed as Dictionary)["log"] = text
				return parsed

	return {"log": text}


func _boots() -> void:
	_section("a start on the overlay")
	var started := _start()
	_check(str(started.get("mounted", "")) != "", "the boot scene mounted it", str(started.get("log", "")).right(400))
	_check(bool(started.get("class", false)), "a class the build never had is a global")
	_check(str(started.get("hello", "")) == "v2 from the pack", "and runs", str(started.get("hello", "")))
	_check(str(started.get("typed", "")) == "v2 from the pack", "a script naming it as a TYPE compiles after the boot", str(started.get("typed", "")))
	_check(str(started.get("panel", "")) == "panel v2", "an addon scene loads its script from the overlay", str(started.get("panel", "")))
	_check(str(started.get("uid", "")) == "res://addons/dot_probe/dot_probe_thing.gd", "its uid resolves to the overlaid file", str(started.get("uid", "")))
	_check(str(started.get("state", "")) == DotCloudAddonSet.STATE_OK, "confirm_boot() marks the start arrived", str(started.get("state", "")))
	_check(FileAccess.file_exists(DotCloudAddonSet.SHELL_CLASSES), "and the build's own class list was kept for the next merge")
	_done()

	_section("a start that never arrived, twice, is not repeated")
	var plan := DotCloudAddonSet.read_plan()
	plan["state"] = DotCloudAddonSet.STATE_BOOTING
	plan["attempts"] = 1
	DotCloudAddonSet.write_plan(plan)

	var guarded := _start()
	_check(str(guarded.get("mounted", "x")) == "", "the boot comes up without the overlay", str(guarded.get("log", "")).right(400))
	_check(not bool(guarded.get("class", true)), "so the overlay's class is not there")
	_check(str(DotCloudAddonSet.read_plan().get("state", "")) == DotCloudAddonSet.STATE_FAILED, "and the plan says it failed")
	_check(DotCloudAddonSet.failed_before(plan.get("addons", {})), "which a shell reads as: do not build this set again")
	_done()

	_section("an overlay made for another build is ignored")
	plan["state"] = DotCloudAddonSet.STATE_READY
	plan["attempts"] = 0
	plan["build"] = "0000000000000000"
	DotCloudAddonSet.write_plan(plan)

	var other := _start()
	_check(str(other.get("mounted", "x")) == "", "a new build does not mount an old build's overlay")
	_check(str(other.get("log", "")).contains("made for another build"), "and says why")
	_done()

	_section("no plan, no overlay")
	DotCloudAddonSet.forget()
	var bare := _start()
	_check(str(bare.get("mounted", "x")) == "" and not bool(bare.get("class", true)), "a start with no plan is the build as it shipped")
	_done()


# --- harness ---------------------------------------------------------------

func _finish() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LOCK))
	DotPaths.remove_tree(DotCloudAddonSet.DIR)
	DotPaths.remove_tree(WORK)

	_check(_completed == _sections, "every section ran to its last line", "%d of %d" % [_completed, _sections])
	_check(_checks + 1 == CHECKS, "every check ran", "%d of %d" % [_checks + 1, CHECKS])
	print("")
	print("%d passed, %d failed" % [_checks - _failures, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _section(title: String) -> void:
	_sections += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("  %s %s%s" % ["ok  " if ok else "FAIL", what, (" (%s)" % detail) if detail != "" and not ok else ""])


func _write(path: String, text: String) -> void:
	DotPaths.ensure_parent_dir(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
