extends Node

## [DotCloudAutoUpdate] against a fake clock, a fake origin and a fake player count.
##
## [codeblock]
## godot --headless --path . res://examples/auto_update_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_auto_update_demo"
const SECTIONS := 11
const CHECKS := 66

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0

var _t: float = 0.0
var _players: int = 0
var _latest: Dictionary = {}
var _running: Array = []
var _warnings: Array = []
var _warn_texts: Array = []
var _restarts: Array = []
var _asked: int = 0


class FakeCvar:
	extends RefCounted
	signal changed(old_value: String, new_value: String)
	var value: String

	func _init(v: String) -> void:
		value = v

	func get_string() -> String:
		return value

	func set_to(v: String) -> void:
		var old := value
		value = v
		changed.emit(old, v)


class FakeConsole:
	extends RefCounted
	var cvars: Dictionary = {}
	var preset: Dictionary = {}

	func cvar(cvar_name: String, default_value: String, _help: String) -> FakeCvar:
		cvars[cvar_name] = FakeCvar.new(str(preset.get(cvar_name, default_value)))
		return cvars[cvar_name]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	print("dot-cloud auto-update")
	DotPaths.remove_tree(WORK)

	await _section_empty_restarts_at_once()
	await _section_waits_for_empty()
	await _section_cap_forces_restart()
	await _section_cap_disabled()
	await _section_not_when_empty()
	await _section_disabled()
	await _section_loop_guard()
	await _section_cfg_layers()
	await _section_cvars()
	await _section_pointer()
	await _section_failures()

	_check(
		"every section finished",
		_sections_started == SECTIONS and _sections_finished == SECTIONS,
		"%d started, %d finished, of %d" % [_sections_started, _sections_finished, SECTIONS]
	)
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])

	print("")
	print("%d checks, %d failed" % [_checks, _failures])
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


func _section_empty_restarts_at_once() -> void:
	_begin("update found while empty")
	var u := _make({})
	_check("defaults: enabled", u.config.enabled and u.config.when_empty)
	_check("defaults: cap 3600, warn 300", u.config.max_wait == 3600 and u.config.warn_seconds == 300)
	_latest = {"gamemann/arena": "0.2.0"}
	u.step()
	_t = 599.0
	u.step()
	await get_tree().process_frame
	_check("no check before the interval", _asked == 0, str(_asked))
	_t = 600.0
	u.step()
	await get_tree().process_frame
	_check("checked at the interval", _asked >= 1, str(_asked))
	_check("update found", u.state == DotCloudAutoUpdate.State.WAITING, DotCloudAutoUpdate.State.keys()[u.state])
	_t = 601.0
	u.step()
	_check("restart requested", _restarts.size() == 1, str(_restarts))
	_check("exit code 75", not _restarts.is_empty() and int(_restarts[0][0]) == 75)
	_check("no warning", _warnings.is_empty(), str(_warnings))
	_done(u)


func _section_waits_for_empty() -> void:
	_begin("players present, when_empty waits")
	var u := _make({"max_wait": 7200})
	_latest = {"gamemann/arena": "0.2.0"}
	_players = 4
	await u.check_now()
	_check("found", u.state == DotCloudAutoUpdate.State.WAITING)
	for i in 70:
		_t += 100.0
		u.step()
	_check("still waiting with players", _restarts.is_empty() and u.state == DotCloudAutoUpdate.State.WAITING)
	_check("no warning while waiting", _warnings.is_empty(), str(_warnings))
	_players = 0
	_t += 1.0
	u.step()
	_check("restarts once empty", _restarts.size() == 1)
	_check("empty restart has no warning", _warnings.is_empty())
	_done(u)


