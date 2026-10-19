class_name DotCloudWorkshop
extends Node

## The Workshop's sync client: a signed-in player's subscribed packs, downloaded, verified and
## mounted for a solo session. The contract is [code]docs/workshop.md[/code]; this file is the
## client half of it.
##
## [codeblock]
## var ws := DotCloudWorkshop.new()
## ws.token_fn = func() -> String: return my_auth.bearer()     # "" for a guest
## ws.ask_fn = func(summary: Dictionary) -> bool: return await my_dialog.ask(summary)
## ws.config.workshop_backbone_url = "https://tmcdev.net"
## add_child(ws)                                              # beside the DotCloudClient
## var res := await ws.sync("gamemann/game-playground")
## [/codeblock]
##
## [b]It never runs for an online session[/b], and says so with [constant DotError.CODE_FORBIDDEN]
## rather than trusting its caller. It never fails for anything a player can cause: a dead
## network, a broken pack, a guest and a declined download are all a successful summary, because
## one pack must never stop a game from starting. No dot-auth dependency: the bearer arrives as a
## [Callable].

const CHANNEL := "dot.cloud.workshop"
const SERVICE := &"dot_workshop"

## Why a pack was left out of a launch, as it appears in [code]summary.skipped[].reason[/code].
const REASON_DEVICE_OFF := "device_off"
const REASON_METERED := "metered"
const REASON_SCRIPT_POLICY := "script_policy"
const REASON_QUOTA := "quota"
const REASON_TOO_MANY := "too_many"
const REASON_INCOMPATIBLE := "incompatible"

## [param done] of [param total] packs, and the bytes of what had to be downloaded. [param current]
## is the pack being worked on, for a loading bar.
signal progress(done: int, total: int, bytes_done: int, bytes_total: int, current: String)
signal pack_failed(content_id: String, version: String, error: DotError)
signal synced(summary: Dictionary)

@export var register_service: bool = true

## Layered configuration; [code]null[/code] makes a default one.
@export var config: DotCloudWorkshopConfig = null

## Read on the first sync when it exists. The layers above it are the exported defaults.
@export var config_file: String = "user://dot_cloud_workshop.json"

## Where the cached lists and [code]device.json[/code] live.
@export var cache_dir: String = "user://dot_cloud/workshop"

## The signed-in player's bearer token, [code]""[/code] for a guest. Set by the host.
var token_fn: Callable = Callable()

## Awaitable [code](summary: Dictionary) -> bool[/code]: "Download 120 MB of subscribed content?".
## Unset means no.
var ask_fn: Callable = Callable()

## The dot-cloud client to mount through; found through [constant DotCloudClient.SERVICE] when null.
var cloud: DotCloudClient = null

## The signed-in account's id when the host knows it, so a cached list that belongs to another
## account is not used offline. Empty trusts the cache (a list is only ever written for the
## account whose token fetched it).
var account_id: String = ""

## -1 asks the platform, 0 and 1 force the answer (tests, and a host that knows better).
var force_metered: int = -1

## The platform sent with the list request, [code]web[/code], [code]desktop[/code] or
## [code]mobile[/code]; empty asks [method client_platform]. The site holds its code-review
## policy per platform (a browser's sandbox apart from a native build's whole machine), so this
## decides which script packs it lists, and the [code]approved[/code] it reports is approval
## for that platform. Forcing it is for tests and for a host that knows better, and only ever
## toward the stricter side: [code]web[/code] is refused unless this build is a browser one
## (logged once, and [method client_platform] is sent instead), because a pack cleared for the
## browser's sandbox may still call [code]OS.execute[/code], which only a native build can run.
## [code]desktop[/code] and [code]mobile[/code] are both native and always accepted; anything
## else is refused the same way.
var force_platform: String = ""

var device: DotCloudWorkshopDevice = null

