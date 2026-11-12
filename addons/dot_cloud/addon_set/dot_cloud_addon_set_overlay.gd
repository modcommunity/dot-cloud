extends RefCounted

## Pieces of [method DotCloudAddonSet._assemble], in a file of their own so the addon set stays inside the
## size budget. Nothing here is used on its own.

## The most one overlay pack file holds. A browser keeps `user://` in IndexedDB one file per value, and Chrome
## refuses a value over 133169152 bytes (127 MiB): a larger overlay is never saved and the reload never comes.
const PART_BYTES := 96 * 1024 * 1024

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
static func add(packer: Parts, target: String, source: String, remap_file: String) -> int:
	var err := packer.add_file(target, source)
	if err == OK and target.get_extension().to_lower() in DotCloudAddonSet.REMAPPED:
		err = add_remap(packer, remap_file, target)
	return err


## Writes a self-pointing `.remap` for [param target] to [param remap_file] and adds it to the pack.
static func add_remap(packer: Parts, remap_file: String, target: String) -> int:
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


## Part [param index] of the overlay named [param first]; part 0 is [param first] itself.
static func part_path(first: String, index: int) -> String:
	return Parts.path_of(first, index)


## The parts of an overlay already on disk, or none when part 0 is missing. Part 0 is renamed into place last
## ([method Parts.finish]), so finding it means every other part was written.
static func existing_parts(first: String) -> PackedStringArray:
	var out := PackedStringArray()
	while FileAccess.file_exists(part_path(first, out.size())):
		out.append(part_path(first, out.size()))
	return out


## Whether [param path] is a part of the overlay named [param first].
static func is_part_of(path: String, first: String) -> bool:
	return path == first or (path.begins_with(first.trim_suffix(".pck") + ".") and path.ends_with(".pck"))


## One overlay written as several pack files, each at most [member limit] bytes of content (a single larger
## file gets a part of its own). Every part is written under a `.part` name and renamed when all are flushed.
class Parts:
	var first := ""
	var limit := PART_BYTES
	var paths := PackedStringArray()
	var _packer: PCKPacker = null
	var _used := 0

	## An inner class cannot call the outer script's static functions, so the naming lives here.
	static func path_of(p_first: String, index: int) -> String:
		return p_first if index == 0 else "%s.%d.pck" % [p_first.trim_suffix(".pck"), index]

	func _init(p_first: String, p_limit: int) -> void:
		first = p_first
		limit = maxi(p_limit, 1)

	func add_file(target: String, source: String) -> int:
		var f := FileAccess.open(source, FileAccess.READ)
		var size := f.get_length() if f != null else 0
		if f != null:
			f.close()
		if _packer == null or (_used > 0 and _used + size > limit):
			var err := _next()
			if err != OK:
				return err
		_used += size
		return _packer.add_file(target, source)

	func _next() -> int:
		if _packer != null:
			var err := _packer.flush(false)
			if err != OK:
				return err
		_packer = PCKPacker.new()
		_used = 0
		paths.append(path_of(first, paths.size()))
		return _packer.pck_start(paths[paths.size() - 1] + ".part")

	## Flushes the last part and renames every part into place, part 0 last.
	func finish() -> int:
		var err := _next() if _packer == null else OK
		if err == OK:
			err = _packer.flush(false)
		for i in range(paths.size() - 1, -1, -1):
			if err == OK:
				err = DirAccess.rename_absolute(paths[i] + ".part", paths[i])
		return err