func _section_cap_forces_restart() -> void:
	_begin("cap reached with players present")
	var u := _make({"max_wait": 1800, "warn_seconds": 300, "warn_steps": ["300", "60", "10", "5"]})
	_latest = {"gamemann/arena": "0.2.0", "gamemann/surf_map": "1.1.0"}
	_players = 3
	var found: DotResult = await u.check_now()
	_check("two updates found", found.ok and (found.value as Array).size() == 2, str(found.value))
	var start := _t
	_t = start + 1799.0
	u.step()
	_check("nothing before the cap", _warnings.is_empty() and _restarts.is_empty())
	_t = start + 1800.0
	u.step()
	_check("first warning at the cap", _seconds() == [300], str(_seconds()))
	_check("message has the version", not _warnings.is_empty() and str(_warnings[0][1]).contains("0.2.0"), str(_warnings))
	_check("message has the seconds", not _warnings.is_empty() and str(_warnings[0][1]).contains("in 300s"))
	_t = start + 1800.0 + 239.0
	u.step()
	_check("no repeat before 60 left", _seconds() == [300])
	_t = start + 1800.0 + 240.0
	u.step()
	_t = start + 1800.0 + 291.0
	u.step()
	_t = start + 1800.0 + 295.5
	u.step()
	_check("a warning at every step", _seconds() == [300, 60, 10, 5], str(_seconds()))
	_check("no restart before 0", _restarts.is_empty())
	_t = start + 1800.0 + 300.0
	u.step()
	_check("restart at 0", _restarts.size() == 1)
	u.step()
	_check("only once", _restarts.size() == 1)
	_check("warn_fn got every warning", _warn_texts.size() == 4, str(_warn_texts))
	_done(u)


func _section_cap_disabled() -> void:
	_begin("cap disabled never restarts while occupied")
	var u := _make({"max_wait": 0})
	_latest = {"gamemann/arena": "0.2.0"}
	_players = 1
	await u.check_now()
	for i in 200:
		_t += 3600.0
		u.step()
	_check("no restart in 200 hours", _restarts.is_empty())
	_check("no warning", _warnings.is_empty())
	_players = 0
	_t += 1.0
	u.step()
	_check("empty restarts at once", _restarts.size() == 1 and _warnings.is_empty())
	_done(u)


func _section_not_when_empty() -> void:
	_begin("when_empty off: countdown, players leave")
	var u := _make({"when_empty": false, "warn_seconds": 120, "warn_steps": ["300", "60", "10"]})
	_latest = {"gamemann/arena": "0.2.0"}
	_players = 2
	await u.check_now()
	u.step()
	_check("countdown starts at once", u.state == DotCloudAutoUpdate.State.COUNTDOWN)
	_check("first warning is warn_seconds", _seconds() == [120], str(_seconds()))
	_t += 61.0
	u.step()
	_check("60 step", _seconds() == [120, 60], str(_seconds()))
	_players = 0
	_t += 1.0
	u.step()
	_check("empty ends the countdown", _restarts.size() == 1)
	var z := _make({"when_empty": false, "warn_seconds": 0})
	_players = 2
	await z.check_now()
	z.step()
	_check("warn_seconds 0 restarts without warning", _restarts.size() == 1 and _warnings.is_empty())
	_done(u)
	_done(z)


func _section_disabled() -> void:
	_begin("disabled never restarts")
	var u := _make({"enabled": false})
	_latest = {"gamemann/arena": "0.2.0"}
	for i in 100:
		_t += 600.0
		u.step()
	await get_tree().process_frame
	_check("never checked", _asked == 0, str(_asked))
	_check("never restarted", _restarts.is_empty())
	var v := _make({})
	_players = 5
	await v.check_now()
	_check("pending", v.state == DotCloudAutoUpdate.State.WAITING)
	v.config.enabled = false
	v.step()
	_check("turning it off drops the update", v.state == DotCloudAutoUpdate.State.IDLE and v.updates.is_empty())
	_players = 0
	v.step()
	_check("and does not restart", _restarts.is_empty())
	_done(u)
	_done(v)


