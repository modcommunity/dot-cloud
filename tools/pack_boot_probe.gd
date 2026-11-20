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
## Exit 0 clean, 1 failures (each printed), 2 usage or a check that could not be judged off the tree.

var _bad := 0
## Checks the probe could not decide off the tree (exit 2 when nothing failed).
var _unjudged := 0
var _pcks: PackedStringArray = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("pack_boot: usage: -- OUT_DIR")
		get_tree().quit(2)
		return
	var rc := _run(args[0])
	for pck in _pcks:
		DirAccess.remove_absolute(pck)
	get_tree().quit(rc)


func _run(out: String) -> int:
	var manifest: Variant = _unwrap(JSON.parse_string(FileAccess.get_file_as_string(out.path_join("manifest.json"))))
	if not (manifest is Dictionary) or not (manifest as Dictionary).has("files"):
		printerr("pack_boot: no readable manifest.json in %s" % out)
		return 2
	var m := manifest as Dictionary
	var prefix := "res://%s/%s/%s" % [str(m.get("mount_root", "dot_cloud")), str(m["content_id"]), str(m["version"])]
	# A server fetches the server and both files only (DotCloudFile.side; an unknown side is both): it is judged on
	# that view first, so a server script reaching a client-only file fails here as it would on the server.
	var server_files: Array = []
	var client_files: Array = []
	for f: Dictionary in m["files"]:
		(client_files if str(f.get("side", "both")) == "client" else server_files).append(f)
	var sv := _mount(out, prefix, server_files, "server")
	if sv.is_empty():
		return 2
	var by_path: Dictionary = sv["by_path"]
	var scripts: PackedStringArray = sv["scripts"]
	_check_requires(by_path)
	if by_path.has("game.yml") and scripts.is_empty() and client_files.is_empty():
		_fail("a game pack with no script to compile (no .gd, .gd.remap or .gdc): nothing would run")
	_check_scripts(sv["scripts"], prefix)
	_check_builtins(sv["resources"], prefix)
	var yml: Dictionary = _game_yml(str(by_path.get("game.yml", "")))
	_check_game_yml(yml, prefix, ["module", "scene"])
	# Then the client's view (both + client): its client-only scripts and scenes, and game.yml's client_scene.
	var cv := _mount(out, prefix, client_files, "client") if not client_files.is_empty() else {"scripts": [], "resources": []}
	if cv.is_empty():
		return 2
	_check_scripts(cv["scripts"], prefix)
	_check_builtins(cv["resources"], prefix)
	_check_game_yml(yml, prefix, ["client_scene"])
	print("pack_boot: %d script(s) compiled, %d failure(s)" % [scripts.size() + (cv["scripts"] as Array).size(), _bad])
	if _bad == 0 and _unjudged > 0:
		printerr("pack_boot: %d check(s) could not be judged off the tree; the pack was not judged" % _unjudged)
		return 2
	return 1 if _bad > 0 else 0


## Packs [param files] into a .pck at [param prefix] and mounts it, as dot-cloud's mounter does. Returns
## {by_path, scripts, resources}, or {} when the pack could not be written or mounted (not a verdict).
func _mount(out: String, prefix: String, files: Array, view: String) -> Dictionary:
	var pck := OS.get_temp_dir().path_join("pack_boot_%d_%s.pck" % [OS.get_process_id(), view])
	var packer := PCKPacker.new()
	if packer.pck_start(pck) != OK:
		printerr("pack_boot: cannot write %s" % pck)
		return {}
	var scripts: PackedStringArray = []
	var resources: PackedStringArray = []
	var by_path := {}
	for f: Dictionary in files:
		var sha := str(f["sha256"])
		var obj := out.path_join("objects").path_join(sha.substr(0, 2)).path_join(sha)
		if not FileAccess.file_exists(obj):
			_fail("%s: object %s is not in %s" % [f["path"], sha, out])
			continue
		var at := prefix.path_join(str(f["path"]))
		packer.add_file(at, obj)
		by_path[str(f["path"])] = obj
		# An export ships x.gd.remap + x.gdc for x.gd (dot_module_host.gd module_script_of): loaded as x.gd, once.
		var gd := _script_of(at)
		if gd != "" and not scripts.has(gd):
			scripts.append(gd)
		var res_at := _resource_of(at)
		if res_at != "" and not resources.has(res_at):
			resources.append(res_at)
	packer.flush()
	_pcks.append(pck)  # the engine reads a mounted .pck lazily: removed when the probe exits
	if not ProjectSettings.load_resource_pack(pck, false):
		printerr("pack_boot: the engine would not mount the %s view" % view)
		return {}
	print("pack_boot: mounted %d %s-view files at %s" % [by_path.size(), view, prefix])
	return {"by_path": by_path, "scripts": scripts, "resources": resources}


