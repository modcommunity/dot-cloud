extends Node

## The mounted-pack boot test's probe (tools/pack_boot_test.sh copies it into a host project built at the
## addons.lock tags). It mounts a pack's objects the way dot-cloud's mounter does (a .pck under
## res://dot_cloud/<id>/<version>/) and fails when anything a server boots from would not:
##   - a script the pack ships does not compile against the host's addons (a stale tree, an addon API drift);
##   - game.yml's module, scene or client_scene does not load;
##   - the module does not instantiate, or its _make_bridge() hands back no bridge (the host then logs
##     "A game has to supply the bridge between itself and the netcode" and the server hibernates);
##   - requires.json names an addon the host lacks, or a level above the one it carries.
## User args: OUT_DIR (manifest.json and objects/<2>/<sha>: a publish dry-run's --out, or tools/pack_fetch.py's).
## Exit 0 clean, 1 failures (each printed), 2 usage.

var _bad := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("pack_boot: usage: -- OUT_DIR")
		get_tree().quit(2)
		return
	get_tree().quit(_run(args[0]))


func _run(out: String) -> int:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("manifest.json")))
	if not (manifest is Dictionary) or not (manifest as Dictionary).has("files"):
		printerr("pack_boot: no readable manifest.json in %s" % out)
		return 2
	var m := manifest as Dictionary
	var prefix := "res://%s/%s/%s" % [str(m.get("mount_root", "dot_cloud")), str(m["content_id"]), str(m["version"])]
	var pck := OS.get_temp_dir().path_join("pack_boot_%d.pck" % OS.get_process_id())
	var packer := PCKPacker.new()
	if packer.pck_start(pck) != OK:
		printerr("pack_boot: cannot write %s" % pck)
		return 2
	var scripts: PackedStringArray = []
	var by_path := {}
	for f: Dictionary in m["files"]:
		var sha := str(f["sha256"])
		var obj := out.path_join("objects").path_join(sha.substr(0, 2)).path_join(sha)
		if not FileAccess.file_exists(obj):
			_fail("%s: object %s is not in %s" % [f["path"], sha, out])
			continue
		var at := prefix.path_join(str(f["path"]))
		packer.add_file(at, obj)
		by_path[str(f["path"])] = obj
		if at.ends_with(".gd"):
			scripts.append(at)
	packer.flush()
	if not ProjectSettings.load_resource_pack(pck, false):
		printerr("pack_boot: the engine would not mount %s" % pck)
		return 2
	print("pack_boot: mounted %d files at %s" % [by_path.size(), prefix])

	_check_requires(by_path)

	for path in scripts:
		var s := load(path) as GDScript
		if s == null or not s.can_instantiate():
			_fail("%s does not compile against the host's addons: %s" % [path, _first_error(path, prefix)])

	var yml := FileAccess.get_file_as_string(str(by_path.get("game.yml", "")))
	for key in ["module", "scene", "client_scene"]:
		var rel := _yml_value(yml, key)
		if rel == "":
			continue
		var res: Resource = load(prefix.path_join(rel))
		if res == null or (res is GDScript and not (res as GDScript).can_instantiate()):
			_fail("game.yml %s (%s) does not load mounted" % [key, rel])
			continue
		print("pack_boot: game.yml %s loads: %s" % [key, rel])
		if key == "module" and res is GDScript:
			_check_module(res as GDScript, rel)

	DirAccess.remove_absolute(pck)
	print("pack_boot: %d script(s) compiled, %d failure(s)" % [scripts.size(), _bad])
	return 1 if _bad > 0 else 0


## What the host does first with a module (dot_module_host.gd _instantiate_module, then DotGameModule's
## netcode start): make one and ask it for its bridge. Neither is added to the tree; both are freed.
func _check_module(script: GDScript, rel: String) -> void:
	var module: Object = script.new()
	if module == null:
		_fail("game.yml module (%s) does not instantiate" % rel)
		return
	if module.has_method("_make_bridge"):
		var bridge: Variant = module.call("_make_bridge")
		if not (bridge is Node):
			_fail("game.yml module (%s): _make_bridge() hands back no bridge; the host would refuse the game" % rel)
		else:
			print("pack_boot: the module makes its bridge: %s" % (bridge as Node).get_class())
			(bridge as Node).free()
	if module is Node:
		(module as Node).free()
	elif not (module is RefCounted):
		module.free()


func _check_requires(by_path: Dictionary) -> void:
	if not by_path.has("requires.json"):
		print("pack_boot: no requires.json in the pack")
		return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(by_path["requires.json"])))
	var addons: Dictionary = (doc as Dictionary).get("addons", {}) if doc is Dictionary else {}
	for name: String in addons:
		var dir := "res://addons/%s" % name
		if not DirAccess.dir_exists_absolute(dir):
			_fail("requires.json names %s, which the host does not carry" % name)
			continue
		var level := 1
		var api := FileAccess.get_file_as_string("%s/%s_api.gd" % [dir, name])
		var m := RegEx.create_from_string("(?m)^const LEVEL *:= *(\\d+)").search(api)
		if m != null:
			level = m.get_string(1).to_int()
		if int(addons[name]) > level:
			_fail("requires.json asks %s level %d; the host carries %d" % [name, int(addons[name]), level])


## The engine's first script error for [param path], as "file:line: Parse Error: ..." (file relative to the
## mount): a loaded script does not keep its errors, so it is parsed again, uncached, with the error stream captured.
## A script that fails only because one it uses does not compile has no error of its own; that is said instead.
static func _first_error(path: String, prefix: String) -> String:
	var capture := _ScriptErrorCapture.new()
	OS.add_logger(capture)
	ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	OS.remove_logger(capture)
	var first := capture.first()
	return first.replace(prefix + "/", "") if first != "" else "no error of its own (a script it uses does not compile)"


class _ScriptErrorCapture extends Logger:
	var _lock := Mutex.new()
	var _errors: PackedStringArray = []

	func _log_error(
		_function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_lock.lock()
		_errors.append("%s:%d: %s" % [file, line, (code if rationale == "" else "%s %s" % [code, rationale]).strip_edges()])
		_lock.unlock()

	func first() -> String:
		_lock.lock()
		var e := "" if _errors.is_empty() else _errors[0]
		_lock.unlock()
		return e


static func _yml_value(text: String, key: String) -> String:
	for line in text.split("\n"):
		if line.begins_with(key + ":"):
			return line.substr(key.length() + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""


func _fail(text: String) -> void:
	_bad += 1
	printerr("pack_boot: FAIL %s" % text)
