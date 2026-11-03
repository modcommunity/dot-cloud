extends RefCounted

## The dependency half of [DotCloudClient]'s job tracking, in a file of its own so the client stays
## inside the size budget. Nothing here is used on its own.

const MAX_DEPTH := 4


## Resolves a manifest's dependency tree ahead of the downloads and registers each pack's missing bytes,
## so the job's total is known before the first byte. Manifests are kept for [method ensure_dependency].
static func register_dependencies(c: DotCloudClient, manifest: DotCloudManifest, depth: int) -> void:
	if depth >= MAX_DEPTH or c.job == null:
		return
	for dep in manifest.dependencies:
		var id := StringName(str(dep["id"]))
		var version := str(dep["version"])
		if c.is_mounted(id, version):
			continue
		var resolved := await c.resolve_manifest(id, version)
		if not resolved.ok or c.job == null:
			continue
		var m: DotCloudManifest = resolved.value
		c._job_manifests[m.key()] = m
		var plan := c.plan_for(m)
		c.job.add_pack(m.key(), int(plan["missing_bytes"]), int(plan["missing_files"]))
		await register_dependencies(c, m, depth + 1)


## [method DotCloudClient.ensure] for one dependency, reusing the manifest [method register_dependencies] already fetched.
static func ensure_dependency(c: DotCloudClient, dep: Dictionary, below: PackedStringArray) -> DotResult:
	var id := StringName(str(dep["id"]))
	var version := str(dep["version"])
	var key := DotCloudClient.content_key_for(id, version)
	var known: DotCloudManifest = c._job_manifests.get(key)
	if known == null or c.is_mounted(id, version):
		return await c.ensure(id, version, PackedStringArray(), "", below)
	return await c.acquire_manifest(known, PackedStringArray(), below)


## Acquires every dependency, [member DotCloudConfig.parallel_packs] at a time. A failure stops new ones starting and lets the running ones finish; the result names the first failure in list order and lists every failed id in its context.
static func ensure_all(c: DotCloudClient, key: String, deps: Array, below: PackedStringArray) -> DotResult:
	var results: Array = []
	results.resize(deps.size())
	var state := {"next": 0, "live": 0, "stop": false}
	var worker := func() -> void:
		while not state["stop"] and int(state["next"]) < deps.size():
			var i: int = state["next"]
			state["next"] = i + 1
			var got: DotResult = await ensure_dependency(c, deps[i], below)
			results[i] = got
			if not got.ok:
				state["stop"] = true
		state["live"] = int(state["live"]) - 1
	var n := mini(maxi(1, c.config.parallel_packs), deps.size())
	for _w in n:
		state["live"] = int(state["live"]) + 1
		worker.call()
	while int(state["live"]) > 0:
		await c.get_tree().process_frame
	var failed := PackedStringArray()
	var first: DotResult = null
	for i in deps.size():
		var got: DotResult = results[i]
		if got == null or got.ok:
			continue
		failed.append("%s@%s" % [deps[i]["id"], deps[i]["version"]])
		if first == null:
			first = got.wrap("%s needs %s@%s" % [key, deps[i]["id"], deps[i]["version"]])
	if first == null:
		return DotResult.success(true)
	var ctx := first.error.context.duplicate()
	ctx["failed_dependencies"] = failed
	first.error.context = ctx
	return first