var _http: DotHttp = null
var _prepared: bool = false
var _platform_refusal_logged: bool = false
var _syncing: bool = false
var _game_id: String = ""
var _list: DotCloudWorkshopList = null
var _summary: Dictionary = {}
var _ran_code: bool = false


func _ready() -> void:
	if Engine.is_editor_hint() or not register_service:
		return
	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


## The last list this node saw (fetched or cached), or null before the first sync.
func last_list() -> DotCloudWorkshopList:
	return _list


## True when a pack that runs code was mounted in this process: an online join then restarts the
## process first, because the pack's scripts stay resident (docs/workshop.md, online isolation).
func requires_restart_before_online() -> bool:
	return _ran_code


## Metered when the browser reports Save-Data or a cellular connection, or on a phone with nothing
## saying otherwise. One method on purpose: a platform that later exposes a real answer replaces it.
func is_metered() -> bool:
	if force_metered >= 0:
		return force_metered == 1
	if DotWeb.available():
		var v: Variant = DotWeb.eval(
			"(function(){var c=navigator.connection;"
			+ "return (c && (c.saveData===true || c.type==='cellular')) ? 1 : 0;})()"
		)
		return int(v) == 1 if v != null else false
	return DotPlatform.is_mobile()


## Fetches the game's list and mounts every pack that survives the device's rules, for the solo
## session. The value is the summary:
## [code]{guest, offline, from_cache, revision, mounted, skipped, failed}[/code] plus [code]reason[/code]
## ("guest", "disabled", "offline_no_cache" or "") and [code]takes_subscriptions[/code].
func sync(game_content_id: String) -> DotResult:
	if game_content_id.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "No game content id to sync the Workshop for.")
	if _syncing:
		return DotResult.fail(DotError.CODE_STATE, "A Workshop sync is already running.")
	if _is_online_session():
		DotLog.warn(CHANNEL, "refused: an online session never mounts subscriptions", {"game": game_content_id})
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The Workshop is not available in an online session.", game_content_id
		)
	var cloud_client := _cloud()
	if cloud_client == null:
		return DotResult.fail(
			DotError.CODE_STATE, "No DotCloudClient to mount through.",
			"place a DotCloudClient beside the Workshop, or set .cloud"
		)
	var prepared := _prepare()
	if not prepared.ok:
		return prepared

	_syncing = true
	_game_id = game_content_id
	var summary := _new_summary()
	_summary = summary
	var res := await _run(game_content_id, cloud_client, summary)
	_syncing = false
	if not res.ok:
		return res
	DotLog.info(CHANNEL, "synced", {
		"game": game_content_id, "revision": summary["revision"], "mounted": (summary["mounted"] as Array).size(),
		"skipped": (summary["skipped"] as Array).size(), "failed": (summary["failed"] as Array).size(),
		"offline": summary["offline"], "guest": summary["guest"],
	})
	synced.emit(summary)
	return DotResult.success(summary)


## Turns a subscription on or off for [b]this game[/b] on the site. Applies at the next launch,
## because a mounted pack cannot be taken back. Needs a prior [method sync] to know the game.
func set_scope(subscription_id: String, on: bool) -> DotResult:
	if _game_id == "":
		return DotResult.fail(DotError.CODE_STATE, "No game yet: sync before changing a scope.")
	return await _post_scope({"subscriptionId": subscription_id, "game": _game_id, "on": on})


## Turns a subscription on or off for [b]every game[/b]. A game-bound token is refused by the site
## ([constant DotError.CODE_FORBIDDEN]); the panel then offers the asset page instead.
func set_all_games(subscription_id: String, on: bool) -> DotResult:
	return await _post_scope({"subscriptionId": subscription_id, "all": on})


## This device's switch for one pack; never reaches the site. Applies at the next launch.
func set_device_off(content_id: String, off: bool) -> DotResult:
	var prepared := _prepare()
	if not prepared.ok:
		return prepared
	device.set_off(content_id, off)
	return device.save_file()


