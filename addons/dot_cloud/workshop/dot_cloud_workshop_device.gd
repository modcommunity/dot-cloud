class_name DotCloudWorkshopDevice
extends RefCounted

## This device's overrides of the subscription list: packs turned off here, and the metered policy.
##
## [b]They stay on the device.[/b] "Off on this phone" is not a subscription change and never
## reaches the site; anything that should follow the player to another device is a scope change
## ([method DotCloudWorkshop.set_scope]). Stored in [code]device.json[/code] beside the cached lists.

const CHANNEL := "dot.cloud.workshop"

var path: String = ""
var _off: Dictionary = {}
var _metered: String = ""


func _init(p_path: String = "") -> void:
	path = p_path


## Reads the file. A missing file is an empty override set; a corrupt one is too, with a WARN,
## because a bad device file must never stop a game from starting.
func load_file() -> DotResult:
	_off = {}
	_metered = ""
	if path == "" or not FileAccess.file_exists(path):
		return DotResult.success(self)
	var read := DotPaths.read_json(path)
	if not read.ok:
		DotLog.warn(CHANNEL, "device file unreadable, using no overrides", {"path": path, "why": str(read.error)})
		return DotResult.success(self)
	if read.value is Dictionary:
		var d: Dictionary = read.value
		var off: Variant = d.get("off", [])
		if off is Array:
			for id in off as Array:
				_off[str(id)] = true
		var m := str(d.get("metered", ""))
		if ["ask", "allow", "never"].has(m):
			_metered = m
	return DotResult.success(self)


## Writes the file atomically (and flushes the browser's filesystem, through [DotPaths]).
func save_file() -> DotResult:
	if path == "":
		return DotResult.success(null)
	var off: Array = _off.keys()
	off.sort()
	var data := {"off": off}
	if _metered != "":
		data["metered"] = _metered
	return DotPaths.write_json(path, data)


func is_off(content_id: String) -> bool:
	return _off.has(content_id)


func set_off(content_id: String, off: bool) -> void:
	if off:
		_off[content_id] = true
	else:
		_off.erase(content_id)


## The device's metered policy, or [param fallback] when it has none.
func metered_policy(fallback: String) -> String:
	return _metered if _metered != "" else fallback


func set_metered_policy(policy: String) -> DotResult:
	if policy != "" and not ["ask", "allow", "never"].has(policy):
		return DotResult.fail(DotError.CODE_INVALID, "Unknown metered policy.", policy)
	_metered = policy
	return DotResult.success(null)


func off_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _off:
		out.append(str(k))
	out.sort()
	return out
