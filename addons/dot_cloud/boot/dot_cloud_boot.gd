extends Node

## A main scene that mounts the addon overlay before anything else loads, then hands over.
##
## [b]This file may name NOTHING from any addon -- not even dot-cloud's own classes.[/b]
## Measured on an exported build: once a script is compiled, a newer copy mounted over it is
## never read, in this process. So the overlay [DotCloudAddonSet] prepares has to be mounted
## before the first addon script is touched, and the only code that can run before that is
## code that touches none. Everything below is the engine's API; the paths and the plan's
## field names are written out again rather than read from `DotCloudAddonSet`, on purpose.
## Keep the two in step.
##
## [b]Use:[/b] make a scene whose root is a Node with this script, set [member next_scene]
## to what the main scene used to be, and make it the main scene. With no plan on disk it
## changes scene on the first frame and costs nothing.
##
## [b]A boot that never arrives is not repeated forever.[/b] The plan says `booting` before
## the mount and the shell says `ok` once it has built itself
## ([method DotCloudAddonSet.confirm_boot]). Finding `booting` means the last start died
## between the two -- a broken addon, or a tab closed mid-load. One retry covers the second;
## after that the overlay is marked failed and the build comes up on its own addons.

## The scene this one stands in front of.
@export_file("*.tscn") var next_scene: String = ""

const DIR := "user://dot_cloud_addons"
const PLAN := "user://dot_cloud_addons/plan.json"
const SHELL_CLASSES := "user://dot_cloud_addons/shell_classes.cfg"
const SHELL_CLASSES_BUILD := "user://dot_cloud_addons/shell_classes.build"
const BUILT_LOCK := "res://addons.lock"
const CLASS_CACHE := "res://.godot/global_script_class_cache.cfg"
const SETTING := "dot_cloud/addon_overlay"

## Unconfirmed boots tolerated before the overlay is given up on.
const MAX_ATTEMPTS := 2


func _ready() -> void:
	_apply()

	if next_scene != "":
		get_tree().change_scene_to_file.call_deferred(next_scene)


func _apply() -> void:
	var text := FileAccess.get_file_as_string(PLAN)

	if text == "":
		return

	var parsed: Variant = JSON.parse_string(text)

	if not (parsed is Dictionary):
		_say("the addon plan is unreadable; starting without it")
		return

	var plan := parsed as Dictionary
	var lock := FileAccess.get_file_as_string(BUILT_LOCK)
	var build := lock.sha256_text().substr(0, 16) if lock != "" else ""

	# Laid over the build it was assembled against, or not at all: over a NEWER build the
	# overlay could take an addon backwards.
	if build == "" or str(plan.get("build", "")) != build:
		_say("the addon overlay was made for another build; starting without it")
		return

	var state := str(plan.get("state", ""))

	if state == "booting":
		var attempts := int(plan.get("attempts", 0)) + 1
		plan["attempts"] = attempts

		if attempts >= MAX_ATTEMPTS:
			plan["state"] = "failed"
			_save(plan)
			_say("the last %d starts on the addon overlay never finished; starting without it" % attempts)
			return
	elif state == "ready" or state == "ok":
		plan["attempts"] = 0
	else:
		return

	var pack := str(plan.get("pack", ""))

	if not pack.begins_with(DIR + "/") or not FileAccess.file_exists(pack):
		return

	_keep_shell_classes(build)

	plan["state"] = "booting"
	_save(plan)

	if not ProjectSettings.load_resource_pack(pack, true):
		plan["state"] = "failed"
		_save(plan)
		_say("the engine refused the addon overlay; starting without it")
		return

	ProjectSettings.set_setting(SETTING, pack)

	var uids: Variant = plan.get("uids", [])
	var registered := 0

	if uids is Array:
		for pair in uids:
			if pair is Array and (pair as Array).size() == 2 and _register_uid(str(pair[0]), str(pair[1])):
				registered += 1

	_say("mounted the addon overlay %s (%d addons, %d uids)" % [
		pack.get_file(), (plan.get("addons", {}) as Dictionary).size(), registered
	])


## The build's own class list, kept before the overlay replaces it -- the next overlay is
## merged from it, never from an earlier overlay's. Once per build.
func _keep_shell_classes(build: String) -> void:
	if FileAccess.get_file_as_string(SHELL_CLASSES_BUILD) == build:
		return

	var list := FileAccess.get_file_as_string(CLASS_CACHE)

	if list == "":
		return

	DirAccess.make_dir_recursive_absolute(DIR)
	_write(SHELL_CLASSES, list)
	_write(SHELL_CLASSES_BUILD, build)


## Points a uid the overlay declares at its file. Only inside `res://addons/`: an overlay
## re-pointing a uid the shell's own scenes use would be an addon reaching outside itself.
func _register_uid(text: String, path: String) -> bool:
	if not path.begins_with("res://addons/") or path.contains(".."):
		return false

	var id := ResourceUID.text_to_id(text)

	if id == ResourceUID.INVALID_ID:
		return false

	if ResourceUID.has_id(id):
		if not ResourceUID.get_id_path(id).begins_with("res://addons/"):
			return false

		ResourceUID.set_id(id, path)
	else:
		ResourceUID.add_id(id, path)

	return true


func _save(plan: Dictionary) -> void:
	_write(PLAN, JSON.stringify(plan, "\t"))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)

	if f == null:
		return

	f.store_string(text)
	f.close()

	# A browser's user:// is a mirror of IndexedDB and is only persisted when asked; a
	# reload before that loses the write. Through the singleton by name, because the
	# identifier does not exist outside a web export.
	if Engine.has_singleton("JavaScriptBridge"):
		Engine.get_singleton("JavaScriptBridge").call("force_fs_sync")


func _say(text: String) -> void:
	print("[dot_cloud boot] ", text)