func describe() -> Dictionary:
	var d := {
		"enabled": config.workshop_enabled if config != null else true,
		"game": _game_id,
		"syncing": _syncing,
		"revision": _list.revision() if _list != null else "",
		"items": _list.items().size() if _list != null else 0,
		"device_off": device.off_ids() if device != null else PackedStringArray(),
		"ran_code": _ran_code,
	}
	if not _summary.is_empty():
		d["last"] = {
			"guest": _summary["guest"], "offline": _summary["offline"], "from_cache": _summary["from_cache"],
			"mounted": (_summary["mounted"] as Array).size(), "skipped": (_summary["skipped"] as Array).size(),
			"failed": (_summary["failed"] as Array).size(), "reason": _summary["reason"],
		}
	return d


func describe_lines() -> PackedStringArray:
	var d := describe()
	var lines := PackedStringArray()
	lines.append("workshop: %s game=%s revision=%s items=%d" % [
		"on" if d["enabled"] else "off", d["game"], d["revision"], d["items"]
	])
	if not (d["device_off"] as PackedStringArray).is_empty():
		lines.append("  off on this device: %s" % ", ".join(d["device_off"]))
	if d.has("last"):
		var l: Dictionary = d["last"]
		lines.append("  last sync: mounted=%d skipped=%d failed=%d guest=%s offline=%s cache=%s %s" % [
			l["mounted"], l["skipped"], l["failed"], l["guest"], l["offline"], l["from_cache"], l["reason"]
		])
	if d["ran_code"]:
		lines.append("  a pack that runs code is mounted: an online join must restart first")
	return lines


# --- the sync ---------------------------------------------------------------


func _run(game: String, cloud_client: DotCloudClient, summary: Dictionary) -> DotResult:
	if not config.workshop_enabled:
		summary["reason"] = "disabled"
		return DotResult.success(null)

	var token := _token()
	if token == "":
		summary["guest"] = true
		summary["reason"] = "guest"
		_list = null
		return DotResult.success(null)

	var cached := _read_cache(game)
	var list: DotCloudWorkshopList = null
	if not cached.is_empty() and _cache_is_this_account(cached):
		list = DotCloudWorkshopList.from_response(cached["response"] as Dictionary)
	var since: String = str(cached.get("revision", "")) if list != null else ""

	var fetched := await _fetch(game, token, since)
	if fetched.ok:
		var response: Dictionary = fetched.value
		if bool(response.get("unchanged", false)) and list != null:
			summary["from_cache"] = true
		elif bool(response.get("unchanged", false)):
			# A delta against a cache we no longer trust: ask for the whole list.
			fetched = await _fetch(game, token, "")
		if fetched.ok and not bool((fetched.value as Dictionary).get("unchanged", false)):
			list = DotCloudWorkshopList.from_response(fetched.value)
			_write_cache(game, list)
			for r in list.removed():
				DotLog.debug(CHANNEL, "not on for this game", {
					"content": r.get("contentId", ""), "reason": r.get("reason", ""),
				})
	if not fetched.ok:
		var err: DotError = fetched.error
		if err.code == DotError.CODE_AUTH:
			# A rejected token is a guest, and the cached list belonged to whoever held the old one.
			_drop_cache(game)
			summary["guest"] = true
			summary["reason"] = "guest"
			_list = null
			DotLog.info(CHANNEL, "token refused, treating as a guest", {"game": game})
			return DotResult.success(null)
		summary["offline"] = true
		var level_fields := {"game": game, "why": err.code, "message": err.message}
		if [DotError.CODE_NETWORK, DotError.CODE_TIMEOUT, DotError.CODE_HTTP].has(err.code):
			DotLog.info(CHANNEL, "site unreachable, using the cached list", level_fields)
		else:
			DotLog.warn(CHANNEL, "list request failed, using the cached list", level_fields)
		if list == null:
			summary["reason"] = "offline_no_cache"
			_list = null
			return DotResult.success(null)
		summary["from_cache"] = true

	_list = list
	summary["revision"] = list.revision()
	summary["takes_subscriptions"] = not list.accepts().is_empty()
	await _mount_all(list, cloud_client, summary)
	return DotResult.success(null)


