## Base of [DotCloudWorkshop]: the vocabulary a sync reports in (channel, skip reasons, signals)
## and the stateless pack rules. Path-based, no class_name: the client's own surface stays on
## [DotCloudWorkshop], and this keeps each script under the size budget.
extends Node

const CHANNEL := "dot.cloud.workshop"
const SERVICE := &"dot_workshop"

## Why a pack was left out of a launch, as it appears in [code]summary.skipped[].reason[/code].
const REASON_DEVICE_OFF := "device_off"
const REASON_METERED := "metered"
const REASON_SCRIPT_POLICY := "script_policy"
const REASON_QUOTA := "quota"
const REASON_TOO_MANY := "too_many"
const REASON_INCOMPATIBLE := "incompatible"
const REASON_SUGGESTED_DECLINED := "suggested_declined"
## An addon pack (kind [code]addon[/code]) whose version the site's reviewers have not approved:
## an addon is laid over the process root, so [code]workshop_script_packs = any[/code] does not admit it.
const REASON_ADDON_UNAPPROVED := "addon_unapproved"
## An addon pack this build already ships (its repository is in [code]res://addons.lock[/code]): the
## subscription is met by the build's copy and nothing is laid over it, even when the subscribed
## release is newer (a subscription never replaces a build's addon files).
const REASON_ADDON_BUILT := "addon_built"

## [param done] of [param total] packs, and the bytes of what had to be downloaded. [param current]
## is the pack being worked on, for a loading bar.
signal progress(done: int, total: int, bytes_done: int, bytes_total: int, current: String)
signal pack_failed(content_id: String, version: String, error: DotError)
signal synced(summary: Dictionary)


## Whether [param count] already reaches [param limit]; a limit of 0 is none.
static func _over(count: int, limit: int) -> bool:
	return limit > 0 and count >= limit


static func _not_accepted_addon() -> DotError:
	return DotError.make(
		DotError.CODE_FORBIDDEN, "This pack would overlay the build's addons, and this game does not accept addon packs.",
		"a game opts in with \"addon\" in its provides.json accepts.kinds"
	)


static func _paths_of(manifest: DotCloudManifest) -> PackedStringArray:
	var out := PackedStringArray()
	for f in manifest.files:
		out.append(f.path)
	return out


## The addon directories (under [code]res://addons/[/code]) a manifest's `addon` entries name.
static func addon_dirs(manifest: DotCloudManifest) -> PackedStringArray:
	var out := PackedStringArray()
	for e: Variant in manifest.provides.get("entries", []):
		if not (e is Dictionary) or str((e as Dictionary).get("kind", "")) != "addon":
			continue
		var dir := str((e as Dictionary).get("dir", "")).trim_suffix("/").get_file()
		if dir == "" or dir == ".":
			dir = str((e as Dictionary).get("id", ""))
		if dir != "" and not out.has(dir):
			out.append(dir)
	return out


## Why [param id] may not lay its addon at [code]res://addons/<dir>[/code], or "" when it may.
## [param taken] is dir -> id of the subscribed addons already taken this sync.
static func addon_clash(dir: String, id: String, taken: Dictionary = {}) -> String:
	if taken.has(dir) and str(taken[dir]) != id:
		return "addons/%s is already taken by the subscribed %s" % [dir, taken[dir]]
	var repo := id.get_file()
	if DotCloudAddonSet.built_versions().has(repo):
		return "this build ships %s" % repo
	var plan := DotCloudAddonSet.read_plan()
	var held: Dictionary = plan.get("addons", {}) if DotCloudAddonSet.mounted_this_boot(plan) else {}
	if held.has(dir):
		var other := str((held[dir] as Dictionary).get("id", ""))
		return "" if other == id else "the running addon overlay has addons/%s from %s" % [dir, other]
	if DirAccess.dir_exists_absolute("res://addons/%s" % dir):
		return "this build has res://addons/%s" % dir
	return ""


## Whether the overlay this process booted on already holds [param id] at [param version] or newer.
static func addon_running(dir: String, id: String, version: String) -> bool:
	var plan := DotCloudAddonSet.read_plan()
	if not DotCloudAddonSet.mounted_this_boot(plan):
		return false
	var held: Variant = (plan.get("addons", {}) as Dictionary).get(dir)
	return held is Dictionary and str((held as Dictionary).get("id", "")) == id \
		and DotCloudAddonSet.compare_versions(str((held as Dictionary).get("version", "")), version) >= 0


static func _any_in(have: Array, want: Array) -> bool:
	for k in have:
		if want.has(k):
			return true
	return false


static func _skip(id: String, version: String, reason: String) -> Dictionary:
	return {"content_id": id, "version": version, "reason": reason}


func _fail_pack(failed: Array, id: String, version: String, error: DotError) -> void:
	failed.append({"content_id": id, "version": version, "code": error.code, "message": error.message})
	DotLog.warn(CHANNEL, "pack skipped", {
		"pack": "%s@%s" % [id, version], "code": error.code, "message": error.message, "detail": error.detail,
	})
	pack_failed.emit(id, version, error)


static func _new_summary() -> Dictionary:
	return {
		"guest": false, "offline": false, "from_cache": false, "revision": "", "reason": "",
		"takes_subscriptions": false, "mounted": [], "skipped": [], "failed": [], "addons": [],
	}


## The second lock behind the shell's own: a join in progress, or a session already online.
func _is_online_session() -> bool:
	if DotRegistry.get_service(&"dot_client_link") != null:
		return true
	return DotContentIndex.shared().session() == DotContentIndex.SESSION_ONLINE


## What this build is, as the site's workshop list wants it: [code]web[/code] in a browser,
## [code]mobile[/code] on a phone or tablet, otherwise [code]desktop[/code]. An old client that
## sends nothing is read as native by the site, the strict case.
static func client_platform() -> String:
	if DotPlatform.is_web():
		return "web"
	if DotPlatform.is_mobile():
		return "mobile"
	return "desktop"


## [code]workshop_script_packs[/code] as a rule: a pack that runs no code is always allowed;
## [code]any[/code] admits all code, [code]approved[/code] only what the site approved, anything else none.
static func _script_policy_allows(policy: String, runs_code: bool, approved: bool) -> bool:
	if not runs_code:
		return true
	match policy:
		"any":
			return true
		"approved":
			return approved
	return false
