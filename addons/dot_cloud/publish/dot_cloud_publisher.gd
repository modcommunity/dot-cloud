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
## <out>/bundles/<hash>.zip         the small objects in one archive (see [member write_bundle])
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
const _Sides := preload("dot_cloud_publisher_sides.gd")
const _Rewrite := preload("dot_cloud_publisher_rewrite.gd")
const TOKENS_ENGINE_FILE := "engine.txt"

## The file at the source root that says what the pack offers a game.
const PROVIDES_FILE := "provides.json"
const LICENCE_FILE := "licence.json"

## The file at the source root that says which files only one side fetches (API 8):
## [code]{"client": ["lightmaps/"], "server": ["server/*.json"]}[/code]. See [member side_rules].
const SIDES_FILE := "sides.json"

var content_id: String = ""
var version: String = "0.0.0"
var display_name: String = ""
var mount_root: String = "dot_cloud"
var entry_scene: String = ""
var min_engine_version: String = ""

## Content this pack needs mounted first, each `{id, version}` (see [member DotCloudManifest.dependencies]).
var dependencies: Array[Dictionary] = []

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
	# Documentation: a repository's README, CLAUDE.md and docs/*.md are loaded by
	# nothing at runtime, and dot-ci's package.sh drops them too.
	".md",
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

## Ship the source file beside its imported form ([code]tile.png[/code] next to
## [code]tile.png.import[/code] and its [code].ctex[/code]). Off by default.
##
## [b]Nothing at runtime reads an imported asset's source.[/b] Every load follows the
## marker to the imported output, and an exported build carries no sources at all, so a
## game that works exported already works without them. They were most of a pack: the
## reference deathmatch shipped 3.5 MB of `.glb` and 0.5 MB of `.png` beside the
## `.scn` and `.ctex` that were actually loaded -- half its bytes and a quarter of its
## fetches, for files no client ever opened.
##
## Only a source whose marker named an imported output this pack ships is left out; an
## asset imported as "keep" or "skip" has no output and its file IS the asset, so it
## stays. A scene that names the source path still has it rebased onto the mount, because
## the marker is what that path resolves through. Turn this on for content that reads
## its own files raw ([code]Image.load_from_file[/code], [code]GLTFDocument[/code]).
var ship_import_sources: bool = false

## Files the pack carries that are not under the source directory, as
## [code]pack path -> file[/code] (an absolute OS path, or `res://` / `user://`).
##
## [b]For a file a build step derives and the source tree must not be written to.[/b] The
## source of a publish is often somebody's checkout; a derived file written into it for the
## length of a publish is an untracked file in their tree whenever the run is killed.
## dot-server-deploy's packer adds the `requires.json` it derives this way.
##
## Each entry is added exactly like an imported output: hashed, copied into `objects/`,
## listed in the manifest, and path-rewritten if it is a text resource. A pack path that
## the source also has is replaced by the extra file. The exclusions do not apply -- the
## file was named on purpose. A missing file or an unsafe pack path (`..`, absolute)
## fails the publish rather than shipping a pack without it.
##
## [codeblock]
## pub.extra_files = {"requires.json": "/tmp/build/requires.json"}
## [/codeblock]
var extra_files: Dictionary = {}

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

## Also writes every object up to [member bundle_max_object_bytes] into one ZIP and names it in
## the manifest, so a client with an empty cache makes one request for the imported-asset long
## tail instead of one per file. Larger objects stay individual and download in parallel.
@export var write_bundle: bool = true
@export var bundle_max_object_bytes: int = 1048576
## No bundle for fewer small objects than this: a request each is cheaper than the archive.
@export var bundle_min_objects: int = 8

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


## Rewrites `res://X` to `res://<mount_root>/<id>/<version>/<where this pack put X>` for every X this pack
## contains. [param inside] maps a reference's path to its path in the pack (identity except imported outputs).
## Returns the staged path, or "" when nothing changed, so the caller keeps hashing the original.
func _rewrite_paths(abs: String, staged: String, inside: Dictionary) -> DotResult:
	return _Rewrite.rewrite_paths(abs, staged, inside, mount_root, content_id, version)