func _fetch(game: String, token: String, since: String) -> DotResult:
	if config.workshop_backbone_url.strip_edges() == "":
		return DotResult.fail(DotError.CODE_STATE, "No workshop_backbone_url is configured.")
	_http.base_url = config.workshop_backbone_url
	_http.timeout_sec = config.workshop_timeout_sec
	var path := "/api/app/v1/workshop?game=%s&platform=%s" % [game.uri_encode(), request_platform()]
	if since != "":
		path += "&since=" + since.uri_encode()
	var res := await _http.get_json(path, {"Authorization": "Bearer " + token})
	if not res.ok:
		return res
	var body: Variant = res.value
	if not (body is Dictionary) or not ((body as Dictionary).get("items", []) is Array):
		return DotResult.fail(DotError.CODE_PARSE, "The Workshop list is not the shape this client reads.")
	return DotResult.success(body)


func _post_scope(body: Dictionary) -> DotResult:
	var prepared := _prepare()
	if not prepared.ok:
		return prepared
	var token := _token()
	if token == "":
		return DotResult.fail(DotError.CODE_AUTH, "Sign in to change a subscription.")
	if config.workshop_backbone_url.strip_edges() == "":
		return DotResult.fail(DotError.CODE_STATE, "No workshop_backbone_url is configured.")
	_http.base_url = config.workshop_backbone_url
	_http.timeout_sec = config.workshop_timeout_sec
	var res := await _http.post_json("/api/app/v1/workshop/scope", body, {"Authorization": "Bearer " + token})
	if not res.ok:
		DotLog.info(CHANNEL, "scope change refused", {"why": res.code(), "message": res.error.message})
		return res
	# The cached list is now stale, and its revision must not be trusted: a "since" equal to the
	# server's new revision would answer "unchanged" and keep the old items for another launch.
	_forget_revision(_game_id)
	DotLog.info(CHANNEL, "scope changed", {"subscription": str(body.get("subscriptionId", ""))})
	return res


