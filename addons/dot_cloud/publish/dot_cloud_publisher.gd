class_name DotCloudPublisher
extends RefCounted

## Turns a directory of content into a manifest plus a content-addressed object tree, ready to serve over HTTP.
## The layout is what [DotCloudSourceHttp] expects, so the target is a static directory behind any CDN:
## [codeblock]
## <out>/manifest.json              the signed manifest
## <out>/objects/<aa>/<full-hash>   one file per unique content hash
## <out>/bundles/<hash>.zip         the small objects in one archive (see [member write_bundle])
## [/codeblock]
## Paths are immutable, so a CDN caches them forever and a republish with one changed texture uploads one object.
## [codeblock]
## var pub := DotCloudPublisher.new()
## pub.content_id = "dm_arena"
## pub.version = "1.2.0"
## pub.signing_key_pem = FileAccess.get_file_as_string("res://keys/content.key")
## var res := pub.publish("res://content/dm_arena", "user://published/dm_arena")
## [/codeblock]

const CHANNEL := "cloud.pub"
const _Sides := preload("dot_cloud_publisher_sides.gd")
const _Groups := preload("dot_cloud_publisher_groups.gd")
const _Rewrite := preload("dot_cloud_publisher_rewrite.gd")
const _Finish := preload("dot_cloud_publisher_finish.gd")
const TOKENS_ENGINE_FILE := "engine.txt"

## The file at the source root that says what the pack offers a game.
const PROVIDES_FILE := "provides.json"
const LICENCE_FILE := "licence.json"

## The file at the source root that says which files only one side fetches (API 8):
## [code]{"client": ["lightmaps/"], "server": ["server/*.json"]}[/code]. See [member side_rules].
const SIDES_FILE := "sides.json"

## The file at the source root that puts files in download groups, read next to [constant SIDES_FILE] and
## merged with [member group_rules]: [code]{"course_a": ["worlds/course_a.*"]}[/code] or
## [code]{"worlds/course_a.*": "course_a"}[/code]. A pattern matching nothing is refused.
const GROUPS_FILE := "groups.json"

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

## Private key PEM. Leave empty to publish unsigned (local development; a default client refuses it).
var signing_key_pem: String = ""

var signing_key_id: String = "default"

## Passed through to the manifest untouched, for a host project's own use.
var metadata: Dictionary = {}

## Glob-ish suffixes never included (import sidecars and editor droppings).
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

## Top-level folders of the source skipped entirely: `examples/` holds editor-only suites and demos, whose scripts do not parse in a web export (they name classes a shell lacks) and which no game scene loads.
## The same holds for the folders every game repository keeps beside its content and nothing loads at runtime:
## tests, tools, docs, CI, review `reports/` and `screenshots/` (PNG sheets, megabytes each) and `art-src/`
## (editable art sources). Games used to list these one by one in their publish.sh and most missed some
## (prop-hunt shipped 9.4 MB of report PNGs, smash-copter 5 MB). A pack that does load one of them
## from `res://` sets this array without it.
var exclude_roots: PackedStringArray = PackedStringArray([
	"examples", "tests", "tools", "docs", "ci", ".github", "screenshots", "reports", "art-src",
])

## Where an imported output lives inside a pack, instead of `.godot/imported/` as in the project.
## A web export cannot read files under the engine's reserved `.godot` name, though Linux can, so a
## headless mount check passes while the game fails on the web.
## A `.import` marker names its output by absolute path, so the output can live anywhere;
## [method _rewrite_paths] moves both together.
const IMPORTED_DIR := "_imported"

## Ship the engine's imported form of assets that have one (.glb, .png...).
## Nothing imports at runtime and every load of a source path is redirected through its `.import` marker,
## so a pack of bare sources has bytes no [method @GDScript.load] can open, and nothing reports a missing file.
## With this on, markers and [code].godot/imported/[/code] come too, and the rewrite moves the three absolute
## paths in each marker onto the mount. The [code].md5[/code] companions stay behind (editor-only).
## Costs about the size of the meshes again; turn it off for a pack of only scenes and scripts.
var include_imported: bool = true