## Directory of pre-tokenized scripts (API 11): `<dir>/game/x.gdc` stands in for `game/x.gd`.
## Empty (the default) ships the `.gd` text as before.
##
## A script shipped as binary tokens skips the tokenizer when the client compiles it, about
## 40% off loading a 100-script game (2.8 s to 1.7 s headless). Tokens can only be made by
## the engine's exporter (see [code]tools/tokenize_scripts.sh[/code]) and are tied to the
## exact engine version that wrote them, so tokenize with the engine the clients run.
## Each swapped script ships as [code]x.gdc[/code] plus an [code]x.gd.remap[/code] naming it,
## the pair an export makes; a script with no `.gdc` in the directory stays text.
## A [code]engine.txt[/code] in the directory (written by the tool) is compared with the running
## engine; on a mismatch the scripts ship as text, which loads everywhere.
var script_tokens_dir: String = ""

## Marks files optional by path prefix.
var optional_prefixes: PackedStringArray = PackedStringArray()

## Restricts files to platforms by path prefix, as [code]prefix -> [tags][/code].
var platform_rules: Dictionary = {}

## Files only one side of a game fetches, as [code]pattern -> "client" | "server"[/code]
## (API 8), merged with the source's [constant SIDES_FILE]. Written into each entry's
## [member DotCloudFile.side], inside the signed payload.
##
## A pattern ending in [code]/[/code] is a directory prefix; anything else is a
## [method String.match] glob over the pack path, where [code]*[/code] crosses
## [code]/[/code]. An imported asset's marker and its relocated output take the side of the
## source asset, so [code]"textures/hd/"[/code] covers the [code]_imported/[/code] file
## too.
##
## [b]In the source tree rather than in one publisher's config,[/b] because a game is packed
## by more than one tool (this class's CLI, a server's packer, the site's release sync) and
## the source is the one thing all of them read. Refused at publish: a pattern that matches
## nothing (a typo would ship the files to both sides and say nothing), a file two patterns
## put on different sides, a file [member side_needs] says the other side reads, and a
## text resource on one side (or both) that references a file only the other side gets.
var side_rules: Dictionary = {}

## Pack paths a side must have, as [code]path -> "client" | "server" | "both"[/code]; a
## side rule that takes one of them away from a side that needs it is refused at publish
## (API 8). [code]requires.json[/code] and [code]provides.json[/code] are always both and
## [member entry_scene] always client; a packer adds what its own loader opens, such as a
## server's game descriptor and module. Add with [method need_on_side], which merges.
var side_needs: Dictionary = {}


