class_name DotCloudUploader
extends RefCounted

## Sends a published pack (`manifest.json` + `objects/`) through the site, which holds the bucket credentials and is the only writer.
##
## claim, manifest, next (presigned PUTs), PUT, finalize; a re-run resumes. The token goes to curl in a config file, never argv or environment. See docs/publishing.md ("Uploading").

const CHANNEL := "dot_cloud.upload"

## Site origin, no trailing slash.
var site := "https://tmcdev.net"
## Path of a file holding the creator token.
var token_file := ""
## Report progress through this callable(done: int, total: int, bytes_done: int).
var on_progress := Callable()
## Retries per object PUT.
var retries := 3
## Object PUTs in flight at once; 1 sends them one at a time.
var concurrency := 6


## Claims [param repo_name]@[param version]. Value: {id, contentId}; build the pack with that contentId.
## A positive [param asset_id] links the version to that asset (the site then names the pack after the asset's repo name and lets visitors fetch it).
## A positive [param member_of] instead publishes it as a MEMBER of that collection asset: the pack keeps its own id
## ([param repo_name]), is listed in the asset's collection.json and gets no Workshop page of its own.
func claim(repo_name: String, version: String, files: int, bytes: int, asset_id: int = 0, member_of: int = 0) -> DotResult:
	var body := {"action": "claim", "repoName": repo_name, "version": version, "fileCount": files, "byteSize": bytes}
	if asset_id > 0:
		body["assetId"] = asset_id
	if member_of > 0:
		body["memberOf"] = member_of
	var r := _with_config(func(cfg: String) -> DotResult: return _post("/api/app/v1/packs", body, cfg))
	if r.ok and not (r.value as Dictionary).has("id"):
		return DotResult.fail(DotError.CODE_PARSE, "The site's claim answer names no id.")
	return r


## Every version this account holds, newest first. Value: Array of {contentId, version, status, fileCount, byteSize, manifestSha, manifestUrl}.
func versions(repo_name: String = "") -> DotResult:
	var body := {"action": "versions"}
	if repo_name != "":
		body["repoName"] = repo_name
	var r := _with_config(func(cfg: String) -> DotResult: return _post("/api/app/v1/packs", body, cfg))
	if r.ok:
		return DotResult.success((r.value as Dictionary).get("versions", []))
	return r


## Links every version of [param repo_name] already published into collection asset [param asset_id] as a member,
## e.g. a map pack that got a Workshop page of its own. Value: {contentId, assetId, linked, previousAssets, compat, collection};
## [code]previousAssets[/code] are the pages it left, which the site does not delete.
func member(repo_name: String, asset_id: int) -> DotResult:
	var body := {"action": "member", "repoName": repo_name, "assetId": asset_id}
	return _with_config(func(cfg: String) -> DotResult: return _post("/api/app/v1/packs", body, cfg))


## Marks a claim failed so its number is not left dangling.
func fail_claim(claim_id: int, error: String) -> void:
	_with_config(func(cfg: String) -> DotResult:
		return _post("/api/app/v1/packs", {"action": "fail", "id": claim_id, "error": error.left(500)}, cfg))


## Uploads the publisher output in [param out_dir] against [param claim_id].
## Value: {uploaded, skipped, bytes, status ("READY"|"HELD"), manifest_url, manifest_sha256}.
func upload(out_dir: String, claim_id: int) -> DotResult:
	var man_bytes := FileAccess.get_file_as_bytes(out_dir.path_join("manifest.json"))
	if man_bytes.is_empty():
		return DotResult.fail(DotError.CODE_IO, "No manifest.json in %s." % out_dir)
	return _with_config(func(cfg: String) -> DotResult: return _run(man_bytes, out_dir, claim_id, cfg))


func _with_config(job: Callable) -> DotResult:
	var token := FileAccess.get_file_as_string(token_file).strip_edges()
	if token == "":
		return DotResult.fail(DotError.CODE_INVALID, "No CLI token in %s." % token_file)
	var cfg := OS.get_user_data_dir().path_join(".dot_cloud_curl_%d.cfg" % OS.get_process_id())
	var f := FileAccess.open(cfg, FileAccess.WRITE)
	if f == null:
		return DotResult.fail(DotError.CODE_IO, "Could not write the curl config.")
	f.store_line('header = "Authorization: Bearer %s"' % token)
	f.close()
	var res: DotResult = job.call(cfg)
	DirAccess.remove_absolute(cfg)
	return res


