@tool
class_name DotCloudSourceLocal
extends DotCloudSource

## Fetches content from a directory already on this machine.
##
## Three real uses:
##
## - [b]Development.[/b] Point it at the publisher's output directory and iterate
##   on content without a web server in the loop.
## - [b]LAN play.[/b] A shared folder is a perfectly good content host, and needs
##   no HTTP server.
## - [b]Seeding from the build.[/b] Ship the base game's content inside the
##   export as [code]res://bundled_content/[/code] and a first launch mounts it
##   with no download at all, while updates still come over HTTP.
##
## Works from [code]res://[/code] as well as absolute paths, which is what makes
## the third case possible — including on web, where [code]res://[/code] is inside
## the downloaded WASM bundle.

## Directories searched in order.
##
## Supports [code]res://[/code], [code]user://[/code] and absolute paths.
@export var search_dirs: PackedStringArray = PackedStringArray()

## Subdirectory holding content-addressed objects, mirroring the HTTP layout.
@export var objects_prefix: String = "objects"

## Also look for files by their manifest path, not just by hash.
##
## Lets a source directory be a plain readable tree
## ([code]maps/dm_arena.tscn[/code]) rather than a wall of hashes. Slower — every
## candidate has to be hashed to confirm it is the right file — so it is for
## development, not production.
@export var allow_path_lookup: bool = true


func source_name() -> String:
	return "local"


func is_supported() -> DotResult:
	if search_dirs.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE, "DotCloudSourceLocal has no search_dirs."
		)
	return DotResult.success(true)


func fetch(
	file: DotCloudFile,
	_manifest: DotCloudManifest,
	store: DotCloudStore,
	_scheduler: DotScheduler
) -> DotResult:
	var supported := is_supported()
	if not supported.ok:
		return supported

	var found := _locate(file)
	if found == "":
		note_failure()
		return DotResult.fail(
			DotError.CODE_IO,
			"Content is not in any local source directory.",
			file.path
		)

	var bytes := DotPaths.read_bytes(found)
	if not bytes.ok:
		note_failure()
		return bytes.wrap("Could not read local content '%s'." % found)

	# Routed through put_bytes so the hash is verified here exactly as it is for a
	# download. A local file is not automatically trustworthy — the whole point of
	# the development source is that its contents are being edited.
	var stored := store.put_bytes(bytes.value, file.sha256)
	if not stored.ok:
		note_failure()
		return stored.wrap(
			"Local content '%s' does not match the manifest." % found
		)

	note_success()
	return stored


## Finds a file in the search directories, by hash first and path second.
func _locate(file: DotCloudFile) -> String:
	for dir in search_dirs:
		var root := dir.trim_suffix("/")

		var by_hash := "%s/%s/%s" % [
			root, objects_prefix.trim_suffix("/"), file.object_path()
		]
		if FileAccess.file_exists(by_hash):
			return by_hash

		var flat := "%s/%s" % [root, file.sha256]
		if FileAccess.file_exists(flat):
			return flat

		if allow_path_lookup:
			var by_path := "%s/%s" % [root, file.path]
			if FileAccess.file_exists(by_path):
				return by_path

	return ""


func health() -> Dictionary:
	var d := super.health()
	d["dirs"] = Array(search_dirs)
	return d