func _mount_all(list: DotCloudWorkshopList, cloud_client: DotCloudClient, summary: Dictionary) -> void:
	var accepts := list.accepts()
	var accepted_kinds: Array = accepts.get("kinds", []) if accepts.get("kinds", []) is Array else []
	var skipped: Array = summary["skipped"]
	var failed: Array = summary["failed"]
	var candidates: Array[Dictionary] = []

	for item in list.items():
		var pack := DotCloudWorkshopList.pack_of(item)
		var id: String = str(pack.get("contentId", ""))
		var version: String = str(pack.get("version", ""))
		if id == "" or version == "":
			continue
		var kinds: Array = pack.get("kinds", []) if pack.get("kinds", []) is Array else []
		if not accepted_kinds.is_empty() and not kinds.is_empty() and not _any_in(kinds, accepted_kinds):
			skipped.append(_skip(id, version, REASON_INCOMPATIBLE))
			continue
		if device.is_off(id):
			skipped.append(_skip(id, version, REASON_DEVICE_OFF))
			continue
		var key_id: String = str(pack.get("keyId", ""))
		if not config.workshop_key_ids.has(key_id):
			_fail_pack(failed, id, version, DotError.make(
				DotError.CODE_FORBIDDEN, "The pack is signed with a key a subscription does not trust.", key_id
			))
			continue
		if not _script_allowed(bool(pack.get("runsCode", false)), bool(pack.get("approved", false))):
			skipped.append(_skip(id, version, REASON_SCRIPT_POLICY))
			continue
		if candidates.size() >= config.workshop_max_packs:
			skipped.append(_skip(id, version, REASON_TOO_MANY))
			continue
		candidates.append({"id": id, "version": version, "item": item, "pack": pack, "title": str(item.get("name", id))})

	# Plan: each manifest is fetched and verified before anything large is downloaded, so the
	# size checks below are about the bytes this device is actually missing.
	var planned: Array[Dictionary] = []
	var cum := 0
	var store_limit := 0
	var referenced := 0
	for c in candidates:
		var id: String = c["id"]
		var version: String = c["version"]
		var missing := 0
		if not cloud_client.is_mounted(StringName(id), version):
			var resolved := await cloud_client.resolve_manifest(
				StringName(id), version, str((c["pack"] as Dictionary).get("manifestUrl", ""))
			)
			if not resolved.ok:
				_fail_pack(failed, id, version, resolved.error)
				continue
			var manifest: DotCloudManifest = resolved.value
			if not config.workshop_key_ids.has(manifest.signature_key_id):
				_fail_pack(failed, id, version, DotError.make(
					DotError.CODE_FORBIDDEN, "The manifest is signed with a key a subscription does not trust.",
					manifest.signature_key_id
				))
				continue
			# The signed manifest is the truth about code; the list is the site's summary of it.
			if (
				bool(manifest.provides.get("runs_code", false))
				and not _script_allowed(true, bool((c["pack"] as Dictionary).get("approved", false)))
			):
				skipped.append(_skip(id, version, REASON_SCRIPT_POLICY))
				continue
			missing = int(cloud_client.plan_for(manifest)["missing_bytes"])
			store_limit = cloud_client.store.limit_bytes()
			referenced = cloud_client.store.referenced_bytes()
		# Never evict the game's own content to make room: only unreferenced objects can go,
		# so what is referenced plus what is coming must fit.
		if store_limit > 0 and missing > 0 and referenced + cum + missing > store_limit:
			skipped.append(_skip(id, version, REASON_QUOTA))
			continue
		cum += missing
		c["missing"] = missing
		planned.append(c)

	var allow_downloads := true
	if cum > 0:
		allow_downloads = await _may_download(planned, cum)
	var to_mount: Array[Dictionary] = []
	for c in planned:
		if int(c["missing"]) > 0 and not allow_downloads:
			skipped.append(_skip(c["id"], c["version"], REASON_METERED))
		else:
			to_mount.append(c)

	var total := to_mount.size()
	var bytes_total := 0
	for c in to_mount:
		bytes_total += int(c["missing"])
	var bytes_done := 0
	var done := 0
	for c in to_mount:
		var id: String = c["id"]
		var version: String = c["version"]
		progress.emit(done, total, bytes_done, bytes_total, str(c["title"]))
		var mounted := await cloud_client.ensure_for_session(
			StringName(id), version, DotContentIndex.SESSION_SOLO, &"subscription",
			{
				"uid_policy": "add_only", "allow_root": false,
				"manifest_url": str((c["pack"] as Dictionary).get("manifestUrl", "")),
			}
		)
		done += 1
		if mounted.ok:
			(summary["mounted"] as Array).append({"content_id": id, "version": version})
			if bool((c["pack"] as Dictionary).get("runsCode", false)):
				_ran_code = true
			bytes_done += int(c["missing"])
		else:
			_fail_pack(failed, id, version, mounted.error)
		progress.emit(done, total, bytes_done, bytes_total, str(c["title"]))


## Whether this launch may download [param bytes] bytes: decided once for the whole set.
func _may_download(planned: Array[Dictionary], bytes: int) -> bool:
	var policy := device.metered_policy(config.workshop_metered)
	var metered := is_metered()
	if metered and policy == "never":
		return false
	var ask := (metered and policy == "ask") or (policy == "ask" and bytes > config.workshop_ask_over_bytes)
	if not ask:
		return true
	if not ask_fn.is_valid():
		return false
	var packs: Array = []
	for c in planned:
		if int(c["missing"]) > 0:
			packs.append({"content_id": c["id"], "version": c["version"], "title": c["title"], "bytes": c["missing"]})
	var answer: Variant = await ask_fn.call({"bytes": bytes, "metered": metered, "packs": packs})
	return answer == true