## Ship the source file beside its imported form ([code]tile.png[/code] next to its [code].import[/code]). Off by default.
## Nothing at runtime reads an imported asset's source, and sources were half the bytes of the reference pack.
## Only a source whose marker names a shipped output is left out; "keep"/"skip" assets ARE their file and stay.
## Turn on for content that reads its own files raw ([code]Image.load_from_file[/code], [code]GLTFDocument[/code]).
var ship_import_sources: bool = false

## Files the pack carries that are not under the source directory, as [code]pack path -> file[/code]
## (absolute OS path, `res://` or `user://`).
## For a file a build step derives, so the publish never writes into somebody's checkout.
## Added like an imported output (hashed, listed, path-rewritten if text); replaces a source file at the
## same pack path; exclusions do not apply. A missing file or unsafe pack path fails the publish.
## [codeblock]
## pub.extra_files = {"requires.json": "/tmp/build/requires.json"}
## [/codeblock]
var extra_files: Dictionary = {}

## Assigns groups to files by path prefix, as [code]prefix -> group[/code] (e.g. `"hd/"` as an optional download).
var group_rules: Dictionary = {}

## Rewrite `res://` references inside .tscn / .tres to the mount prefix.
## On by default: scenes naming their authored paths mount, then cannot find their own scripts.
@export var rewrite_resource_paths: bool = true

## Also writes every object up to [member bundle_max_object_bytes] into one ZIP and names it in
## the manifest, so a client with an empty cache makes one request for the imported-asset long
## tail instead of one per file. Larger objects stay individual and download in parallel.
@export var write_bundle: bool = true
@export var bundle_max_object_bytes: int = 1048576
## No bundle for fewer small objects than this: a request each is cheaper than the archive.
@export var bundle_min_objects: int = 8

## Text resources whose `res://` references have to move with the pack.
## .tscn and .tres only: a binary .scn or .res cannot be rewritten by string substitution.
## .import too, which is what makes [member include_imported] work: its three absolute paths
## name the authoring project and are rewritten to the mount like any reference.
static func _is_text_resource(rel: String) -> bool:
	var e := rel.get_extension().to_lower()
	return e == "tscn" or e == "tres" or e == "import"


## Rewrites `res://X` to `res://<mount_root>/<id>/<version>/<where this pack put X>` for every X this pack
## contains. [param inside] maps a reference's path to its path in the pack (identity except imported outputs).
## Returns the staged path, or "" when nothing changed, so the caller keeps hashing the original.
func _rewrite_paths(abs: String, staged: String, inside: Dictionary) -> DotResult:
	return _Rewrite.rewrite_paths(abs, staged, inside, mount_root, content_id, version)


## Directory of pre-tokenized scripts (API 11): `<dir>/game/x.gdc` stands in for `game/x.gd`. Empty ships `.gd` text.
## Tokens skip the tokenizer on the client (about 40% off loading 100 scripts) but are tied to the exact
## engine version that wrote them (see [code]tools/tokenize_scripts.sh[/code]). Each swapped script ships as
## `x.gdc` plus an `x.gd.remap`; a script with no `.gdc` stays text.
## An `engine.txt` in the directory is compared with the running engine; on a mismatch scripts ship as text.
var script_tokens_dir: String = ""

## Marks files optional by path prefix.
var optional_prefixes: PackedStringArray = PackedStringArray()

## Restricts files to platforms by path prefix, as [code]prefix -> [tags][/code].
var platform_rules: Dictionary = {}

