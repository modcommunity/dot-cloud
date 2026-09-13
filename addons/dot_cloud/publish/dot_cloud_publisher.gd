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

## Ship the engine's imported form of assets that have one.
##
## [b]Without this a pack can carry a .glb or a .png and deliver nothing.[/b] Those are
## not loadable resources: the editor imports them into [code].godot/imported/[/code] and
## every load of the source path is redirected there by the [code].import[/code] marker
## beside it. Nothing imports at runtime, on any platform -- so a pack built from a source
## tree, with `.import` in [member exclude_suffixes] and `.godot` in
## [member exclude_dirs], ships the bytes of an asset that no [method @GDScript.load] can
## open. Measured, on a real pack:
##
## [codeblock]
## character-a.glb    exists=false file=true  load=null
## arena.tscn         exists=true  file=true  load=PackedScene
## [/codeblock]
##
## `file=true` is the trap: the bytes are right there, so nothing reports a missing file.
##
## With this on, the markers and [code].godot/imported/[/code] come too, and the rewrite
## moves the three absolute paths inside each marker onto the mount. The [code].md5[/code]
## companions are left behind: they exist so the EDITOR can tell whether a reimport is
## needed, and nothing at runtime reads one.
##
## Costs what the imported form costs -- for a game whose assets are 18 character meshes,
## about the size of the meshes again. Turn it off for a pack that is all scenes and
## scripts, where there is nothing to import.
var include_imported: bool = true

## Assigns groups to files by path prefix, as [code]prefix -> group[/code].
##
## Lets a publisher mark [code]"hd/"[/code] as an optional download without
## hand-editing the manifest.
var group_rules: Dictionary = {}

## Rewrite `res://` references inside .tscn / .tres to the mount prefix.
##
## On by default, because a pack whose scenes still name their authored paths mounts
## and then fails to find its own scripts. Turn it off for content that is pure data
## and references nothing, or for a publisher that has already done this itself.
@export var rewrite_resource_paths: bool = true

## Text resources whose `res://` references have to move with the pack.
##
## .tscn and .tres only. A .scn or .res is the binary form of the same thing and
## cannot be rewritten by string substitution -- a project that saves binary scenes
## has to publish them already namespaced, and nothing here can tell it so. Godot
## writes text by default and this family uses text everywhere.
##
## [b].import too, and that is what makes [member include_imported] work.[/b] An import
## marker is three absolute paths -- the imported resource, the source file, and the
## dest_files list -- and all three name the project the asset was authored in. Rewritten
## like any other reference, they name the mount instead.
static func _is_text_resource(rel: String) -> bool:
	var e := rel.get_extension().to_lower()
	return e == "tscn" or e == "tres" or e == "import"


## Rewrites `res://X` to `res://<mount_root>/<id>/<version>/X` for every X this pack
## contains, and leaves every other reference exactly as it was.
##
## Returns the staged file's path, or "" when nothing needed changing -- so the caller
## keeps hashing the original and no object is written twice for an identical file.
func _rewrite_paths(abs: String, staged: String, inside: Dictionary) -> DotResult:
	var text := FileAccess.get_file_as_string(abs)
	if text == "" and FileAccess.get_open_error() != OK:
		return DotResult.fail(DotError.CODE_IO, "Could not read the file.", abs)

	var prefix := "res://%s/%s/%s/" % [mount_root, content_id, version]
	var out := ""
	var i := 0
	var changed := false

	while true:
		var at := text.find("res://", i)
		if at < 0:
			out += text.substr(i)
			break

		out += text.substr(i, at - i)

		# The reference ends at the first character that cannot be in a path. Scenes
		# quote them, but .tres and a stray comment do not always, so this stops at
		# whitespace and quotes rather than assuming a delimiter.
		var j := at + 6
		while j < text.length():
			var c := text[j]
			if c == '"' or c == "'" or c == " " or c == "\t" or c == "\n" or c == "\r" or c == ")":
				break
			j += 1

		var path := text.substr(at + 6, j - (at + 6))

		# Already namespaced: publishing a directory that was published before, or a
		# source tree somebody has namespaced by hand. Rewriting it again would bury
		# the content one level deeper on every republish.
		if inside.has(path) and not path.begins_with("%s/%s/%s/" % [mount_root, content_id, version]):
			out += prefix + path
			changed = true
		else:
			out += "res://" + path

		i = j

	if not changed:
		return DotResult.success("")

	var parent := DotPaths.ensure_parent_dir(staged)
	if not parent.ok:
		return parent

	var f := FileAccess.open(staged, FileAccess.WRITE)
	if f == null:
		return DotResult.fail(
			DotError.CODE_IO, "Could not write the rewritten file.", staged
		)
	f.store_string(out)
	f.close()

	return DotResult.success(staged)


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
	var rewritten := 0
	var seen := {}

	# Every path this pack will contain, so the rewrite below can tell a reference to
	# its own content from a reference to the host build's.
	var inside := {}
	for rel in relatives:
		inside[rel] = true

	var staging := out_dir.path_join(".rewritten")
	if rewrite_resource_paths:
		DotPaths.remove_tree(staging)

	for rel in relatives:
		var abs := source_dir.path_join(rel)

		# [b]A scene names its script by ABSOLUTE path, and the pack does not mount at
		# the path it was authored at.[/b] Godot writes `res://game/thing.gd` into a
		# .tscn, the pack mounts at `res://<mount_root>/<id>/<version>/`, and the scene
		# then loads with its script missing -- measured:
		#
		#     mount: true   scene exists: true
		#     ERROR: Attempt to open script 'res://s.gd' … 'File not found'
		#
		# which is the worst failure shape there is: the pack mounts, the scene loads,
		# and nothing says a word until something tries to run one of its scripts.
		# Rewritten here, where the id and the version are known and the bytes have not
		# been hashed yet, so the manifest covers what will actually be mounted.
		#
		# Only paths this pack CONTAINS are moved. A scene referencing
		# `res://addons/dot_core/…` means the host build's copy and must stay absolute.
		if rewrite_resource_paths and _is_text_resource(rel):
			var staged := _rewrite_paths(abs, staging.path_join(rel), inside)
			if not staged.ok:
				return staged.wrap("Could not rewrite paths in '%s'." % rel)
			if str(staged.value) != "":
				abs = str(staged.value)
				rewritten += 1

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

	# The staged rewrites have been hashed and copied into objects/ by now, and every
	# object is named by its own hash -- so the staging tree is pure duplication and
	# leaving it behind would double the size of a published directory somebody is
	# about to upload.
	if rewrite_resource_paths:
		DotPaths.remove_tree(staging)

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
			"rewritten": rewritten,
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
		"rewritten": rewritten,
		"deduped": deduped,
		"bytes": total_bytes,
		"signed": manifest.signature != "",
	})


## Files to publish, as paths relative to [param source_dir].
func _collect(source_dir: String) -> PackedStringArray:
	var out := PackedStringArray()

	for rel in DotPaths.list_files_recursive(source_dir):
		# The engine's imported form, and the markers that point at it. Decided before the
		# exclusions rather than after, because both of the rules below would drop it:
		# `.godot` is an excluded directory and `.import` an excluded suffix, and they are
		# right to be for everything else in there.
		if _is_imported_form(rel):
			if include_imported and not rel.ends_with(".md5"):
				out.append(rel)
			continue

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


## The engine's imported output, or a marker pointing at it.
static func _is_imported_form(rel: String) -> bool:
	return rel.begins_with(".godot/imported/") or rel.ends_with(".import")


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