## Says [param side] ("client", "server" or "both") reads [param path]; two different
## sides make it both.
func need_on_side(path: String, side: String) -> void:
	if path == "":
		return
	var held := str(side_needs.get(path, side))
	side_needs[path] = side if held == side else "both"


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
	manifest.dependencies = dependencies.duplicate(true)
	manifest.mirrors = mirrors
	manifest.metadata = metadata

	# The id and version rules are the manifest's alone; a restated copy once refused ids it accepts.
	var shape := manifest.validate_shape()
	if not shape.ok:
		return shape

	var relatives := _collect(source_dir)

	# An imported asset's output lives at the project root, which may be outside the published directory;
	# without it the pack ships `.import` markers pointing at files it does not contain.
	var imported := _imported_outputs_for(source_dir, relatives)
	var extra: Dictionary = imported["files"]
	var remap: Dictionary = imported["remap"]

	# Sources the imported form stands in for. Still in `inside` below, so a scene that
	# names `res://assets/crate.glb` is rebased onto the mount, where its marker is.
	var dropped := {}
	if not ship_import_sources:
		for src: String in imported["sources"]:
			if relatives.has(src) and not extra_files.has(src):
				dropped[src] = true
		if not dropped.is_empty():
			var kept := PackedStringArray()
			for rel in relatives:
				if not dropped.has(rel):
					kept.append(rel)
			relatives = kept

	if script_tokens_dir != "":
		var tokened := _swap_in_script_tokens(out_dir, relatives, extra, dropped)
		if not tokened.ok:
			return tokened
		relatives = tokened.value

	# After the imported outputs, so a file named on purpose wins a collision.
	for named: Variant in extra_files:
		var from := str(extra_files[named])
		var safe_named := DotPaths.safe_relative(str(named))
		if not safe_named.ok:
			return safe_named.wrap("Cannot publish the extra file '%s'." % named)
		if not FileAccess.file_exists(from):
			return DotResult.fail(
				DotError.CODE_IO,
				"An extra file for the pack does not exist.",
				"%s -> %s" % [named, from]
			)
		extra[str(safe_named.value)] = from

	for rel: String in extra:
		if not relatives.has(rel):
			relatives.append(rel)

	if relatives.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No publishable files in the source directory.",
			source_dir
		)

	var provided := _Sides.provides_for(self, source_dir, relatives, extra, dropped)
	if not provided.ok:
		return provided
	manifest.provides = provided.value

	var licence_path := source_dir.path_join(LICENCE_FILE)
	if FileAccess.file_exists(licence_path):
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(licence_path))
		if doc is Dictionary:
			doc = (doc as Dictionary).get("licences")
		if not (doc is Array):
			return DotResult.fail(DotError.CODE_PARSE, "licence.json must be a list of {paths, licence, author, url}, or an object holding one as \"licences\".")
		manifest.licences = doc

	var sided := _Sides.sides_for(self, source_dir, relatives, imported["owners"])
	if not sided.ok:
		return sided
	var sides: Dictionary = sided.value

	# Maps where a reference says a file is to where this pack put it (they differ once an imported
	# output is relocated out of `.godot/`), so a rewrite can tell its own content from the host's.
	var inside := {}
	for rel in relatives:
		inside[rel] = rel
	for src: String in dropped:
		inside[src] = src
	for project_rel: String in remap:
		inside[project_rel] = remap[project_rel]

	var crossed := _check_side_references(relatives, extra, source_dir, inside, sides)
	if not crossed.ok:
		return crossed

	var staging := out_dir.path_join(".rewritten")
	if rewrite_resource_paths:
		DotPaths.remove_tree(staging)

	var stored := _store_files(manifest, relatives, extra, source_dir, inside, sides, objects_dir, staging)
	if not stored.ok:
		return stored
	var written: int = stored.value["written"]
	var deduped: int = stored.value["deduped"]
	var total_bytes: int = stored.value["bytes"]
	var rewritten: int = stored.value["rewritten"]
	var seen: Dictionary = stored.value["seen"]

	var bundled := {}
	if write_bundle:
		var made_bundle := _write_bundle(manifest, out_dir)
		if not made_bundle.ok:
			return made_bundle
		bundled = made_bundle.value
		manifest.bundle = bundled

	# Written verbatim, signed or not, so the bytes a client verifies are the bytes hashed here.
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

	# Staged rewrites are already hashed into objects/; leaving them would double the published size.
	if rewrite_resource_paths:
		DotPaths.remove_tree(staging)
	DotPaths.remove_tree(out_dir.path_join(".tokens"))

	DotLog.info(
		CHANNEL,
		"published",
		{
			"content": manifest.key(),
			"files": manifest.files.size(),
			"objects": seen.size(),
			"deduped": deduped,
			"sources_dropped": dropped.size(),
			"sided": sides.size(),
			"provides": manifest.provides.get("entries", []).size() if not manifest.provides.is_empty() else -1,
			"runs_code": bool(manifest.provides.get("runs_code", false)),
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
		"sources_dropped": dropped.size(),
		"sided": sides.size(),
		"bytes": total_bytes,
		"signed": manifest.signature != "",
	})


