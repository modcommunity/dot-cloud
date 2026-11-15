extends Node

## DotCloudAddonSet.mount_now: mounts a planned overlay in this process (a first visit), or refuses and leaves the plan.
## Run: godot --headless --path . res://examples/mount_now_selftest.tscn

const CHECKS := 17
const WORK := "user://dot_cloud_mount_now"
const LOCK := "res://addons.lock"

var _failures := 0
var _checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotPaths.remove_tree(DotCloudAddonSet.DIR)
	DotPaths.remove_tree(WORK)
	DirAccess.make_dir_recursive_absolute(WORK)
	ProjectSettings.set_setting("dot_cloud/addon_overlay", "")
	var had_lock := FileAccess.file_exists(LOCK)
	if not had_lock:
		var f := FileAccess.open(LOCK, FileAccess.WRITE)
		f.store_string("# for mount_now_selftest\n")
		f.close()
	_run()
	if not had_lock:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LOCK))
	DotPaths.remove_tree(DotCloudAddonSet.DIR)
	DotPaths.remove_tree(WORK)
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


func _pack(name: String, file: String, text: String) -> String:
	var src := "%s/%s.txt" % [WORK, name]
	var f := FileAccess.open(src, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	var path := "%s/%s.pck" % [DotCloudAddonSet.DIR, name]
	DirAccess.make_dir_recursive_absolute(DotCloudAddonSet.DIR)
	var packer := PCKPacker.new()
	packer.pck_start(ProjectSettings.globalize_path(path))
	packer.add_file(file, ProjectSettings.globalize_path(src))
	packer.flush()
	return path


func _plan(pack: String, extra: Dictionary = {}) -> void:
	var plan := {
		"state": DotCloudAddonSet.STATE_READY, "build": DotCloudAddonSet.build_fingerprint(), "pack": pack,
		"addons": {"mn_probe": {"repo": "x/mn-probe", "version": "1.0.0"}},
		"resume": {"server": "127.0.0.1:1"}, "uids": [],
	}
	plan.merge(extra, true)
	DotCloudAddonSet.write_plan(plan)


func _state() -> String:
	return str(DotCloudAddonSet.read_plan().get("state", ""))


func _run() -> void:
	_check("no plan is refused", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)

	_plan("user://dot_cloud_addons/missing.pck")
	_check("a pack that is not on disk is refused", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)
	_check("and the plan stays ready", _state() == DotCloudAddonSet.STATE_READY)

	var pack := _pack("good", "res://addons/mn_probe/mn.txt", "from the overlay")
	_plan(pack, {"build": "0000000000000000"})
	_check("an overlay made for another build is refused", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)

	_plan("user://elsewhere/x.pck")
	_check("a pack outside the overlay directory is refused", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)

	_plan(pack, {"state": DotCloudAddonSet.STATE_FAILED})
	_check("a failed plan is refused", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)
	_check("nothing was mounted by the refusals", not FileAccess.file_exists("res://addons/mn_probe/mn.txt")
			and str(ProjectSettings.get_setting("dot_cloud/addon_overlay", "")) == "")

	var garbage := "%s/garbage.pck" % DotCloudAddonSet.DIR
	var g := FileAccess.open(garbage, FileAccess.WRITE)
	g.store_string("not a pack")
	g.close()
	_plan(garbage)
	_check("a pack the engine refuses is refused", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)
	var after := DotCloudAddonSet.read_plan()
	_check("and the plan is ready again with its resume", str(after.get("state", "")) == DotCloudAddonSet.STATE_READY
			and (after.get("resume", {}) as Dictionary).get("server", "") == "127.0.0.1:1")

	_plan(pack)
	_check("a ready plan mounts and runs", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.RUNNING)
	_check("its file is readable", FileAccess.get_file_as_string("res://addons/mn_probe/mn.txt") == "from the overlay")
	_check("the plan is confirmed", _state() == DotCloudAddonSet.STATE_OK)
	_check("nothing is left to resume", (DotCloudAddonSet.read_plan().get("resume", {}) as Dictionary).is_empty())
	_check("the overlay is recorded as mounted this boot", DotCloudAddonSet.mounted_this_boot(DotCloudAddonSet.read_plan()))
	_check("the build's class list was kept", FileAccess.get_file_as_string(DotCloudAddonSet.SHELL_CLASSES_BUILD) \
			== DotCloudAddonSet.build_fingerprint() or not FileAccess.file_exists(DotCloudScriptClass.CACHE_PATH))
	_check("an ok plan is not mounted twice", DotCloudAddonSet.mount_now() == DotCloudAddonSet.MountNow.REFUSED)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("  [%s] %s%s" % ["ok" if ok else "FAIL", label, ("  " + detail) if detail != "" else ""])
