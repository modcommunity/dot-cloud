class_name DotCloudAutoUpdate
extends Node

## Keeps a dedicated server on the newest published version of the packs it runs (docs/auto-update.md).
## A mounted pack never unmounts, so an update is a clean exit with [member DotCloudAutoUpdateConfig.restart_exit_code]
## for the supervisor to restart; everything host-specific is injected.

const CHANNEL := "cloud.autoupdate"
const SERVICE := &"dot_cloud_autoupdate"
const LATEST_FILE := "latest.json"

enum State { IDLE, WAITING, COUNTDOWN, RESTARTING, OFF }

signal update_found(updates: Array)
signal warning_sent(seconds: int, text: String)
signal restart_requested(exit_code: int, reason: String)

## Settings; [method _ready] loads the layered config when none was assigned.
var config: DotCloudAutoUpdateConfig = null

## `func() -> Array` of `{id, version}`: the packs this process runs.
var watch_fn: Callable = Callable()

## `func(id: String) -> DotResult` with `{id, version}` of the newest signed version, or `{}`
## for "nothing to ask". May be a coroutine. Default: `latest.json` plus a verified manifest.
var latest_fn: Callable = Callable()

## `func() -> int`: connected players. Unset counts as empty.
var players_fn: Callable = Callable()

## `func(text: String) -> void`: shows the warning to players (chat, console).
var warn_fn: Callable = Callable()

## `func(exit_code: int, reason: String) -> void`. Default: quit with the exit code.
var restart_fn: Callable = Callable()

## `func() -> float`, seconds. Default: the monotonic clock.
var now_fn: Callable = Callable()

## Off for a test that drives [method step] itself.
var drive_by_process: bool = true

var state: State = State.IDLE
var updates: Array = []
var _next_check: float = -1.0
var _checking: bool = false
var _found_at: float = 0.0
var _countdown_end: float = 0.0
var _sent_steps: Dictionary = {}
var _told_waiting: bool = false
var _fail_streak: int = 0
var _requested: Dictionary = {}
var _skipped: Dictionary = {}
var _http: DotHttp = null
var _cvars: Array = []
var last_check: Dictionary = {}


## Whether this process may update itself at all: a browser tab is only ever a client.
static func supported() -> bool:
	return not DotPlatform.is_web() and DotPlatform.can_listen()


func _ready() -> void:
	if config == null:
		config = DotCloudAutoUpdateConfig.new()
		var loaded := config.load_cfg()
		if not loaded.ok:
			DotLog.warn(CHANNEL, "auto-update configuration refused; using the defaults", {"why": str(loaded.error)})
			config = DotCloudAutoUpdateConfig.new()
	if not supported():
		state = State.OFF
		set_process(false)
		return
	DotRegistry.register(SERVICE, self)
	_load_state()
	set_process(drive_by_process)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


func _process(_delta: float) -> void:
	# A Callable, so the frame-hazard scan does not charge the rare check and restart paths to every frame.
	step.call()


func now() -> float:
	return float(now_fn.call()) if now_fn.is_valid() else Time.get_ticks_msec() / 1000.0


## One pass of the state machine; [method _process] calls it every frame.
func step() -> void:
	if state == State.RESTARTING or state == State.OFF:
		return
	var t := now()
	if not config.enabled:
		if state != State.IDLE:
			DotLog.info(CHANNEL, "auto-update turned off; the pending update is dropped", _update_fields())
			_reset()
		_next_check = -1.0
		return
	if _next_check < 0.0:
		_next_check = t + config.check_interval
	if state == State.IDLE:
		if not _checking and t >= _next_check:
			_next_check = t + config.check_interval
			check_now()
		return

	if _players() <= 0:
		request_restart("the server is empty")
		return
	if state == State.WAITING:
		var forced := config.max_wait > 0 and t - _found_at >= config.max_wait
		if config.when_empty and not forced:
			if not _told_waiting:
				_told_waiting = true
				DotLog.info(CHANNEL, "update waits for the server to empty", _update_fields().merged({
					"players": _players(), "max_wait": config.max_wait,
				}))
			return
		_start_countdown(t)
		return
	if state == State.COUNTDOWN:
		var left := _countdown_end - t
		if left <= 0.0:
			request_restart("the warning countdown ended")
			return
		var due := -1
		for s in config.steps():
			if float(s) >= left and not _sent_steps.has(s):
				_sent_steps[s] = true
				due = s
		if due > 0:
			_warn(due)


