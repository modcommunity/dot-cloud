class_name DotCloudMirrorList
extends RefCounted

## The site's signed list of community mirrors of a game origin (API 13).
## A mirror is untrusted (it can withhold or corrupt, never substitute; manifests never come from one), so the
## list is a [DotCloudEnvelope] signed by a key trusted for [constant SCOPE_ID].

const CHANNEL := "cloud.mirrors"

## The pseudo content id a key must be trusted for to sign a mirror list.
const SCOPE_ID := "_platform/mirrors"

const KIND := "dot_cloud_mirrors"
const FORMAT := 1
const MAX_MIRRORS := 64

## Origin ROOT (packs under `<origin>/content`), without a trailing slash.
var origin: String = ""
var issued_at: int = 0
var expires_at: int = 0

## Accepted mirrors, each `{id, base_url, operator, regions, packs, avatars, latency_ms}`,
## in rank order once [method rank] has run (`latency_ms` -1 = not probed, -2 = unreachable).
var mirrors: Array[Dictionary] = []

## Entries refused while parsing, with the reason, for [method describe].
var dropped: PackedStringArray = PackedStringArray()


## Unwraps, verifies and parses a published mirror list. Malformed entries are dropped one by
## one; a bad envelope, signature, kind, format, origin or expiry refuses the whole list, and so
## does an [code]issued_at[/code] older than [param newest_seen] (a replayed list that is still valid).
static func parse_signed(bytes: PackedByteArray, trusted_keys: Dictionary, now_unix: int, newest_seen: int = 0) -> DotResult:
	var unwrapped := DotCloudEnvelope.unwrap(bytes)
	if not unwrapped.ok:
		return unwrapped.wrap("The mirror list is not a valid envelope.")
	var env: Dictionary = unwrapped.value
	if not bool(env["signed"]):
		return DotResult.fail(DotError.CODE_INTEGRITY, "The mirror list is not signed.")
	var payload: PackedByteArray = env["payload"]
	var verified := DotCloudSignature.verify_for(
		payload, str(env["signature"]), trusted_keys, SCOPE_ID, str(env["key_id"])
	)
	if not verified.ok:
		return verified.wrap("The mirror list's signature was refused.")

	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "The mirror list is not a JSON object.")
	var d := parsed as Dictionary
	if str(d.get("kind", "")) != KIND:
		return DotResult.fail(DotError.CODE_INVALID, "This is not a mirror list.", str(d.get("kind", "")))
	var fmt := int(d.get("format", 0))
	if fmt < 1 or fmt > FORMAT:
		return DotResult.fail(DotError.CODE_VERSION, "Unsupported mirror list format %d." % fmt)
	var list := DotCloudMirrorList.new()
	list.issued_at = int(d.get("issued_at", 0))
	list.expires_at = int(d.get("expires_at", 0))
	if list.expires_at <= 0 or now_unix > list.expires_at:
		return DotResult.fail(DotError.CODE_INVALID, "The mirror list has expired.", "expires_at %d" % list.expires_at)
	if list.issued_at < newest_seen:
		return DotResult.fail(DotError.CODE_INVALID, "The mirror list is older than one already accepted.",
			"issued_at %d < %d" % [list.issued_at, newest_seen])
	var origin_ok := check_base_url(str(d.get("origin", "")))
	if not origin_ok.ok:
		return origin_ok.wrap("The mirror list's origin is unusable.")
	list.origin = str(origin_ok.value)

	var raw: Variant = d.get("mirrors", [])
	if not (raw is Array):
		return DotResult.fail(DotError.CODE_PARSE, "The mirror list's mirrors is not an array.")
	if (raw as Array).size() > MAX_MIRRORS:
		return DotResult.fail(
			DotError.CODE_INVALID, "The mirror list names too many mirrors.",
			"%d, at most %d" % [(raw as Array).size(), MAX_MIRRORS]
		)
	for entry: Variant in raw:
		var m := _parse_entry(entry)
		if not m.ok:
			list.dropped.append(m.error.message)
			continue
		var md: Dictionary = m.value
		if md["base_url"] == list.origin or list._has_base(str(md["base_url"])):
			list.dropped.append("duplicate base %s" % md["base_url"])
			continue
		list.mirrors.append(md)
	if not list.dropped.is_empty():
		DotLog.debug(CHANNEL, "mirror entries dropped", {"dropped": list.dropped})
	return DotResult.success(list)


