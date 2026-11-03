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