## [param approved] is the site's verdict for [method request_platform], which never claims a
## looser platform than this build is; so "approved" here always means approved for code that
## can run on this machine, and the policy below is the client's own floor on top of it.
func _script_allowed(runs_code: bool, approved: bool) -> bool:
	if not runs_code:
		return true
	match config.workshop_script_packs:
		"any":
			return true
		"approved":
			return approved
	return false


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
		"takes_subscriptions": false, "mounted": [], "skipped": [], "failed": [],
	}


# --- setup and the cache ------------------------------------------------------


func _prepare() -> DotResult:
	if _prepared:
		return DotResult.success(null)
	if config == null:
		config = DotCloudWorkshopConfig.new()
	if config_file != "" and FileAccess.file_exists(config_file):
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return loaded
	config.apply_env()
	config.apply_cli()
	var valid := config.validate()
	if not valid.ok:
		return valid
	device = DotCloudWorkshopDevice.new(cache_dir.path_join("device.json"))
	device.load_file()
	_http = DotHttp.new()
	_http.name = "WorkshopHttp"
	_http.max_retries = 0
	_http.max_response_bytes = 4 * 1024 * 1024
	add_child(_http)
	_prepared = true
	return DotResult.success(null)


func _cloud() -> DotCloudClient:
	if cloud != null:
		return cloud
	return DotRegistry.get_service(DotCloudClient.SERVICE) as DotCloudClient


func _token() -> String:
	if not token_fn.is_valid():
		return ""
	return str(token_fn.call())


## The platform this instance sends: [member force_platform] when set and allowed, else
## [method client_platform]. The site trusts this claim only for the client's own safety (it
## decides what is listed as approved), so a native build never claims [code]web[/code].
func request_platform() -> String:
	var forced := force_platform.strip_edges().to_lower()
	if forced == "":
		return client_platform()
	var own := client_platform()
	var native_ok := forced == "desktop" or forced == "mobile"
	if forced == own or native_ok:
		return forced
	if not _platform_refusal_logged:
		_platform_refusal_logged = true
		DotLog.warn(CHANNEL, "force_platform refused: this build is not that platform", {
			"forced": forced, "sent": own,
		})
	return own


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


func _cache_path(game: String) -> String:
	return cache_dir.path_join("%s_%s.json" % [DotPaths.slugify(game, 40), game.sha256_text().substr(0, 8)])


func _read_cache(game: String) -> Dictionary:
	var path := _cache_path(game)
	if not FileAccess.file_exists(path):
		return {}
	var read := DotPaths.read_json(path)
	if not read.ok or not (read.value is Dictionary):
		DotLog.warn(CHANNEL, "cached list unreadable, ignoring it", {"path": path})
		return {}
	var d: Dictionary = read.value
	if not (d.get("response", null) is Dictionary):
		return {}
	return d


func _cache_is_this_account(cached: Dictionary) -> bool:
	if account_id == "":
		return true
	return DotValue.same(str(cached.get("account", "")), account_id)


func _write_cache(game: String, list: DotCloudWorkshopList) -> void:
	var written := DotPaths.write_json(_cache_path(game), {
		"account": list.account(), "revision": list.revision(),
		"fetched_at": int(Time.get_unix_time_from_system()), "response": list.response,
	})
	if not written.ok:
		DotLog.warn(CHANNEL, "could not cache the list", {"why": written.code(), "message": written.error.message})


func _drop_cache(game: String) -> void:
	var path := _cache_path(game)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		DotWeb.sync_filesystem()


func _forget_revision(game: String) -> void:
	var cached := _read_cache(game)
	if cached.is_empty():
		return
	cached["revision"] = ""
	DotPaths.write_json(_cache_path(game), cached)