## Hashes, rewrites and stores every file; returns {written, deduped, bytes, rewritten, seen}.
func _store_files(manifest: DotCloudManifest, relatives: PackedStringArray, extra: Dictionary, source_dir: String, inside: Dictionary, sides: Dictionary, objects_dir: String, staging: String) -> DotResult:
	var written := 0
	var deduped := 0
	var total_bytes := 0
	var rewritten := 0
	var seen := {}

	for rel in relatives:
		# `extra` entries come from the project root or [member extra_files]; the rest from the source.
		var abs: String = extra.get(rel, source_dir.path_join(rel))

		# A scene names its script by absolute path and the pack mounts elsewhere, so rewrite paths to files
		# this pack contains (not the host build's addons) before hashing, so the manifest covers what mounts.
		if rewrite_resource_paths and _is_text_resource(rel):
			var staged := _rewrite_paths(abs, staging.path_join(rel), inside)
			if not staged.ok:
				return staged.wrap("Could not rewrite paths in '%s'." % rel)
			if str(staged.value) != "":
				abs = str(staged.value)
				rewritten += 1

		var safe := DotPaths.safe_relative(rel)
		if not safe.ok:
			# Refuse rather than skip: a silently missing file surfaces as a missing texture on a player's machine.
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
		entry.side = str(sides.get(rel, DotCloudFile.SIDE_BOTH))

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

		# Objects are named by their hash, so an existing one is already correct.
		if FileAccess.file_exists(dest) and DotPaths.file_size(dest) == size:
			continue

		var copied := _copy(abs, dest)
		if not copied.ok:
			return copied
		written += 1

	return DotResult.success({"written": written, "deduped": deduped, "bytes": total_bytes, "rewritten": rewritten, "seen": seen})


## Writes `bundles/<sha256>.zip` with every unique object at or under the size cap, each entry
## named by its hash. Returns the manifest declaration, or an empty dictionary when too few
## objects qualify. ZIP because every platform the client runs on can read one with ZIPReader.
func _write_bundle(manifest: DotCloudManifest, out_dir: String) -> DotResult:
	var small := {}
	for f in manifest.files:
		if f.size <= bundle_max_object_bytes:
			small[f.sha256] = f.size
	if small.size() < bundle_min_objects:
		return DotResult.success({})

	var tmp := out_dir.path_join("bundles/pending.zip")
	var parent := DotPaths.ensure_parent_dir(tmp)
	if not parent.ok:
		return parent
	var zip := ZIPPacker.new()
	var err := zip.open(tmp)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "creating the bundle"))

	var names := small.keys()
	names.sort()
	for h in names:
		var src := out_dir.path_join("objects/%s/%s" % [str(h).substr(0, 2), h])
		var bytes := FileAccess.get_file_as_bytes(src)
		zip.start_file(str(h))
		zip.write_file(bytes)
		zip.close_file()
	zip.close()

	var hashed := DotHash.sha256_file(tmp)
	if not hashed.ok:
		return hashed
	var digest: String = hashed.value
	var final_rel := "bundles/%s.zip" % digest
	DirAccess.rename_absolute(tmp, out_dir.path_join(final_rel))

	# Older bundles of earlier publishes into this directory are dead weight.
	var dir := DirAccess.open(out_dir.path_join("bundles"))
	if dir != null:
		for n in dir.get_files():
			if n != "%s.zip" % digest:
				dir.remove(n)

	return DotResult.success({
		"sha256": digest,
		"size": DotPaths.file_size(out_dir.path_join(final_rel)),
		"count": names.size(),
		"max_object_bytes": bundle_max_object_bytes,
		"url_path": final_rel,
	})


## The running engine as `godot --version` prints it; `tokenize_scripts.sh` writes it beside the tokens.
static func engine_stamp() -> String:
	var v := Engine.get_version_info()
	return "%d.%d.%d.%s.%s.%s" % [v.major, v.minor, v.patch, v.status, v.build, str(v.hash).substr(0, 9)]


