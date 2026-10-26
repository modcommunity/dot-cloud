extends RefCounted

## [method DotCloudClient.prefetch] and its document parser, in a file of their own so the client stays
## inside the size budget. Nothing here is used on its own.

const CHANNEL := "cloud"


## Downloads the packs a server will want into the store before connecting, mounting nothing; see
## [method DotCloudClient.prefetch].
static func run(c: DotCloudClient, doc: Dictionary) -> DotResult:
	if not c._started:
		var started := await c.start()
		if not started.ok:
			return started
	if DotPlatform.is_web() and not c.config.prefetch_on_web:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "Prefetch is off in the browser.", "prefetch_on_web")

	var parsed := parse(doc, c.config.prefetch_max_packs)
	if not parsed.ok:
		return parsed
	var plan: Dictionary = parsed.value

	var doc_mirrors := str(plan["mirrors_url"])
	if doc_mirrors != "" and c._mirror_list == null and c.config.use_mirrors:
		await c.load_mirror_list(doc_mirrors)

	var skipped: Array = (plan["over_cap"] as Array).duplicate()
	var fetched := 0
	var bytes := 0
	var budget := c.config.prefetch_max_bytes

	for entry: Dictionary in plan["packs"]:
		var id := str(entry["id"])
		var version := str(entry["version"])
		var resolved := await c.resolve_manifest(StringName(id), version)
		if not resolved.ok:
			skipped.append({"id": id, "version": version, "why": resolved.error.message})
			continue
		var manifest: DotCloudManifest = resolved.value
		var need := c.plan_for(manifest)
		var missing := int(need["missing_bytes"])
		if missing > budget - bytes:
			skipped.append({"id": id, "version": version, "why": "over the prefetch byte budget (%s)" % DotPaths.format_bytes(missing)})
			continue
		var key := manifest.key()
		var done := await c._download(manifest, PackedStringArray(), key)
		# The sync claims refs; a prefetched pack nobody mounted must stay evictable.
		if not c.mounter.is_mounted(key) and not c._inflight.has(key):
			c.store.release_refs(key)
			c.store.flush_index()
		if not done.ok:
			skipped.append({"id": id, "version": version, "why": done.error.message})
			continue
		fetched += 1
		bytes += missing

	if c._inflight.is_empty() and not c._sync_busy:
		c._set_phase(DotCloudClient.Phase.IDLE, "")
	DotLog.info(CHANNEL, "prefetch finished", {
		"server": plan["server_id"], "fetched": fetched, "skipped": skipped.size(),
		"bytes": DotPaths.format_bytes(bytes),
	})
	return DotResult.success({
		"packs_fetched": fetched,
		"packs_skipped": skipped.size(),
		"bytes": bytes,
		"skipped": skipped,
		"avatar_library": plan["avatar_library"],
	})


## Validates a prefetch document strictly: kind, format, and each pack's id and version through
## [method DotCloudManifest.validate_shape]. Packs past [param max_packs] land in `over_cap`.
static func parse(doc: Dictionary, max_packs: int) -> DotResult:
	if str(doc.get("kind", "")) != "dot_cloud_prefetch":
		return DotResult.fail(DotError.CODE_INVALID, "This is not a prefetch document.")
	var fmt: Variant = doc.get("format", 0)
	if not (fmt is int or fmt is float) or int(fmt) != 1:
		return DotResult.fail(DotError.CODE_VERSION, "Unsupported prefetch format.", str(fmt))
	var raw: Variant = doc.get("packs", null)
	if not (raw is Array):
		return DotResult.fail(DotError.CODE_PARSE, "The prefetch document has no packs array.")
	var packs: Array = []
	var over_cap: Array = []
	var seen := {}
	for p: Variant in raw:
		if not (p is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "A prefetch pack is not an object.")
		var id := str((p as Dictionary).get("id", ""))
		var version := str((p as Dictionary).get("version", ""))
		var probe := DotCloudManifest.new()
		probe.content_id = id
		probe.version = version
		var shape := probe.validate_shape()
		if not shape.ok:
			return shape.wrap("The prefetch document names an unusable pack.")
		var key := "%s@%s" % [id, version]
		if seen.has(key):
			continue
		seen[key] = true
		var entry := {"id": id, "version": version}
		if packs.size() >= max_packs:
			over_cap.append({"id": id, "version": version, "why": "over the prefetch pack limit"})
		else:
			packs.append(entry)
	var mirrors := str(doc.get("mirrors_url", ""))
	if mirrors != "":
		var ok := DotCloudMirrorList.check_base_url(mirrors)
		if not ok.ok:
			return ok.wrap("The prefetch document's mirrors_url is unusable.")
	return DotResult.success({
		"server_id": doc.get("server_id", null),
		"app_id": doc.get("app_id", null),
		"packs": packs,
		"over_cap": over_cap,
		"avatar_library": str(doc.get("avatar_library", "")),
		"mirrors_url": mirrors,
	})
