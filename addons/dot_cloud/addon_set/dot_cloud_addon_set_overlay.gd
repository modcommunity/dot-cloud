extends RefCounted

## Pieces of [method DotCloudAddonSet._assemble], in a file of their own so the addon set stays inside the
## size budget. Nothing here is used on its own.


## The overlay's file name, from what is in it.
static func path(dir: String, manifests: Dictionary, fingerprint: String) -> String:
	var lines := PackedStringArray([fingerprint])
	for d: String in manifests:
		for f in (manifests[d] as DotCloudManifest).files:
			lines.append("%s/%s:%s" % [d, f.path, f.sha256])
	lines.sort()
	return dir.path_join("overlay-%s.pck" % "\n".join(lines).sha256_text().substr(0, 16))


## Writes a self-pointing `.remap` for [param target] to [param remap_file] and adds it to the pack.
static func add_remap(packer: PCKPacker, remap_file: String, target: String) -> int:
	var w := FileAccess.open(remap_file, FileAccess.WRITE)
	w.store_string("[remap]\n\npath=\"%s\"\n" % target)
	w.close()
	return packer.add_file(target + ".remap", remap_file)


## Picks the script confirm_boot loads to see which copy is running: the addon's API file when it has
## one (constants, nothing that runs on load), else the first by path, so the choice is the same every build.
static func note_probe(probes: Dictionary, dir: String, manifest: DotCloudManifest, rel: String, target: String) -> void:
	var api := "%s_api.gd" % dir
	if rel == api:
		probes[dir] = target
	elif not DotCloudAddonSet._has_file(manifest, api) and (not probes.has(dir) or target < str(probes[dir])):
		probes[dir] = target
