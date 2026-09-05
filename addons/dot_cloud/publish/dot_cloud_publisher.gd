class_name DotCloudPublisher
extends RefCounted

## Turns a directory of content into a manifest plus a content-addressed object
## tree, ready to serve over HTTP.
##
## Output layout — deliberately identical to what [DotCloudSourceHttp] expects, so
## the publish target is a static directory you can drop behind any web server or
## CDN with no configuration:
##
## [codeblock]
## <out>/manifest.json              the signed manifest
## <out>/objects/<aa>/<full-hash>   one file per unique content hash
## [/codeblock]
##
## Content addressing on the server side too, for the same reasons it works on the
## client: identical files across versions are stored and transferred once, paths
## are immutable so a CDN can cache them forever with no invalidation, and
## republishing a game with one changed texture uploads one object.
##
## [codeblock]
## var pub := DotCloudPublisher.new()
## pub.content_id = "dm_arena"
## pub.version = "1.2.0"
## pub.entry_scene = "arena.tscn"
## pub.signing_key_pem = FileAccess.get_file_as_string("res://keys/content.key")
##
## var res := pub.publish("res://content/dm_arena", "user://published/dm_arena")
## [/codeblock]

const CHANNEL := "cloud.pub"

var content_id: String = ""
var version: String = "0.0.0"
var display_name: String = ""
var mount_root: String = "dot_cloud"
var entry_scene: String = ""
var min_engine_version: String = ""

## Base URLs written into the manifest, so clients know where to fetch from.
var mirrors: PackedStringArray = PackedStringArray()

## Private key PEM. Leave empty to publish unsigned.
##
## Unsigned content is refused by a default-configured client, which is the point.
## Publishing unsigned is for local development.
var signing_key_pem: String = ""

var signing_key_id: String = "default"

## Passed through to the manifest untouched, for a host project's own use.
var metadata: Dictionary = {}

## Glob-ish suffixes never included.
##
## Godot's [code].import[/code] sidecars and editor droppings would otherwise ship
## as content — harmless but wasteful, and confusing to anyone reading a manifest.
var exclude_suffixes: PackedStringArray = PackedStringArray([
	".import", ".gd.uid", ".tmp", ".DS_Store", "Thumbs.db",
])

## Directory names skipped entirely.
var exclude_dirs: PackedStringArray = PackedStringArray([
	".git", ".godot", ".svn", "__pycache__",
])

## Assigns groups to files by path prefix, as [code]prefix -> group[/code].
##
## Lets a publisher mark [code]"hd/"[/code] as an optional download without
## hand-editing the manifest.
var group_rules: Dictionary = {}

## Marks files optional by path prefix.
var optional_prefixes: PackedStringArray = PackedStringArray()

## Restricts files to platforms by path prefix, as [code]prefix -> [tags][/code].
var platform_rules: Dictionary = {}


# --- Publishing ------------------------------------------------------------