func _check_scripts(scripts: PackedStringArray, prefix: String) -> void:
	for path in scripts:
		var s := load(path) as GDScript
		if s == null or not s.can_instantiate():
			_fail("%s does not compile against the host's addons: %s" % [path, _first_error(path, prefix)])


func _check_builtins(resources: PackedStringArray, prefix: String) -> void:
	# A script built into a scene or resource (a .tscn's [sub_resource type="GDScript"]) is no file of its own: each
	# scene and resource the pack ships is loaded and every built-in script in it must compile too.
	# Imported assets (_imported/, .godot/: the .glb/.png outputs an import remap points at) hold no scripts and are skipped.
	# A scene that will not load here is only noted: what the server loads (game.yml's module and scenes) is judged below.
	for path in resources:
		var rel_res := path.replace(prefix + "/", "")
		if rel_res.begins_with("_imported/") or rel_res.begins_with(".godot/"):
			continue
		var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		if res == null:
			print("pack_boot: note: %s does not load off the tree; its built-in scripts were not checked" % rel_res)
			continue
		for s: GDScript in _builtin_scripts(res):
			if not s.can_instantiate():
				_fail("%s does not compile against the host's addons (a script built into %s)" % [
					s.resource_path.replace(prefix + "/", ""), path.replace(prefix + "/", "")])


func _check_game_yml(yml: Dictionary, prefix: String, keys: Array) -> void:
	for key: String in keys:
		var rel := str(DotYaml.at(yml, key, "")).strip_edges()
		if rel == "":
			continue
		var res: Resource = load(rel if rel.contains("://") else prefix.path_join(rel))
		if res == null or (res is GDScript and not (res as GDScript).can_instantiate()):
			_fail("game.yml %s (%s) does not load mounted" % [key, rel])
			continue
		print("pack_boot: game.yml %s loads: %s" % [key, rel])
		if key == "module" and res is GDScript:
			_check_module(res as GDScript, rel)


## What the host does first with a module (dot_module_host.gd _instantiate_module, then DotGameModule's
## netcode start): make one and ask it for its bridge. Neither is added to the tree; both are freed.
func _check_module(script: GDScript, rel: String) -> void:
	var module: Object = script.new()
	if module == null:
		_fail("game.yml module (%s) does not instantiate" % rel)
		return
	# The host asks for a bridge only when the game declares netcode (dot_game_module.gd: _net_config() not null, then
	# _make_bridge()); a game without netcode keeps the inherited null bridge and boots. Off the tree a game's
	# _net_config() may error (it reads `game`, unset here) and so return null: an error counts as netcode declared.
	var wants_net := false
	if module.has_method("_net_config"):
		var capture := _ScriptErrorCapture.new()
		OS.add_logger(capture)
		var config: Variant = module.call("_net_config")
		OS.remove_logger(capture)
		wants_net = config != null or capture.first_for("") != ""
	if wants_net and module.has_method("_make_bridge"):
		# The host calls _make_bridge() inside _module_load, with `game` and the server set; off the tree a bridge that
		# reads them errors at run time. That is not a verdict on the pack (exit 2), unless a script already failed to compile.
		var bcap := _ScriptErrorCapture.new()
		OS.add_logger(bcap)
		var bridge: Variant = module.call("_make_bridge")
		OS.remove_logger(bcap)
		var runtime := bcap.first_for("")
		if not (bridge is Node) and runtime != "" and _bad == 0:
			_unjudged += 1
			printerr("pack_boot: NOT JUDGED game.yml module (%s): _make_bridge() errored off the tree (%s); it needs the running game" % [rel, runtime])
		elif not (bridge is Node):
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
	var first := capture.first_for(path)
	if first != "":
		return first.replace(prefix + "/", "")
	# The logger is process-wide: an error about another file (another thread, a dependency) is not this script's own.
	var other := capture.first_for("")
	if other != "":
		return "no error of its own; the engine reported %s" % other.replace(prefix + "/", "")
	return "no error of its own (a script it uses does not compile)"