func _section_loop_guard() -> void:
	_begin("a restart that did not apply is not repeated")
	var u := _make({})
	_latest = {"gamemann/arena": "0.2.0"}
	await u.check_now()
	u.step()
	_check("first restart", _restarts.size() == 1)
	_done(u)
	var again := _make({}, true)
	await again.check_now()
	_check("same version not found again", again.state == DotCloudAutoUpdate.State.IDLE, DotCloudAutoUpdate.State.keys()[again.state])
	_latest = {"gamemann/arena": "0.3.0"}
	await again.check_now()
	_check("a newer one is", again.state == DotCloudAutoUpdate.State.WAITING)
	_done(again)
	_latest = {"gamemann/arena": "0.2.0"}
	var applied := _make({}, true, [{"id": "gamemann/arena", "version": "0.2.0"}])
	await applied.check_now()
	_check("applied clears the record", not (applied.describe()["requested"] as Dictionary).has("gamemann/arena"))
	_done(applied)
	var ignored := _make({"ignore": ["gamemann/arena"]}, false, [{"id": "gamemann/arena", "version": "0.1.0"}])
	_latest = {"gamemann/arena": "9.0.0"}
	await ignored.check_now()
	_check("ignored id never checked", _asked == 0 and ignored.state == DotCloudAutoUpdate.State.IDLE)
	_done(ignored)


func _section_cfg_layers() -> void:
	_begin("configuration layers")
	var path := WORK.path_join("autoupdate.yml")
	DotPaths.write_text(path, "when_empty: false\nwarn_seconds: 120\nmax_wait: 99\nwarn_steps: [60, 10]\nmessage: \"Back in {seconds}s ({content} {version})\"\n")
	OS.set_environment("DOT_CLOUD_AUTOUPDATE_WARN_SECONDS", "30")
	var c := DotCloudAutoUpdateConfig.new()
	var res := c.load_cfg(path)
	OS.unset_environment("DOT_CLOUD_AUTOUPDATE_WARN_SECONDS")
	_check("loads", res.ok, str(res.error) if not res.ok else "")
	_check("file over defaults", not c.when_empty and c.max_wait == 99)
	_check("env over file", c.warn_seconds == 30, str(c.warn_seconds))
	_check("default kept", c.enabled and is_equal_approx(c.check_interval, 600.0))
	_check("steps parsed", c.steps() == PackedInt32Array([60, 10]), str(c.steps()))
	_check("template", c.format_message(5, "1.0", "a/b") == "Back in 5s (a/b 1.0)", c.format_message(5, "1.0", "a/b"))
	DotPaths.write_text(path, "check_interval: 1\n")
	_check("too-short interval refused", not DotCloudAutoUpdateConfig.new().load_cfg(path).ok)
	_end()


func _section_cvars() -> void:
	_begin("cvars change a running server")
	var u := _make({})
	var console := FakeConsole.new()
	console.preset = {"sv_autoupdate_warn_seconds": "45"}
	u.bind_console(console)
	_check("all registered", console.cvars.size() == DotCloudAutoUpdate.CVARS.size(), str(console.cvars.keys()))
	_check("server.cfg value applied", u.config.warn_seconds == 45, str(u.config.warn_seconds))
	_check("defaults as text", (console.cvars["sv_autoupdate_max_wait_seconds"] as FakeCvar).value == "3600")
	(console.cvars["sv_autoupdate"] as FakeCvar).set_to("0")
	_check("sv_autoupdate 0 disables", not u.config.enabled)
	(console.cvars["sv_autoupdate_when_empty"] as FakeCvar).set_to("0")
	(console.cvars["sv_autoupdate_warn_steps"] as FakeCvar).set_to("30,5")
	_check("live changes", not u.config.when_empty and u.config.steps() == PackedInt32Array([30, 5]))
	_check("describe", u.describe().has("state") and u.describe_lines().size() > 3)
	_done(u)