## Asks every watched pack's origin for its newest version now. Value: the updates found.
func check_now() -> DotResult:
	if _checking:
		return DotResult.fail(DotError.CODE_STATE, "A check is already running.")
	_checking = true
	var res: DotResult = await _check()
	_checking = false
	return res


func _check() -> DotResult:
	var found: Array = []
	var errors := PackedStringArray()
	var asked := 0
	for w: Dictionary in watched():
		var id := str(w["id"])
		var running := str(w["version"])
		var got: Variant = null
		if latest_fn.is_valid():
			got = await latest_fn.call(id)
		else:
			got = await latest_from_origin(id)
		if not (got is DotResult):
			errors.append("%s: the latest_fn returned no DotResult" % id)
			continue
		var res := got as DotResult
		if not res.ok:
			# S3 answers 403, not 404, for a key that does not exist: an id nothing published
			# (a shipped descriptor for a game this server does not run) is not a failed check.
			if res.error.code == DotError.CODE_FORBIDDEN:
				DotLog.debug(CHANNEL, "no published pack to check", {"content": id})
				continue
			errors.append("%s: %s" % [id, str(res.error)])
			continue
		var latest := res.value as Dictionary
		if latest == null or latest.is_empty():
			continue
		asked += 1
		var to := str(latest["version"])
		var to_id := str(latest.get("id", id))
		if to_id == id and to == running:
			if _requested.has(id):
				DotLog.info(CHANNEL, "running the updated version", {"content": id, "version": running})
				_requested.erase(id)
				_save_state()
			continue
		var target := to if to_id == id else "%s@%s" % [to_id, to]
		if str(_requested.get(id, "")) == target:
			if not _skipped.has(id + "@" + target):
				_skipped[id + "@" + target] = true
				DotLog.warn(CHANNEL, "a restart did not install this update; not restarting for it again", {
					"content": id, "running": running, "latest": target,
					"hint": "the version is pinned, or the install at start failed (see its log)",
				})
			continue
		found.append({"id": id, "from": running, "to": target})

	last_check = {"at": now(), "asked": asked, "found": found.size(), "errors": errors.size()}
	if not errors.is_empty():
		var fields := {"failed": errors.size(), "first": errors[0]}
		if _fail_streak == 0:
			DotLog.warn(CHANNEL, "could not check for a newer pack", fields)
		else:
			DotLog.debug(CHANNEL, "could not check for a newer pack", fields)
		_fail_streak += 1
	else:
		_fail_streak = 0

	if found.is_empty() or state != State.IDLE or not config.enabled:
		return DotResult.success(found)
	updates = found
	_found_at = now()
	state = State.WAITING
	DotLog.info(CHANNEL, "update found", _update_fields())
	update_found.emit(found)
	return DotResult.success(found)


## The packs to check, once each, minus [member DotCloudAutoUpdateConfig.ignore].
func watched() -> Array:
	var out: Array = []
	var seen := {}
	var listed: Variant = watch_fn.call() if watch_fn.is_valid() else []
	if not (listed is Array):
		return out
	for w: Variant in listed:
		if not (w is Dictionary):
			continue
		var id := str((w as Dictionary).get("id", ""))
		var version := str((w as Dictionary).get("version", ""))
		if id == "" or version == "" or seen.has(id) or config.ignore.has(id):
			continue
		seen[id] = true
		out.append({"id": id, "version": version})
	return out