## Collects the script errors the engine reports while it is installed, each with its file. Called from any thread.
class _ScriptErrorCapture extends Logger:
	var _lock := Mutex.new()
	var _errors: PackedStringArray = []
	var _files: PackedStringArray = []

	func _log_error(
		_function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_lock.lock()
		_errors.append("%s:%d: %s" % [file, line, (code if rationale == "" else "%s %s" % [code, rationale]).strip_edges()])
		_files.append(file)
		_lock.unlock()

	## The first error reported against [param file]; with "", the first about any file.
	func first_for(file: String) -> String:
		_lock.lock()
		var e := ""
		for i in _errors.size():
			if file == "" or _files[i] == file:
				e = _errors[i]
				break
		_lock.unlock()
		return e


## The .gd path [param file] stands for: itself, or the source an exported x.gd.remap / x.gdc replaces; "" otherwise.
static func _script_of(file: String) -> String:
	if file.ends_with(".gd.remap"):
		return file.trim_suffix(".remap")
	if file.ends_with(".gdc"):
		return file.trim_suffix(".gdc") + ".gd"
	return file if file.ends_with(".gd") else ""


## The manifest inside a signed envelope ({"payload": base64url of the manifest JSON, "signatures": ...}, as
## dot_cloud_envelope.gd writes it and tools/pack_fetch.py reads it); a bare manifest as it is.
static func _unwrap(doc: Variant) -> Variant:
	if not (doc is Dictionary) or not (doc as Dictionary).has("payload"):
		return doc
	var payload: Variant = (doc as Dictionary)["payload"]
	if payload is Dictionary:
		return payload
	var b64 := str(payload).replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	return JSON.parse_string(Marshalls.base64_to_utf8(b64))


## The path a scene or resource file [param file] is loaded by (an export's x.tscn.remap stands for x.tscn); "" otherwise.
static func _resource_of(file: String) -> String:
	var f := file.trim_suffix(".remap")
	for ext in [".tscn", ".scn", ".tres", ".res"]:
		if f.ends_with(ext):
			return f
	return ""


## Every script built into [param root] (its resource_path holds "::"), found through its properties, arrays and
## dictionaries (a PackedScene keeps its sub-resources in _bundled's variants). Files of their own are checked as files.
static func _builtin_scripts(root: Resource) -> Array[GDScript]:
	var found: Array[GDScript] = []
	var seen := {}
	var todo: Array = [root]
	while not todo.is_empty():
		var v: Variant = todo.pop_back()
		if v is Dictionary:
			todo.append_array((v as Dictionary).keys())
			todo.append_array((v as Dictionary).values())
		elif v is Array:
			todo.append_array(v as Array)
		elif v is Resource:
			var r := v as Resource
			if seen.has(r.get_instance_id()):
				continue
			seen[r.get_instance_id()] = true
			if r is GDScript:
				if r.resource_path.contains("::") or r.resource_path == "":
					found.append(r as GDScript)
				continue
			if r != root and r.resource_path != "" and not r.resource_path.contains("::"):
				continue  # another file: checked as its own entry
			for p: Dictionary in r.get_property_list():
				if int(p["usage"]) & PROPERTY_USAGE_STORAGE:
					todo.append(r.get(str(p["name"])))
	return found


## game.yml parsed as the host parses it (DotYaml, as tmc_content.gd's TmcYaml): comments, quoting and nesting
## read the same. A game.yml that does not parse is one the host would refuse: a failure.
func _game_yml(path: String) -> Dictionary:
	if path == "":
		return {}
	var parsed: DotResult = DotYaml.parse(FileAccess.get_file_as_string(path), "game.yml")
	if not parsed.ok or not (parsed.value is Dictionary):
		_fail("game.yml does not parse: %s" % str(parsed.error))
		return {}
	return parsed.value as Dictionary


func _fail(text: String) -> void:
	_bad += 1
	printerr("pack_boot: FAIL %s" % text)
