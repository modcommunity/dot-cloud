extends RefCounted

## Pieces of [method DotCloudAddonSet._assemble], in a file of their own so the addon set stays inside the
## size budget. Nothing here is used on its own.

## [method base] of a pack that holds no addon.
const NOT_AN_ADDON := "\n"

## Text formats the site rewrites onto the pack's mount prefix when it publishes.
const REWRITTEN := ["tscn", "tres", "import"]


## Where the addon's directory starts in [param manifest]: "" for a pack that is the addon (a dot-*
## release), `addons/<dir>/` for a project that holds it (a game addon's release), else [constant NOT_AN_ADDON].
static func base(manifest: DotCloudManifest, dir: String) -> String:
	if DotCloudAddonSet._has_file(manifest, "plugin.cfg"):
		return ""
	var nested := "addons/%s/" % dir
	return nested if DotCloudAddonSet._has_file(manifest, nested + "plugin.cfg") else NOT_AN_ADDON


## Where [param path] goes: the addon's files under `res://addons/<dir>/`, the rest of a project pack
## (its `_imported/` outputs, data its scenes name) where the site's rewritten references expect it.
static func target(manifest: DotCloudManifest, dir: String, at: String, path: String) -> String:
	if at == "" or path.begins_with(at):
		return "res://addons/%s/%s" % [dir, path.trim_prefix(at)]
	return manifest.mount_prefix().path_join(path)


## [param source], or a copy in [param scratch] whose references to the addon's own files are moved
## from the mount prefix the site wrote back to `res://addons/<dir>/`, where the overlay puts them.
## References to the rest of the pack keep the prefix: [method target] puts those files there.
static func unrelocate(manifest: DotCloudManifest, dir: String, at: String, path: String, source: String, scratch: String) -> String:
	if at == "" or not path.begins_with(at) or path.get_extension().to_lower() not in REWRITTEN:
		return source
	var text := FileAccess.get_file_as_string(source)
	var moved := manifest.mount_prefix().path_join(at)
	if not text.contains(moved):
		return source
	var w := FileAccess.open(scratch, FileAccess.WRITE)
	w.store_string(text.replace(moved, "res://addons/%s/" % dir))
	w.close()
	return scratch


## The overlay's file name, from what is in it.
static func path(dir: String, manifests: Dictionary, fingerprint: String) -> String:
	var lines := PackedStringArray([fingerprint])
	for d: String in manifests:
		for f in (manifests[d] as DotCloudManifest).files:
			lines.append("%s/%s:%s" % [d, f.path, f.sha256])
	lines.sort()
	return dir.path_join("overlay-%s.pck" % "\n".join(lines).sha256_text().substr(0, 16))


## Adds [param source] at [param target], and its self-pointing `.remap` when it is a resource.
static func add(packer: PCKPacker, target: String, source: String, remap_file: String) -> int:
	var err := packer.add_file(target, source)
	if err == OK and target.get_extension().to_lower() in DotCloudAddonSet.REMAPPED:
		err = add_remap(packer, remap_file, target)
	return err


## Writes a self-pointing `.remap` for [param target] to [param remap_file] and adds it to the pack.
static func add_remap(packer: PCKPacker, remap_file: String, target: String) -> int:
	var w := FileAccess.open(remap_file, FileAccess.WRITE)
	w.store_string("[remap]\n\npath=\"%s\"\n" % target)
	w.close()
	return packer.add_file(target + ".remap", remap_file)


## Picks the script confirm_boot loads to see which copy is running: the addon's API file when it has
## one (constants, nothing that runs on load), else the first by path, so the choice is the same every build.
static func note_probe(probes: Dictionary, dir: String, manifest: DotCloudManifest, at: String, target: String) -> void:
	var api := "%s_api.gd" % dir
	if target == "res://addons/%s/%s" % [dir, api]:
		probes[dir] = target
	elif not DotCloudAddonSet._has_file(manifest, at + api) and (not probes.has(dir) or target < str(probes[dir])):
		probes[dir] = target
