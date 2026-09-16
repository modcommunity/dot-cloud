class_name DotCloudRegistry
extends RefCounted

## The registry's half of a publish: claim a version, then say what happened.
##
## [b]Why a publish talks to a server at all.[/b] Everything this class does could be
## skipped by a publisher who chose to, and the point is what happens when it is not
## skipped: the registry owns the `<owner>/<repo>` namespace and it owns the rule that
## a version is published exactly once. Both are enforced there -- a unique index and
## an account -- because a check that lives only in a publishing tool protects an
## honest publisher from an accident and nothing else.
##
## [b]Why the version is claimed BEFORE the bytes move.[/b] Publishing a pack is
## minutes of hashing and uploading, and the version number has to be ours for all of
## it. Doing the work first and registering afterwards means two publishes of one
## version both do the work and one throws it away -- having already spent the
## storage. So: [method claim], then the slow part, then [method complete] or
## [method fail].
##
## [b]Why a failed publish keeps its number.[/b] [method fail] does not free the
## version. A failure that handed its number straight to the next attempt would let a
## second publish take it while somebody is still reading why the first did not work.
##
## [codeblock]
## var reg := DotCloudRegistry.new(http, token)
## var claim := await reg.claim("dot-controller", "1.0.0", files.size(), total_bytes)
## if not claim.ok:
##     return claim  # taken, out of space, not your namespace -- it says which
##
## var built := publisher.publish(source, out)
## if built.ok:
##     await reg.complete(claim.value["id"], files.size(), total_bytes, sha)
## else:
##     await reg.fail(claim.value["id"], built.error.message)
## [/codeblock]

const CHANNEL := "cloud.reg"

## Where the registry lives. The default is the site's own API surface.
const DEFAULT_PATH := "/api/app/v1/packs"

var _http: DotHttp
var _token: String
var _path: String


## [param http] must already be in the tree -- [DotHttp] is a [Node] and pools
## [HTTPRequest] children, which never poll while it is detached.
func _init(http: DotHttp, token: String, path: String = DEFAULT_PATH) -> void:
	_http = http
	_token = token
	_path = path


func _headers() -> Dictionary:
	# A bearer, not a cookie: this runs in a terminal, and the credential is a CLI
	# token the member approved by name and can revoke by name.
	return {"Authorization": "Bearer %s" % _token}


## Takes `<owner>/<repo>@<version>`, or explains why it cannot.
##
## The owner half is NOT sent: the server takes it from the credential. A publisher
## that could name its own owner could publish into somebody else's namespace by
## typing their name, which is the one thing this whole scheme exists to prevent.
##
## Returns the claim's `id` and the `content_id` the server resolved, which is what
## the manifest must then be built with -- the server's answer, not a guess.
func claim(
	repo_name: String,
	version: String,
	file_count: int,
	byte_size: int,
	asset_id: int = 0,
	release_id: int = 0
) -> DotResult:
	var body := {
		"action": "claim",
		"version": version,
		"fileCount": file_count,
		"byteSize": byte_size,
	}

	# An asset publishes under ITS name, so `repoName` is not sent beside one: two
	# sources for one field is a disagreement waiting to happen, and the server would
	# have to pick.
	if asset_id > 0:
		body["assetId"] = asset_id
	else:
		body["repoName"] = repo_name

	if release_id > 0:
		body["releaseId"] = release_id

	var sent := await _send(body)

	if not sent.ok:
		return sent

	var d: Dictionary = sent.value

	if not d.has("id"):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The registry's answer did not name a claim.",
			str(d).substr(0, 200)
		)

	# [b]JSON has one number type and Godot parses it as a float.[/b] So a claim id
	# arrives as `65.0`, and every line that reports it -- the log, an error, whatever
	# the caller prints -- says `65.0` for a database row called 65. Narrowed here, at
	# the one place the wire becomes ours, rather than at each of the callers who
	# would each have to remember.
	d["id"] = int(d["id"])

	DotLog.info(
		CHANNEL,
		"claimed",
		{"content": d.get("contentId", "?"), "version": version, "claim": d.get("id", 0)}
	)

	return DotResult.success(d)


## The bytes are in. [param file_count] and [param byte_size] are what ACTUALLY
## landed, which is what the member's allowance is charged -- the claim's numbers were
## a statement of intent.
func complete(
	claim_id: int,
	file_count: int,
	byte_size: int,
	manifest_sha: String = "",
	contains: Dictionary = {}
) -> DotResult:
	var body := {
		"action": "complete",
		"id": claim_id,
		"fileCount": file_count,
		"byteSize": byte_size,
	}

	if manifest_sha != "":
		body["manifestSha"] = manifest_sha

	# The bill of materials: `{ "<owner>/<repo>": "<version>" }`. Not a dependency
	# list -- nothing resolves it -- but it is the only way to answer "which published
	# games contain this asset version?" once an asset has been vendored into one.
	if not contains.is_empty():
		body["contains"] = contains

	var sent := await _send(body)

	if sent.ok:
		DotLog.info(CHANNEL, "published", {"claim": claim_id, "files": file_count})

	return sent


## It did not work. Said out loud so the version stops reading as "still uploading".
func fail(claim_id: int, error: String) -> DotResult:
	var sent := await _send(
		{"action": "fail", "id": claim_id, "error": error.substr(0, 500)}
	)

	if sent.ok:
		DotLog.warn(CHANNEL, "publish failed", {"claim": claim_id, "why": error})

	return sent


## The body out of the API's envelope.
##
## [b]Every answer is `{"ok": bool, "data": {...}}`.[/b] Reading the top level for the
## fields was the first thing tried and it fails in the least helpful way available:
## the request succeeded, the JSON parsed, and the claim came back as "the registry's
## answer did not name a claim" -- which reads as a server that changed its mind
## rather than as a client looking one level too high. An envelope is also where the
## server says `ok: false` with a message worth repeating, so unwrapping and error
## reporting are the same job.
func _payload(value: Variant) -> DotResult:
	if not (value is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The registry did not answer with an object.",
			str(value).substr(0, 200)
		)

	var doc: Dictionary = value

	if not bool(doc.get("ok", false)):
		return DotResult.fail(
			DotError.CODE_INVALID,
			str(doc.get("message", "The registry refused the request.")),
			str(doc.get("code", ""))
		)

	var data: Variant = doc.get("data", {})

	if not (data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The registry's answer carried no data object.",
			str(doc).substr(0, 200)
		)

	return DotResult.success(data)


## POST, and report what the REGISTRY said rather than what HTTP said.
##
## [b]The interesting refusals are not 2xx.[/b] "That version is already published" is
## a 409 and "you are out of space" is a 413, so [DotHttp] hands both back as a failed
## [DotResult] whose code is `http` -- and a publisher told "the registry refused the
## claim (http)" has learned nothing it can act on. The body of those responses is the
## same envelope as a success and carries the reason in words; [member DotError.detail]
## is where [method DotError.from_http] already put it. So: parse it, and let a taken
## version say it is a taken version.
func _send(body: Dictionary) -> DotResult:
	var res := await _http.post_json(_path, body, _headers())

	if res.ok:
		return _payload(res.value)

	# A refusal with a readable body beats the status line it arrived on.
	var parsed: Variant = JSON.parse_string(res.error.detail)

	if parsed is Dictionary:
		var spoke := _payload(parsed)

		if not spoke.ok:
			return spoke

	return res.wrap("The registry refused the request.")
