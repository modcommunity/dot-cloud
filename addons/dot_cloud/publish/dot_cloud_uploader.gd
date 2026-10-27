class_name DotCloudUploader
extends RefCounted

## Sends a published pack (`manifest.json` + `objects/`) through the site, which holds the bucket credentials and is the only writer.
##
## claim -> manifest (the site names what it lacks) -> next (presigned PUTs, a page at a time) -> PUT -> finalize. Re-running
## after a failure resumes: the site lists only what is still missing. The CLI token is read from a file and handed to curl in a
## config file, so it is on neither the command line nor the environment. Contract: docs/publishing.md ("Uploading").

const CHANNEL := "dot_cloud.upload"

## Site origin, no trailing slash.
var site := "https://dev.dotgames.org"
## Path of a file holding the creator token.
var token_file := ""
## Report progress through this callable(done: int, total: int, bytes_done: int).
var on_progress := Callable()
## Retries per object PUT.
var retries := 3


## Claims [param repo_name]@[param version]. Value: {id, contentId}; build the pack with that contentId.
func claim(repo_name: String, version: String, files: int, bytes: int) -> DotResult:
	var r := _with_config(func(cfg: String) -> DotResult:
		return _post("/api/app/v1/packs", {
			"action": "claim", "repoName": repo_name, "version": version, "fileCount": files, "byteSize": bytes,
		}, cfg))
	if r.ok and not (r.value as Dictionary).has("id"):
		return DotResult.fail(DotError.CODE_PARSE, "The site's claim answer names no id.")
	return r


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
		for p: Dictionary in puts:
			var h := str(p["sha256"])
			var file := out_dir.path_join("objects/%s/%s" % [h.substr(0, 2), h])
			if not FileAccess.file_exists(file):
				file = out_dir.path_join("bundles/%s.zip" % h)
			var put := _put(p, file)
			if not put.ok:
				if put.error.detail.contains("403"):
					break
				return put.wrap("uploading %s" % h)
			done += 1
			bytes += int(p.get("size", 0))
			if on_progress.is_valid():
				on_progress.call(done, total, bytes)
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
		"message": str(d.get("message", "")),
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
			var err: Dictionary = doc.get("error", {}) if doc is Dictionary and doc.get("error") is Dictionary else {}
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
	var args := ["-sS", "-f", "-X", "PUT", "--upload-file", path, "-o", "/dev/null"]
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