## Starts the restart now. The supervisor's restart installs the new version.
func request_restart(reason: String) -> void:
	if state == State.RESTARTING:
		return
	state = State.RESTARTING
	for u: Dictionary in updates:
		_requested[str(u["id"])] = str(u["to"])
	_save_state()
	var code := config.restart_exit_code
	DotLog.info(CHANNEL, "restarting to apply an update", _update_fields().merged({
		"reason": reason, "exit_code": code,
	}))
	restart_requested.emit(code, reason)
	if restart_fn.is_valid():
		restart_fn.call(code, reason)
	elif is_inside_tree():
		get_tree().quit(code)


func _start_countdown(t: float) -> void:
	if config.warn_seconds <= 0:
		request_restart("an update with players present and no warning configured")
		return
	state = State.COUNTDOWN
	_countdown_end = t + config.warn_seconds
	for s in config.steps():
		if s >= config.warn_seconds:
			_sent_steps[s] = true
	_warn(config.warn_seconds)


func _warn(seconds: int) -> void:
	var first: Dictionary = updates[0] if not updates.is_empty() else {"id": "", "to": ""}
	var content := str(first["id"]) if updates.size() < 2 else "%s and %d more" % [first["id"], updates.size() - 1]
	var text := config.format_message(seconds, str(first["to"]), content)
	DotLog.info(CHANNEL, "restart warning sent", {"seconds": seconds, "text": text})
	warning_sent.emit(seconds, text)
	if warn_fn.is_valid():
		warn_fn.call(text)


func _players() -> int:
	return int(players_fn.call()) if players_fn.is_valid() else 0


func _reset() -> void:
	state = State.IDLE
	updates = []
	_sent_steps = {}
	_told_waiting = false


func _update_fields() -> Dictionary:
	var parts := PackedStringArray()
	for u: Dictionary in updates:
		parts.append("%s %s -> %s" % [u["id"], u["from"], u["to"]])
	return {"updates": ", ".join(parts)}


## Default [member latest_fn]: `<base>/<id>/latest.json` from the registered [DotCloudClient]'s
## HTTP bases, then that version's manifest fetched and verified the way a client's is.
func latest_from_origin(id: String) -> DotResult:
	var client := DotRegistry.get_node_service(DotCloudClient.SERVICE) as DotCloudClient
	if client == null:
		return DotResult.success({})
	var bases := client.resolved_http_base_urls()
	if bases.is_empty():
		return DotResult.success({})
	if _http == null:
		_http = DotHttp.new()
		_http.name = "LatestHttp"
		add_child(_http)

	var pointer := await _read_pointer(id, bases, 0)
	if pointer.ok and str(pointer.value["moved_to"]) != "":
		var moved := str(pointer.value["moved_to"])
		pointer = await _read_pointer(moved, bases, 1)
		if pointer.ok:
			pointer.value["id"] = moved
	if not pointer.ok:
		return pointer
	var to_id := str(pointer.value.get("id", id))
	var version := str(pointer.value["version"])

	var manifest := await client.resolve_manifest(StringName(to_id), version)
	if not manifest.ok:
		return manifest.wrap("%s@%s is published but its manifest did not verify:" % [to_id, version])
	if (manifest.value as DotCloudManifest).signature == "":
		return DotResult.fail(DotError.CODE_FORBIDDEN, "%s@%s is not signed; it is not installed automatically." % [to_id, version])
	return DotResult.success({"id": to_id, "version": version})


func _read_pointer(id: String, bases: PackedStringArray, hop: int) -> DotResult:
	var last: DotResult = null
	for base in bases:
		var got: DotResult = await _http.get_json("%s/%s/%s" % [base.rstrip("/"), id, LATEST_FILE])
		if not got.ok:
			last = got
			continue
		return follow_pointer(id, got.value, hop)
	return last if last != null else DotResult.fail(DotError.CODE_IO, "No base to ask for %s." % id)