## Builds a manifest and object tree from [param source_dir] into [param out_dir].
##
## Synchronous and unapologetically so: this runs in a build step or a CLI, not in
## a frame. It hashes every file with [method DotHash.sha256_file], which blocks.
func publish(source_dir: String, out_dir: String) -> DotResult:
	if content_id == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "publish() needs a content_id."
		)

	var slug := DotPaths.slugify(content_id)
	if slug != content_id:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"content_id must be lowercase alphanumeric with - or _.",
			"try '%s'" % slug
		)

	if not DirAccess.dir_exists_absolute(source_dir):
		return DotResult.fail(
			DotError.CODE_IO, "Source directory not found.", source_dir
		)

	var objects_dir := out_dir.path_join("objects")
	var made := DotPaths.ensure_dir(objects_dir)
	if not made.ok:
		return made

	var manifest := DotCloudManifest.new()
	manifest.content_id = content_id
	manifest.version = version
	manifest.display_name = display_name
	manifest.mount_root = mount_root
	manifest.entry_scene = entry_scene
	manifest.min_engine_version = min_engine_version
	manifest.mirrors = mirrors
	manifest.metadata = metadata

	var relatives := _collect(source_dir)
	if relatives.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No publishable files in the source directory.",
			source_dir
		)

	var written := 0
	var deduped := 0
	var total_bytes := 0
	var seen := {}

	for rel in relatives:
		var abs := source_dir.path_join(rel)

		var safe := DotPaths.safe_relative(rel)
		if not safe.ok:
			# Refuse rather than skip: a path the publisher cannot express safely
			# would be silently missing from the shipped content, and the failure
			# would surface as a missing texture on a player's machine.
			return safe.wrap("Cannot publish '%s'." % rel)

		var hashed := DotHash.sha256_file(abs)
		if not hashed.ok:
			return hashed.wrap("Could not hash '%s'." % rel)

		var digest: String = hashed.value
		var size := DotPaths.file_size(abs)

		var entry := DotCloudFile.new()
		entry.path = safe.value
		entry.sha256 = digest
		entry.size = size
		entry.required = not _is_optional(entry.path)
		entry.groups = _groups_for(entry.path)
		entry.platforms = _platforms_for(entry.path)

		var checked := entry.validate()
		if not checked.ok:
			return checked

		manifest.files.append(entry)
		total_bytes += size

		if seen.has(digest):
			deduped += 1
			continue
		seen[digest] = true

		var dest := objects_dir.path_join("%s/%s" % [digest.substr(0, 2), digest])

		# Objects are immutable by construction — the name is the hash — so an
		# existing one is already correct and copying over it is pure IO.
		if FileAccess.file_exists(dest) and DotPaths.file_size(dest) == size:
			continue

		var copied := _copy(abs, dest)
		if not copied.ok:
			return copied
		written += 1

	# The payload is written verbatim, whether signed or not, so the bytes the
	# client verifies are the bytes the publisher hashed. Nothing reformats them
	# in between — see DotCloudEnvelope.
	var payload := manifest.payload_bytes()
	var document := payload

	if signing_key_pem != "":
		var sig := DotCloudSignature.sign(payload, signing_key_pem)
		if not sig.ok:
			return sig.wrap("Could not sign the manifest.")

		manifest.signature = sig.value
		manifest.signature_key_id = signing_key_id

		document = DotCloudEnvelope.wrap(
			payload, str(sig.value), signing_key_id
		).to_utf8_buffer()
	else:
		DotLog.warn(
			CHANNEL,
			"publishing UNSIGNED content — a default-configured client will refuse it",
			{"content": manifest.key()}
		)

	var manifest_path := out_dir.path_join("manifest.json")
	var saved := DotPaths.write_bytes(manifest_path, document)
	if not saved.ok:
		return saved

	DotLog.info(
		CHANNEL,
		"published",
		{
			"content": manifest.key(),
			"files": manifest.files.size(),
			"objects": seen.size(),
			"deduped": deduped,
			"written": written,
			"bytes": DotPaths.format_bytes(total_bytes),
			"signed": manifest.signature != "",
			"out": out_dir,
		}
	)

	return DotResult.success({
		"manifest": manifest,
		"manifest_path": manifest_path,
		"files": manifest.files.size(),
		"objects": seen.size(),
		"objects_written": written,
		"deduped": deduped,
		"bytes": total_bytes,
		"signed": manifest.signature != "",
	})


## Files to publish, as paths relative to [param source_dir].
func _collect(source_dir: String) -> PackedStringArray:
	var out := PackedStringArray()

	for rel in DotPaths.list_files_recursive(source_dir):
		var skip := false

		for dir_name in exclude_dirs:
			if rel.begins_with(dir_name + "/") or rel.contains("/" + dir_name + "/"):
				skip = true
				break

		if skip:
			continue

		for suffix in exclude_suffixes:
			if rel.ends_with(suffix):
				skip = true
				break

		if not skip:
			out.append(rel)

	out.sort()
	return out


func _copy(from: String, to: String) -> DotResult:
	var parent := DotPaths.ensure_parent_dir(to)
	if not parent.ok:
		return parent

	var read := DotPaths.read_bytes(from)
	if not read.ok:
		return read

	return DotPaths.write_bytes(to, read.value)


func _is_optional(path: String) -> bool:
	for prefix in optional_prefixes:
		if path.begins_with(prefix):
			return true
	return false


func _groups_for(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for prefix in group_rules:
		if path.begins_with(str(prefix)):
			out.append(str(group_rules[prefix]))
	return out


func _platforms_for(path: String) -> PackedStringArray:
	for prefix in platform_rules:
		if path.begins_with(str(prefix)):
			var tags: Variant = platform_rules[prefix]
			if tags is PackedStringArray:
				return tags
			if tags is Array:
				var out := PackedStringArray()
				for t in (tags as Array):
					out.append(str(t))
				return out
			return PackedStringArray([str(tags)])
	return PackedStringArray()


# --- Keys ------------------------------------------------------------------

## Generates a signing keypair and writes both halves.
##
## The private half is written with whatever permissions the platform defaults
## to, which is not good enough for a key that authorises code execution on every
## player's machine. Move it into a secrets manager and delete the file.
static func generate_keys(private_path: String, public_path: String) -> DotResult:
	var pair := DotCloudSignature.generate_keypair()
	if not pair.ok:
		return pair

	var d: Dictionary = pair.value

	var priv := DotPaths.write_text(private_path, str(d["private"]))
	if not priv.ok:
		return priv

	var pub := DotPaths.write_text(public_path, str(d["public"]))
	if not pub.ok:
		return pub

	DotLog.info(
		CHANNEL,
		"generated signing keypair",
		{"private": private_path, "public": public_path}
	)

	DotLog.warn(
		CHANNEL,
		"the private key is on disk with default permissions — move it into a "
		+ "secrets store and delete the file",
		{"path": private_path}
	)

	return DotResult.success(d)