func _run(man_bytes: PackedByteArray, out_dir: String, claim_id: int, cfg: String) -> DotResult:
	var route := "/api/app/v1/packs/upload"
	var m := _post(route, {"action": "manifest", "id": claim_id, "manifest": Marshalls.raw_to_base64(man_bytes)}, cfg)
	if not m.ok:
		return m.wrap("manifest refused")
	var total := int(m.value.get("missing", 0))
	var skipped := int(m.value.get("present", 0))
	var done := 0
	var bytes := 0
	while true:
		var page := _post(route, {"action": "next", "id": claim_id, "max": 500}, cfg)
		if not page.ok:
			return page.wrap("listing uploads")
		var puts: Array = page.value.get("puts", [])
		var jobs: Array = []
		for p: Dictionary in puts:
			var h := str(p["sha256"])
			var file := out_dir.path_join("objects/%s/%s" % [h.substr(0, 2), h])
			if not FileAccess.file_exists(file):
				file = out_dir.path_join("bundles/%s.zip" % h)
			jobs.append({"put": p, "path": file})
		var expired := false
		if concurrency > 1 and jobs.size() > 1 and _parallel_supported():
			var tally := [done, bytes]
			var sent := _put_many(jobs, func(n: int, nbytes: int) -> void:
				tally[0] += n
				tally[1] += nbytes
				if on_progress.is_valid():
					on_progress.call(tally[0], total, tally[1]))
			done = tally[0]
			bytes = tally[1]
			if not sent.ok:
				return sent
			expired = bool(sent.value)
		else:
			for j: Dictionary in jobs:
				var put := _put(j["put"], j["path"])
				if not put.ok:
					if put.error.detail.contains("403"):
						expired = true
						break
					return put.wrap("uploading %s" % str(j["put"]["sha256"]))
				done += 1
				bytes += int(j["put"].get("size", 0))
				if on_progress.is_valid():
					on_progress.call(done, total, bytes)
		if expired:
			continue
		if puts.is_empty() and int(page.value.get("remaining", 0)) == 0:
			break

	var fin := _post(route, {"action": "finalize", "id": claim_id}, cfg)
	if not fin.ok:
		return fin.wrap("finalize refused")
	var d: Dictionary = fin.value
	DotLog.info(CHANNEL, "uploaded", {"claim": claim_id, "objects": done, "present": skipped, "status": d.get("status", "?")})
	return DotResult.success({
		"uploaded": done, "skipped": skipped, "bytes": bytes, "status": str(d.get("status", "")),
		"manifest_url": str(d.get("manifestUrl", "")), "manifest_sha256": str(d.get("manifestSha256", "")),
		"message": str(d.get("message", "")), "approval_id": int(d.get("approvalId", 0)),
	})


## POST JSON through curl; the app-API envelope is unwrapped. 5xx and 429 retry; 4xx never do.
func _post(route: String, body: Dictionary, cfg: String) -> DotResult:
	var tmp := OS.get_user_data_dir().path_join(".dot_cloud_body_%d.json" % OS.get_process_id())
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string(JSON.stringify(body))
	f.close()
	var last := DotResult.fail(DotError.CODE_NETWORK, "no attempt")
	for attempt in range(retries + 1):
		var out: Array = []
		var code := OS.execute("curl", ["-sS", "-K", cfg, "-X", "POST", "-H", "Content-Type: application/json",
			"--data-binary", "@" + tmp, "-w", "\n%{http_code}", site + route], out, true)
		if code != 0:
			last = DotResult.fail(DotError.CODE_NETWORK, "curl failed (%d)" % code, "".join(out).left(300))
		else:
			var text := "".join(out)
			var nl := text.rfind("\n")
			var status := int(text.substr(nl + 1))
			var doc: Variant = JSON.parse_string(text.left(nl))
			if status >= 200 and status < 300 and doc is Dictionary and bool(doc.get("ok", false)) and doc.get("data") is Dictionary:
				DirAccess.remove_absolute(tmp)
				return DotResult.success(doc["data"])
			# The site's envelope is flat ({ok, code, message}); a nested {error: {...}} is accepted too.
			var err: Dictionary = {}
			if doc is Dictionary:
				err = doc["error"] if doc.get("error") is Dictionary else doc
			var why := str(err.get("message", text.left(200)))
			var kind := DotError.CODE_AUTH if status == 401 else DotError.CODE_FORBIDDEN if status == 403 else DotError.CODE_HTTP
			last = DotResult.fail(kind, "HTTP %d %s: %s" % [status, str(err.get("code", "")), why], str(err.get("code", "")))
			if status < 500 and status != 429:
				break
		OS.delay_msec(1000 << attempt)
	DirAccess.remove_absolute(tmp)
	return last