## Files only one side of a game fetches, as [code]pattern -> "client" | "server"[/code] (API 8), merged
## with the source's [constant SIDES_FILE] and written into [member DotCloudFile.side] inside the signed payload.
## A pattern ending in `/` is a directory prefix; any other is a [method String.match] glob over the pack path.
## An imported asset's marker and relocated output take its source's side.
## Lives in the source tree because several tools pack a game and all read the source.
## Refused: a pattern matching nothing (a typo would ship to both sides silently), a file on two sides,
## a file [member side_needs] says the other side reads, and a text resource referencing a file only the other side gets.
var side_rules: Dictionary = {}

## Pack paths a side must have, as [code]path -> "client" | "server" | "both"[/code]; a side rule removing one
## from a side that needs it is refused at publish (API 8).
## `requires.json` and `provides.json` are always both and [member entry_scene] client; add with [method need_on_side].
var side_needs: Dictionary = {}


## Says [param side] ("client", "server" or "both") reads [param path]; two different
## sides make it both.
func need_on_side(path: String, side: String) -> void:
	if path == "":
		return
	var held := str(side_needs.get(path, side))
	side_needs[path] = side if held == side else "both"


## Builds a manifest and object tree from [param source_dir] into [param out_dir].
## Synchronous: for a build step or CLI, not a frame; [method DotHash.sha256_file] blocks.
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
	var missing: PackedStringArray = imported["missing"]
	if not missing.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, (
			"%d .import marker(s) name an output the project has not imported (first: %s); "
			+ "run `godot --headless --path <project> --import` before publishing"
		) % [missing.size(), ", ".join(missing.slice(0, 3))])
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
	var added := _Finish.add_extra_files(extra, extra_files)
	if not added.ok:
		return added

	for rel: String in extra:
		if not relatives.has(rel):
			relatives.append(rel)

	if relatives.is_empty() and dependencies.is_empty():
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
	var signed_doc := _Finish.signed_document(manifest, signing_key_pem, signing_key_id)
	if not signed_doc.ok:
		return signed_doc
	var document: PackedByteArray = signed_doc.value

	var manifest_path := out_dir.path_join("manifest.json")
	var saved := DotPaths.write_bytes(manifest_path, document)
	if not saved.ok:
		return saved

	# Staged rewrites are already hashed into objects/; leaving them would double the published size.
	if rewrite_resource_paths:
		DotPaths.remove_tree(staging)
	DotPaths.remove_tree(out_dir.path_join(".tokens"))

	_Finish.log_published(manifest, out_dir, {
		"objects": seen.size(), "deduped": deduped, "dropped": dropped.size(), "sided": sides.size(),
		"written": written, "bytes": total_bytes, "rewritten": rewritten,
	})

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
	var file_groups := _Groups.groups_for(self, source_dir, relatives)
	if not file_groups.ok:
		return file_groups

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
		entry.groups = _groups_for(entry.path, file_groups.value.get(rel, PackedStringArray()))
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


