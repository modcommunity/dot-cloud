class_name DotCloudAutoUpdateConfig
extends DotConfig

## What a dedicated server does when a newer version of a pack it runs is published.
## Layers, weakest first: defaults < `autoupdate.yml` under `cfg/` < `DOT_CLOUD_AUTOUPDATE_*` < `--autoupdate-<key>=`;
## the `sv_autoupdate_*` cvars change a running server.

const CFG_ADDON := "dot-cloud"
const CFG_FILE := "autoupdate.yml"

## Master switch. On by default: a server keeps itself current unless told not to.
@export var enabled: bool = true

## Seconds between checks. The first check is one interval after start.
@export var check_interval: float = 600.0

## Restart only once nobody is connected (or [member max_wait] has passed).
@export var when_empty: bool = true

## Countdown before a restart that players will see. 0 restarts without a countdown.
@export var warn_seconds: int = 300

## Remaining seconds at which the warning is repeated, besides the first one.
@export var warn_steps: PackedStringArray = PackedStringArray(["300", "60", "10", "5"])

## With [member when_empty], restart anyway (after the countdown) once this long has passed
## since the update was found. 0 never forces: the server restarts only when empty.
@export var max_wait: int = 3600

## The warning text. `{seconds}`, `{version}` and `{content}` are filled in.
@export var message: String = "Server restarting in {seconds}s to update to {version}."

## Content ids never checked (a pack the operator has pinned on purpose).
@export var ignore: PackedStringArray = PackedStringArray()

## Exit code the process leaves with to ask its supervisor for a restart (EX_TEMPFAIL).
@export var restart_exit_code: int = 75

## Remembers which restart was asked for, so a restart that did not install it is not repeated.
@export var state_path: String = "user://dot_cloud/autoupdate_state.json"


func env_prefix() -> String:
	return "DOT_CLOUD_AUTOUPDATE_"


func cli_prefix() -> String:
	return "--autoupdate-"


func validate() -> DotResult:
	if check_interval < 10.0:
		return DotResult.fail(DotError.CODE_INVALID, "check_interval must be at least 10.")
	if warn_seconds < 0 or max_wait < 0:
		return DotResult.fail(DotError.CODE_INVALID, "warn_seconds and max_wait cannot be negative.")
	if restart_exit_code <= 0 or restart_exit_code > 255:
		return DotResult.fail(DotError.CODE_INVALID, "restart_exit_code must be 1-255.")
	return DotResult.success(null)


## The yml layers of [DotAddonConfig] ([param file_path] alone when given), then env, CLI, validation.
func load_cfg(file_path: String = "") -> DotResult:
	unknown_keys = PackedStringArray()
	var layers := PackedStringArray([file_path]) if file_path != "" \
		else DotAddonConfig.file_layers(CFG_ADDON, CFG_FILE)
	for path in layers:
		var parsed := DotYaml.parse_file(path)
		if not parsed.ok:
			return parsed.wrap("Could not read '%s'." % path)
		if parsed.value is Dictionary:
			apply_dictionary(parsed.value, path)
		elif parsed.value != null:
			return DotResult.fail(DotError.CODE_PARSE, "'%s' must hold a mapping at the top level." % path)
	apply_env()
	apply_cli()
	var valid := validate()
	if not valid.ok:
		return valid.wrap("The auto-update configuration is invalid.")
	return DotResult.success(self)


## [member warn_steps] as numbers, largest first, without zeros or duplicates.
func steps() -> PackedInt32Array:
	var out: Array[int] = []
	for s in warn_steps:
		var n := int(s.strip_edges())
		if n > 0 and not out.has(n):
			out.append(n)
	out.sort()
	out.reverse()
	return PackedInt32Array(out)


## [member message] with its placeholders filled.
func format_message(seconds: int, version: String, content: String) -> String:
	return message.replace("{seconds}", str(seconds)).replace("{version}", version) \
		.replace("{content}", content)