## PUT one object to its presigned URL with exactly the headers the site named (the bucket checks the sha-256 itself).
func _put(p: Dictionary, path: String) -> DotResult:
	var args := ["-sS", "-f", "-X", "PUT", "--upload-file", path, "-o", "NUL" if OS.get_name() == "Windows" else "/dev/null"]
	for k in (p.get("headers", {}) as Dictionary):
		args.append_array(["-H", "%s: %s" % [k, p["headers"][k]]])
	args.append(str(p["url"]))
	var last := ""
	for attempt in range(retries + 1):
		var out: Array = []
		var code := OS.execute("curl", args, out, true)
		if code == 0:
			return DotResult.success()
		last = "curl exit %d %s" % [code, "".join(out).left(200)]
		if code == 22 and last.contains("403"):
			return DotResult.fail(DotError.CODE_FORBIDDEN, "presigned URL expired", "403")
		OS.delay_msec(1000 << attempt)
	return DotResult.fail(DotError.CODE_NETWORK, last)


## PUTs [param jobs] ({put, path}) with one `curl --parallel`, [member concurrency] at a time; per-transfer outcomes are appended to a status file that is polled for [param progress] callable(n, bytes).
## Value: true when a presigned URL had expired (403), so the caller asks for fresh ones.
func _put_many(jobs: Array, progress: Callable) -> DotResult:
	var base := OS.get_user_data_dir().path_join(".dot_cloud_put_%d" % OS.get_process_id())
	var cfg := base + ".cfg"
	var status := base + ".status"
	var f := FileAccess.open(cfg, FileAccess.WRITE)
	if f == null:
		return DotResult.fail(DotError.CODE_IO, "Could not write the curl config.")
	var sink := "NUL" if OS.get_name() == "Windows" else "/dev/null"
	f.store_line("silent\nshow-error\nparallel\nparallel-max = %d" % concurrency)
	for i in jobs.size():
		var p: Dictionary = jobs[i]["put"]
		if i > 0:
			f.store_line("next")
		f.store_line("fail\nrequest = \"PUT\"\nretry = %d\nretry-connrefused" % retries)
		f.store_line("upload-file = %s\nurl = %s\noutput = %s" % [_q(jobs[i]["path"]), _q(str(p["url"])), _q(sink)])
		for k in (p.get("headers", {}) as Dictionary):
			f.store_line("header = %s" % _q("%s: %s" % [k, p["headers"][k]]))
		f.store_line("write-out = %s" % _q("%%output{>>%s}%%{exitcode} %%{http_code} %s\\n" % [status.replace("\\", "/"), str(p["sha256"])]))
	f.close()
	FileAccess.open(status, FileAccess.WRITE).close()
	var by_sha := {}
	for j: Dictionary in jobs:
		by_sha[str(j["put"]["sha256"])] = int(j["put"].get("size", 0))
	var pid := OS.create_process("curl", ["-K", cfg])
	if pid < 0:
		DirAccess.remove_absolute(cfg)
		DirAccess.remove_absolute(status)
		return DotResult.fail(DotError.CODE_NETWORK, "Could not start curl.")
	var seen := 0
	var reported := 0
	var failed: Array = []
	var expired := false
	while true:
		var running := OS.is_process_running(pid)
		var text := FileAccess.get_file_as_string(status)
		var lines := text.split("\n", false)
		if not text.ends_with("\n") and not lines.is_empty():
			lines.remove_at(lines.size() - 1)
		for i in range(seen, lines.size()):
			var parts := lines[i].split(" ")
			if parts.size() < 3:
				continue
			reported += 1
			if parts[0] == "0":
				progress.call(1, int(by_sha.get(parts[2], 0)))
			elif parts[1] == "403":
				expired = true
			else:
				failed.append("%s: curl exit %s HTTP %s" % [parts[2], parts[0], parts[1]])
			seen = i + 1
		if not running:
			break
		OS.delay_msec(100)
	DirAccess.remove_absolute(cfg)
	DirAccess.remove_absolute(status)
	if not failed.is_empty():
		var sha := str(failed[0]).get_slice(":", 0)
		return DotResult.fail(DotError.CODE_NETWORK, "uploading %s: %s" % [sha, failed[0]], "%d failed" % failed.size())
	if reported < jobs.size():
		return DotResult.fail(DotError.CODE_NETWORK, "curl ended after %d of %d transfers" % [reported, jobs.size()])
	return DotResult.success(expired)


static var _parallel_ok := -1


## True when the installed curl can drive [method _put_many]: `%output{}` in write-out needs 8.3.0 (`%{exitcode}` 7.75, `--parallel` 7.66).
func _parallel_supported() -> bool:
	if _parallel_ok < 0:
		var out: Array = []
		var ok := false
		if OS.execute("curl", ["--version"], out, true) == 0:
			var m := RegEx.create_from_string("curl (\\d+)\\.(\\d+)").search("".join(out))
			if m != null:
				var v := int(m.get_string(1)) * 1000 + int(m.get_string(2))
				ok = v >= 8003
		_parallel_ok = 1 if ok else 0
	return _parallel_ok == 1


## Quotes a curl config value.
func _q(v: String) -> String:
	return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