## Refuses a text resource that references a file its own side will not have (a scene both sides load naming a
## client-only lightmap): Godot loads `ext_resource` entries unconditionally, so it would fail after a clean mount.
## Scripts are not scanned; a path in code is loaded when the code decides to, and gating that is the game's job.
## An imported asset's side is its marker's.
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
	# Outside a project there is no `.godot/imported/` to take outputs from, so a marker would name a file
	# the pack lacks and every load of its source would fail; the raw source ships instead.
	var keep_markers := include_imported and _project_root_of(source_dir) != ""

	for rel in DotPaths.list_files_recursive(source_dir):
		# The engine's imported form and its markers are decided before the exclusions, because `.godot` (excluded dir)
		# and `.import` (excluded suffix) would drop them. An output is kept from any directory; a MARKER is not,
		# since its directory is the asset's own and keeping one for a file not shipped drags in its textures.
		# Never from the walk: outputs reach a pack only through `_imported_outputs_for`, which also rewrites the marker.
		if rel.begins_with(".godot/"):
			continue

		var skip := false

		for dir_name in exclude_dirs:
			if rel.begins_with(dir_name + "/") or rel.contains("/" + dir_name + "/"):
				skip = true
				break

		for root in exclude_roots:
			if rel.begins_with(root + "/"):
				skip = true
				break

		if skip:
			continue

		# The suffix rules below would drop a marker; decided here, after the directory rules, because
		# `.import` is excluded for packs of only scenes and scripts.
		if keep_markers and rel.ends_with(".import"):
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
## Returns `{"files": {pack_rel: absolute}, "remap": {project_rel: pack_rel}, "sources": {source_rel: true}}`;
## the remap lets [method _rewrite_paths] send a marker to [constant IMPORTED_DIR], where the output landed.
## Empty only when the source is not inside a Godot project.
## Resolved from the markers, not by listing `.godot/imported/`, because that directory holds an output
## for every asset ever imported. [method DotPaths.list_files_recursive] skips hidden entries, so `_collect`
## never finds `.godot`, and a pack from a project root would otherwise carry markers without their `.ctex`.
func _imported_outputs_for(
	source_dir: String, relatives: PackedStringArray
) -> Dictionary:
	var out := {}
	var remap := {}
	var sources := {}
	var owners := {}
	var missing := PackedStringArray()
	var empty := {"files": out, "remap": remap, "sources": sources, "owners": owners, "missing": missing}

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
			# Skipping it would ship a marker naming a file the pack lacks: an asset that never loads.
			if not FileAccess.file_exists(root.path_join(hit)):
				missing.append("%s -> %s" % [rel, hit])
				continue
			var landed := "%s/%s" % [IMPORTED_DIR, hit.get_file()]
			out[landed] = root.path_join(hit)
			remap[hit] = landed
			sources[rel.trim_suffix(".import")] = true
			owners[landed] = rel.trim_suffix(".import")

	return {"files": out, "remap": remap, "sources": sources, "owners": owners, "missing": missing}


## Every `res://…` path in a text blob, as paths relative to the project root.
func _res_paths_in(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0

	while true:
		var at := text.find("res://", i)
		if at < 0:
			break

		# A quoted path may hold spaces and commas ("color_golden yellow.png"): it ends at its quote.
		var quote := text[at - 1] if at > 0 and text[at - 1] in ['"', "'"] else ""
		var j := at + 6
		while j < text.length():
			var c := text[j]
			if c in ["\n", "\r", "\t"] or (quote != "" and c == quote):
				break
			if quote == "" and c in ['"', "'", " ", ",", "]", ")"]:
				break
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


func _groups_for(path: String, from_file: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out := PackedStringArray()
	for prefix in group_rules:
		if path.begins_with(str(prefix)):
			out.append(str(group_rules[prefix]))
	for g in from_file:
		if not out.has(g):
			out.append(g)
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


## Tag a VRAM-compressed texture's per-format output (`.s3tc.ctex`, `.etc2.ctex`, `.bptc`, `.astc`, and dot-map's baked `.s3tc.res`/`.etc2.res`) with
## the platforms that use it (API 15), so a desktop client does not download the phone copy.
## A browser and macOS get both, since the format depends on the GPU. A rule from [member platform_rules] wins.
var tag_vram_textures: bool = true


static func vram_platforms(path: String) -> PackedStringArray:
	if path.ends_with(".s3tc.ctex") or path.ends_with(".bptc.ctex") or path.ends_with(".s3tc.res"):
		return PackedStringArray(["windows", "linux", "macos", "web"])
	if path.ends_with(".etc2.ctex") or path.ends_with(".astc.ctex") or path.ends_with(".etc2.res"):
		return PackedStringArray(["android", "ios", "macos", "web"])
	return PackedStringArray()


## Generates a signing keypair and writes both halves.
## The private half gets default permissions, not enough for a key that authorises code on every player's
## machine: move it into a secrets manager and delete the file.
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