## Reads one `latest.json` body: `{version, moved_to}`. `moved_to` is followed one hop only.
static func follow_pointer(id: String, body: Variant, hop: int) -> DotResult:
	if not (body is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "%s for %s is not an object." % [LATEST_FILE, id])
	var moved := str((body as Dictionary).get("moved_to", "")).strip_edges()
	if moved != "":
		if moved == id or hop >= 1 or not moved.contains("/") or moved.contains(".."):
			return DotResult.fail(DotError.CODE_INVALID, "%s for %s names an unusable moved_to: %s" % [LATEST_FILE, id, moved])
		return DotResult.success({"version": "", "moved_to": moved})
	var version := str((body as Dictionary).get("version", "")).strip_edges()
	if version == "" or version.contains("/") or version.contains(".."):
		return DotResult.fail(DotError.CODE_PARSE, "%s for %s names no usable version." % [LATEST_FILE, id])
	return DotResult.success({"version": version, "moved_to": ""})


## The cvars, as `name: [config key, help]`.
const CVARS := {
	"sv_autoupdate": ["enabled", "Restart to install a newer published version of this server's packs (0/1)."],
	"sv_autoupdate_when_empty": ["when_empty", "Restart for an update only when nobody is connected (0/1)."],
	"sv_autoupdate_warn_seconds": ["warn_seconds", "Countdown players are warned with before an update restart."],
	"sv_autoupdate_warn_steps": ["warn_steps", "Seconds left at which the warning repeats, comma-separated."],
	"sv_autoupdate_max_wait_seconds": ["max_wait", "With when_empty, restart anyway after this long (0 = never)."],
	"sv_autoupdate_check_interval": ["check_interval", "Seconds between update checks."],
	"sv_autoupdate_message": ["message", "Warning text; {seconds}, {version} and {content} are filled in."],
}


## Registers the `sv_autoupdate_*` cvars on a console with `cvar(name, default, help)`
## (dot-server's [code]DotConsole[/code]); each change applies to [member config] at once.
func bind_console(console: Object) -> void:
	if console == null or not console.has_method("cvar"):
		return
	for cvar_name: String in CVARS:
		var key: String = CVARS[cvar_name][0]
		var c: Object = console.call("cvar", cvar_name, _cvar_text(key), CVARS[cvar_name][1])
		if c == null:
			continue
		_cvars.append(c)
		if c.has_method("get_string") and str(c.call("get_string")) != _cvar_text(key):
			config.apply_dictionary({key: str(c.call("get_string"))}, "cvar")
		if c.has_signal("changed"):
			c.connect("changed", func(_old: String, new_value: String) -> void:
				config.apply_dictionary({key: new_value}, "cvar"))


func _cvar_text(key: String) -> String:
	var v: Variant = config.get(key)
	if v is bool:
		return "1" if v else "0"
	if v is PackedStringArray:
		return ",".join(v)
	if v is float and is_equal_approx(v, roundf(v)):
		return str(int(v))
	return str(v)


func _load_state() -> void:
	if config.state_path == "" or not FileAccess.file_exists(config.state_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config.state_path))
	if parsed is Dictionary and (parsed as Dictionary).get("requested") is Dictionary:
		_requested = (parsed as Dictionary)["requested"]


func _save_state() -> void:
	if config.state_path == "":
		return
	DirAccess.make_dir_recursive_absolute(config.state_path.get_base_dir())
	var f := FileAccess.open(config.state_path, FileAccess.WRITE)
	if f == null:
		DotLog.warn(CHANNEL, "could not record the requested update", {"path": config.state_path})
		return
	f.store_string(JSON.stringify({"requested": _requested}))
	f.close()
	DotWeb.sync_filesystem()


func describe() -> Dictionary:
	return {
		"state": State.keys()[state],
		"enabled": config.enabled if config != null else false,
		"when_empty": config.when_empty if config != null else false,
		"warn_seconds": config.warn_seconds if config != null else 0,
		"max_wait": config.max_wait if config != null else 0,
		"check_interval": config.check_interval if config != null else 0.0,
		"watched": watched().size() if config != null else 0,
		"updates": _update_fields()["updates"],
		"next_check_in": maxf(0.0, _next_check - now()) if _next_check >= 0.0 else -1.0,
		"last_check": last_check,
		"requested": _requested,
	}


func describe_lines() -> PackedStringArray:
	var d := describe()
	var out := PackedStringArray()
	for k: String in d:
		out.append("%s: %s" % [k, str(d[k])])
	return out