## The newest [code]issued_at[/code] recorded at [param path], or 0.
static func newest_seen(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var read := DotPaths.read_json(path)
	return maxi(0, int((read.value as Dictionary).get("issued_at", 0))) if read.ok and read.value is Dictionary else 0


## Records [param issued_at] at [param path] when it is newer than what is there.
static func remember(path: String, issued_at: int) -> void:
	if issued_at <= newest_seen(path):
		return
	var written := DotPaths.write_json(path, {"issued_at": issued_at}, false)
	if not written.ok:
		DotLog.warn(CHANNEL, "could not record the mirror list's issue time", {"detail": written.error.detail})
	DotWeb.sync_filesystem()


## An http(s) base with a host and no userinfo, query or fragment, returned without a trailing slash.
static func check_base_url(url: String) -> DotResult:
	var u := url.strip_edges()
	var rest := ""
	if u.begins_with("https://"):
		rest = u.substr(8)
	elif u.begins_with("http://"):
		rest = u.substr(7)
	else:
		return DotResult.fail(DotError.CODE_INVALID, "A mirror URL must be http or https.", url)
	if "?" in u or "#" in u or " " in u or "\\" in u:
		return DotResult.fail(DotError.CODE_INVALID, "A mirror URL must not carry a query or fragment.", url)
	var authority := rest.split("/")[0]
	if authority == "" or "@" in authority:
		return DotResult.fail(DotError.CODE_INVALID, "A mirror URL needs a host and no user info.", url)
	if "/../" in (u + "/") or "/./" in (u + "/"):
		return DotResult.fail(DotError.CODE_INVALID, "A mirror URL must not contain dot segments.", url)
	return DotResult.success(u.trim_suffix("/"))


static func _parse_entry(entry: Variant) -> DotResult:
	if not (entry is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "a mirror entry is not an object")
	var e := entry as Dictionary
	var base := check_base_url(str(e.get("base_url", "")))
	if not base.ok:
		return DotResult.fail(DotError.CODE_INVALID, "%s: %s" % [str(e.get("id", "?")), base.error.message])
	var packs := PackedStringArray()
	var raw_packs: Variant = e.get("packs", [])
	if raw_packs is Array:
		for p: Variant in raw_packs:
			if p is String and str(p) != "":
				packs.append(str(p))
	var regions := PackedStringArray()
	var raw_regions: Variant = e.get("regions", [])
	if raw_regions is Array:
		for r: Variant in raw_regions:
			regions.append(str(r))
	return DotResult.success({
		"id": str(e.get("id", "")),
		"base_url": str(base.value),
		"operator": str(e.get("operator", "")),
		"regions": regions,
		"packs": packs,
		"avatars": e.get("avatars", false) is bool and bool(e.get("avatars", false)),
		"latency_ms": -1,
	})


func _has_base(base: String) -> bool:
	for m in mirrors:
		if m["base_url"] == base:
			return true
	return false


## Whether [param pattern] (`*`, `owner/*` or an exact id) covers [param content_id].
static func pack_matches(pattern: String, content_id: String) -> bool:
	if pattern == "*" or pattern == content_id:
		return true
	return DotCloudSignature._match_segments(pattern, content_id)


## Content roots (`<base_url>/content`) of every mirror carrying [param content_id], in rank order.
func pack_bases(content_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	for m in mirrors:
		for pattern in (m["packs"] as PackedStringArray):
			if pack_matches(pattern, content_id):
				out.append(str(m["base_url"]) + "/content")
				break
	return out


## Whether [param url] is the origin or under it.
func is_origin_url(url: String) -> bool:
	return origin != "" and (url == origin or url.begins_with(origin + "/"))


## The same path on every mirror with `avatars: true`, for an origin URL; empty for any other.
func alternatives(url: String) -> PackedStringArray:
	var out := PackedStringArray()
	if origin == "" or not url.begins_with(origin + "/"):
		return out
	var rel := url.substr(origin.length())
	for m in mirrors:
		if bool(m["avatars"]):
			out.append(str(m["base_url"]) + rel)
	return out


## Probes each mirror once (HEAD `<base_url>/content/mirrors.json`) at most [param timeout_sec]
## each, all at once, and sorts by latency with unreachable mirrors last. Give it a [DotHttp]
## nobody else is using: its timeout and retries are overridden while this runs.
func rank(http: DotHttp, timeout_sec: float = 3.0) -> void:
	if http == null or mirrors.is_empty():
		return
	var saved_timeout := http.timeout_sec
	var saved_retries := http.max_retries
	http.timeout_sec = maxf(0.5, timeout_sec)
	http.max_retries = 0
	_probes_finished = 0
	for i in mirrors.size():
		_probe_one(http, i)
	while _probes_finished < mirrors.size():
		await _probe_done
	http.timeout_sec = saved_timeout
	http.max_retries = saved_retries
	mirrors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la := int(a["latency_ms"])
		var lb := int(b["latency_ms"])
		if (la < 0) != (lb < 0):
			return lb < 0
		return la < lb
	)
	DotLog.debug(CHANNEL, "mirrors ranked", {"order": _ids()})


signal _probe_done
var _probes_finished := 0


func _probe_one(http: DotHttp, i: int) -> void:
	var t0 := Time.get_ticks_msec()
	var res := await http.probe(str(mirrors[i]["base_url"]) + "/content/mirrors.json")
	mirrors[i]["latency_ms"] = (Time.get_ticks_msec() - t0) if res.ok else -2
	_probes_finished += 1
	_probe_done.emit()


func _ids() -> PackedStringArray:
	var out := PackedStringArray()
	for m in mirrors:
		out.append("%s:%d" % [m["id"], int(m["latency_ms"])])
	return out


func describe() -> Dictionary:
	return {
		"origin": origin,
		"expires_at": expires_at,
		"mirrors": Array(_ids()),
		"dropped": dropped.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["origin %s, %d mirrors, %d dropped" % [origin, mirrors.size(), dropped.size()]])
	for m in mirrors:
		out.append("  %-12s %s  %s ms  packs=%s avatars=%s" % [
			m["id"], m["base_url"], m["latency_ms"], ",".join(m["packs"]), m["avatars"],
		])
	return out
