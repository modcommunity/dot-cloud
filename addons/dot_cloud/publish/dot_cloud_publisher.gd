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

## Where an imported output lives inside a pack.
##
## [b]Not `.godot/imported/`, which is where it lives in the project.[/b] Shipping it at
## its real path put the engine's own reserved directory name inside delivered content,
## and a web export cannot read it back:
##
##     ERR cloud  A required file is not readable after mounting.
##     res://dot_cloud/g2gfast/0.1.0/.godot/imported/character-m.glb-ceef4a4….scn
##
## Linux reads it perfectly, which is the trap -- a headless mount of the same pack lists
## the directory and loads every file in it, so the one check that could have caught this
## passes on the platform that does not matter and the game will not start on the one
## that does.
##
## The name is arbitrary as far as the loader is concerned: a `.import` marker names its
## output by absolute path, so the output can live anywhere as long as the marker says
## where. [method _rewrite_paths] moves both, together.
const IMPORTED_DIR := "_imported"

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


## Rewrites `res://X` to `res://<mount_root>/<id>/<version>/<where this pack put X>` for
## every X this pack contains, and leaves every other reference exactly as it was.
##
## [param inside] maps a reference's path to its path in the pack. Those differ only for
## an imported output, which moves to [constant IMPORTED_DIR]; for everything else the
## map is the identity and this is the plain prefixing it always was.
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
			out += prefix + str(inside[path])
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

	# [b]The id and version rules are the manifest's, and are not restated here.[/b]
	# They were, and the copy was already wrong the day `content_id` learned about
	# `<owner>/<name>`: this refused a namespaced id that [method DotCloudManifest.validate]
	# accepts, so a publisher could not produce content a client would happily mount.
	# One rule, in the class whose field it is. `validate()` also checks the version,
	# which this never did.
	var shape := manifest.validate_shape()
	if not shape.ok:
		return shape

	var relatives := _collect(source_dir)

	# [b]An imported asset's OUTPUT lives at the project root, which is not always inside
	# the directory being published.[/b] `_collect` walks the source, so publishing a
	# whole project picks up `.godot/imported/` for free -- and publishing a SUBDIRECTORY
	# of one, which is how every imported map is published
	# (`--content ../game-g2gfast/maps/imported`), picks up the `.import` markers and
	# none of the files they point at. The marker then names
	# `res://.godot/imported/<name>.ctex`, the pack does not contain it, and the host
	# does not have it either:
	#
	#     ERROR: Unable to open file: res://.godot/imported/nature_sand_wavey_1.png-….ctex
	#     WARNING: Loaded resource as image file, this will not work on export.
	#
	# The warning is Godot falling back to reading the PNG directly, which works on a
	# dedicated server and does not work in an export -- so this failed loudly on the
	# machine that could survive it and would have failed silently on the ones that
	# could not.
	var imported := _imported_outputs_for(source_dir, relatives)
	var extra: Dictionary = imported["files"]
	var remap: Dictionary = imported["remap"]

	for rel: String in extra:
		if not relatives.has(rel):
			relatives.append(rel)

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
	# [b]A MAP, from where a reference says the file is to where this pack actually put
	# it.[/b] It was a set, because those two were always the same thing -- and they stop
	# being the same the moment an imported output is relocated out of `.godot/`. A
	# `.import` marker still names `res://.godot/imported/tile.png-abc.ctex`, which is
	# true of the project and false of the pack, so the marker has to be pointed at
	# [constant IMPORTED_DIR] rather than merely prefixed.
	var inside := {}
	for rel in relatives:
		inside[rel] = rel
	for project_rel: String in remap:
		inside[project_rel] = remap[project_rel]

	var staging := out_dir.path_join(".rewritten")
	if rewrite_resource_paths:
		DotPaths.remove_tree(staging)

	for rel in relatives:
		# `extra` entries come from the project root; everything else from the source.
		var abs: String = extra.get(rel, source_dir.path_join(rel))

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
		# [b]An output is kept whatever directory it is in; a MARKER is not.[/b] The
		# output's directory is `.godot/`, which is excluded and has to be -- that is the
		# whole reason for this branch. A marker's directory is the asset's own, so a
		# marker under `screenshots/` or `maps/imported/` belongs to a file this pack is
		# not shipping, and keeping it shipped 241 `.import` files naming content that is
		# not in the pack -- along with, once `_imported_outputs_for` follows them, every
		# texture behind the exclusion the publisher was asked for.
		# [b]Never from the walk, whatever the platform lists.[/b] An imported output
		# reaches a pack only through `_imported_outputs_for`, which puts it under
		# [constant IMPORTED_DIR] -- so there is exactly one route in, and it is the one
		# that also rewrites the marker pointing at it. This branch used to be that route
		# and shipped the path verbatim.
		if rel.begins_with(".godot/"):
			continue

		var skip := false

		for dir_name in exclude_dirs:
			if rel.begins_with(dir_name + "/") or rel.contains("/" + dir_name + "/"):
				skip = true
				break

		if skip:
			continue

		# The suffix rules below would drop a marker, and they are right to for
		# everything else: `.import` is in `exclude_suffixes` because a pack that is all
		# scenes and scripts has no use for one. Decided here, after the directory rules
		# rather than before them.
		if include_imported and rel.ends_with(".import"):
			out.append(rel)
			continue

		for suffix in exclude_suffixes:
			if rel.ends_with(suffix):
				skip = true
				break

		if not skip:
			out.append(rel)

	out.sort()
	return out