func _section_pointer() -> void:
	_begin("latest.json")
	var ok := DotCloudAutoUpdate.follow_pointer("a/b", {"version": "1.2.0"}, 0)
	_check("version read", ok.ok and ok.value["version"] == "1.2.0")
	var moved := DotCloudAutoUpdate.follow_pointer("a/b", {"moved_to": "a/c"}, 0)
	_check("moved read", moved.ok and moved.value["moved_to"] == "a/c")
	_check("second hop refused", not DotCloudAutoUpdate.follow_pointer("a/c", {"moved_to": "a/d"}, 1).ok)
	_check("traversal refused", not DotCloudAutoUpdate.follow_pointer("a/b", {"version": "../x"}, 0).ok)
	_check("not an object refused", not DotCloudAutoUpdate.follow_pointer("a/b", [], 0).ok)
	var u := _make({})
	u.latest_fn = Callable()
	var none: DotResult = await u.latest_from_origin("a/b")
	_check("no client: nothing to ask", none.ok and (none.value as Dictionary).is_empty())
	_done(u)


func _section_failures() -> void:
	_begin("a failing origin")
	var u := _make({})
	u.latest_fn = func(_id: String) -> DotResult: return DotResult.fail(DotError.CODE_NETWORK, "down")
	await u.check_now()
	_check("no update on failure", u.state == DotCloudAutoUpdate.State.IDLE)
	_check("failure counted", int(u.last_check.get("errors", 0)) == 2, str(u.last_check))
	u.latest_fn = func(_id: String) -> DotResult: return DotResult.success({"id": "gamemann/arena2", "version": "0.1.0"})
	await u.check_now()
	_check("moved id is an update", u.state == DotCloudAutoUpdate.State.WAITING and str(u.updates[0]["to"]) == "gamemann/arena2@0.1.0", str(u.updates))
	_done(u)


func _make(overrides: Dictionary, keep_state: bool = false, running: Array = []) -> DotCloudAutoUpdate:
	_t = 0.0
	_players = 0
	_asked = 0
	_warnings = []
	_warn_texts = []
	_restarts = []
	_running = running if not running.is_empty() else [
		{"id": "gamemann/arena", "version": "0.1.0"},
		{"id": "gamemann/surf_map", "version": "1.0.0"},
		{"id": "gamemann/arena", "version": "0.1.0"},
	]
	if not keep_state:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(WORK.path_join("state.json")))
	var u := DotCloudAutoUpdate.new()
	u.config = DotCloudAutoUpdateConfig.new()
	u.config.state_path = WORK.path_join("state.json")
	u.config.apply_dictionary(overrides, "test")
	u.drive_by_process = false
	u.now_fn = func() -> float: return _t
	u.players_fn = func() -> int: return _players
	u.watch_fn = func() -> Array: return _running
	u.latest_fn = func(id: String) -> DotResult:
		_asked += 1
		return DotResult.success({"id": id, "version": str(_latest.get(id, _version_of(id)))})
	u.warn_fn = func(text: String) -> void: _warn_texts.append(text)
	u.warning_sent.connect(func(s: int, text: String) -> void: _warnings.append([s, text]))
	u.restart_fn = func(code: int, reason: String) -> void: _restarts.append([code, reason])
	add_child(u)
	return u


func _version_of(id: String) -> String:
	for w: Dictionary in _running:
		if w["id"] == id:
			return w["version"]
	return ""


func _seconds() -> Array:
	return _warnings.map(func(w: Array) -> int: return int(w[0]))


func _done(u: DotCloudAutoUpdate) -> void:
	if is_instance_valid(u) and u.is_inside_tree():
		remove_child(u)  # unregisters now, before the next section registers its own
		u.queue_free()
	if _sections_started > _sections_finished:
		_end()


func _begin(section: String) -> void:
	_sections_started += 1
	print("")
	print("[%s]" % section)


func _end() -> void:
	_sections_finished += 1


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("  %s %s%s" % [label.rpad(40), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])