## Replaces each `x.gd` that has `x.gdc` in [member script_tokens_dir] by the token file and
## a staged `x.gd.remap`. The text path goes into [param dropped] so scenes naming it are still
## rebased onto the mount. Returns the remaining relative paths.
func _swap_in_script_tokens(
	out_dir: String, relatives: PackedStringArray, extra: Dictionary, dropped: Dictionary
) -> DotResult:
	var stamp := script_tokens_dir.path_join(TOKENS_ENGINE_FILE)
	if FileAccess.file_exists(stamp):
		var made_by := FileAccess.get_file_as_string(stamp).strip_edges()
		if made_by != engine_stamp():
			DotLog.warn(CHANNEL, "script tokens are from another engine build, shipping text scripts", {"tokens": made_by, "engine": engine_stamp()})
			return DotResult.success(relatives)
	var prefix := "res://%s/%s/%s/" % [mount_root, content_id, version]
	var staging := out_dir.path_join(".tokens")
	DotPaths.remove_tree(staging)
	var kept := PackedStringArray()
	for rel in relatives:
		var tok := script_tokens_dir.path_join(rel + "c")
		if rel.get_extension() != "gd" or extra_files.has(rel) or not FileAccess.file_exists(tok):
			kept.append(rel)
			continue
		var remap_abs := staging.path_join(rel + ".remap")
		var parent := DotPaths.ensure_parent_dir(remap_abs)
		if not parent.ok:
			return parent
		var written := DotPaths.write_text(remap_abs, '[remap]\n\npath="%s%sc"\n' % [prefix, rel])
		if not written.ok:
			return written
		extra[rel + "c"] = tok
		extra[rel + ".remap"] = remap_abs
		dropped[rel] = true
	return DotResult.success(kept)


## Refuses a text resource that references a file its own side will not have: a scene both
## sides load naming a client-only lightmap, or a client-only resource naming a server-only
## one. Godot loads a scene's [code]ext_resource[/code] entries unconditionally, so the
## scene would fail on the side that skipped the file, after a clean publish, fetch and
## mount. Scripts are not scanned: a path in code is loaded when the code decides to, and
## gating that by side is the game's job (a server that never draws never asks for a
## lightmap). An imported asset's side is its marker's.
func _check_side_references(
	relatives: PackedStringArray,
	extra: Dictionary,
	source_dir: String,
	inside: Dictionary,
	sides: Dictionary
) -> DotResult:
	if sides.is_empty():
		return DotResult.success(true)

	for rel in relatives:
		if not _is_text_resource(rel):
			continue
		var own := str(sides.get(rel, DotCloudFile.SIDE_BOTH))
		var abs: String = extra.get(rel, source_dir.path_join(rel))
		for ref in _res_paths_in(FileAccess.get_file_as_string(abs)):
			var path := ref.get_slice("::", 0)
			if not inside.has(path):
				continue
			var target := str(inside[path])
			var theirs := str(sides.get(target, sides.get(target + ".import", DotCloudFile.SIDE_BOTH)))
			if theirs == DotCloudFile.SIDE_BOTH or theirs == own:
				continue
			return DotResult.fail(
				DotError.CODE_INVALID,
				"'%s' references '%s', which only the %s gets." % [rel, target, theirs],
				"%s loads '%s'; put both on one side, or load the %s file from code on that side" % [
					"every side" if own == DotCloudFile.SIDE_BOTH else "the " + own,
					rel, theirs,
				]
			)

	return DotResult.success(true)


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
## Returns `{"files": {pack_rel: absolute}, "remap": {project_rel: pack_rel},
## "sources": {source_rel: true}}` (the assets a shipped output stands in for) — the
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
	var sources := {}
	var owners := {}
	var empty := {"files": out, "remap": remap, "sources": sources, "owners": owners}

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
			sources[rel.trim_suffix(".import")] = true
			owners[landed] = rel.trim_suffix(".import")

	return {"files": out, "remap": remap, "sources": sources, "owners": owners}


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
	return vram_platforms(path) if tag_vram_textures else PackedStringArray()


## Tag a VRAM-compressed texture's per-format output (`.s3tc.ctex`, `.etc2.ctex`, and the `.bptc` / `.astc` ones) with
## the platforms that use it (API 15), so a desktop client does not download the phone copy and the reverse. A
## browser gets both: which format it uses depends on the GPU, which no feature tag says. macOS gets both too
## (Apple GPUs read ETC2/ASTC, Intel ones S3TC). A rule from [member platform_rules] wins.
var tag_vram_textures: bool = true


static func vram_platforms(path: String) -> PackedStringArray:
	if path.ends_with(".s3tc.ctex") or path.ends_with(".bptc.ctex"):
		return PackedStringArray(["windows", "linux", "macos", "web"])
	if path.ends_with(".etc2.ctex") or path.ends_with(".astc.ctex"):
		return PackedStringArray(["android", "ios", "macos", "web"])
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