## Imported outputs an `.import` marker in this pack points at.
##
## Returns `{"files": {pack_rel: absolute}, "remap": {project_rel: pack_rel}}` — the
## second is what lets [method _rewrite_paths] send a marker to where the output actually
## landed, which is [constant IMPORTED_DIR] and not where the marker says.
##
## Empty only when the source is not inside a Godot project at all, which is a legitimate
## thing to publish and simply has no imported anything.
##
## [b]It used to return empty for a source that IS a project root, on the grounds that
## `_collect` had already found them. `_collect` never found one.[/b]
## [method DotPaths.list_files_recursive] lists through [method DirAccess.list_dir_begin],
## which skips hidden entries unless asked otherwise -- and `.godot` is hidden. So a pack
## published from a project root carried the `.import` markers and not one of the
## `.ctex`, `.mesh` or `.scn` files they point at, which is the exact failure
## [member include_imported] exists to prevent:
##
##     ERROR: Unable to open file: res://.godot/imported/floor.png-6c859f4….ctex
##      at: _load_data (scene/resources/compressed_texture.cpp:45)
##
## Every delivered game was published that way. It survived unnoticed because the ONE
## shape that was tested -- an imported map, published from a subdirectory -- is the one
## shape this function already handled, and because a dedicated server does not draw
## anything: the textures it could not load cost it nothing, and the client that could
## not draw them is a different process reading a different log.
##
## Resolving from the markers rather than by listing `.godot/imported/` wholesale is also
## the smaller pack: a project's imported directory holds an output for every asset it
## has ever imported, including the ones this pack excludes and the ones it deleted.
func _imported_outputs_for(
	source_dir: String, relatives: PackedStringArray
) -> Dictionary:
	var out := {}
	var remap := {}
	var empty := {"files": out, "remap": remap}

	if not include_imported:
		return empty

	var root := _project_root_of(source_dir)

	if root == "":
		return empty

	for rel in relatives:
		if not rel.ends_with(".import"):
			continue

		var text := FileAccess.get_file_as_string(source_dir.path_join(rel))

		# `path=` for a single output, `dest_files=[…]` for the general case. Both are
		# read: an importer may write either, and a marker naming an output this misses
		# is an asset that silently does not load.
		for hit in _res_paths_in(text):
			if not hit.begins_with(".godot/"):
				continue
			if not FileAccess.file_exists(root.path_join(hit)):
				continue
			var landed := "%s/%s" % [IMPORTED_DIR, hit.get_file()]
			out[landed] = root.path_join(hit)
			remap[hit] = landed

	return {"files": out, "remap": remap}


## Every `res://…` path in a text blob, as paths relative to the project root.
func _res_paths_in(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0

	while true:
		var at := text.find("res://", i)
		if at < 0:
			break

		var j := at + 6
		while j < text.length() and not (text[j] in ['"', "'", " ", "\t", "\n", "\r", ",", "]", ")"]):
			j += 1

		var path := text.substr(at + 6, j - (at + 6))
		if path != "" and not out.has(path):
			out.append(path)

		i = j

	return out


## The Godot project [param dir] sits in, or "" when it is not inside one.
func _project_root_of(dir: String) -> String:
	var at := dir.simplify_path().rstrip("/")

	# Bounded rather than `while true`: a path that never yields a parent would spin, and
	# no project in this family is twelve directories deep.
	for _i in range(12):
		if at == "" or at == "/" or at == "res:/" or at == "user:/":
			return ""
		if FileAccess.file_exists(at.path_join("project.godot")):
			return at
		at = at.get_base_dir()

	return ""


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
