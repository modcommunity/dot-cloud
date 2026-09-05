@tool
class_name DotCloudFile
extends Resource

## One downloadable file in a [DotCloudManifest].
##
## Content-addressed: the SHA-256 is the file's identity in the cache, and
## [member path] is only where it goes once mounted. Two games shipping the same
## 40 MB texture pack therefore download it once, and a re-published game whose
## textures did not change re-downloads nothing.

## Where this file lives inside the mounted content, relative to the manifest's
## mount prefix. Always validated with [method DotPaths.safe_relative] before use
## — it comes from a server.
@export var path: String = ""

## Lowercase hex SHA-256 of the file's bytes. The cache key.
@export var sha256: String = ""

@export var size: int = 0

## Optional groups this file belongs to.
##
## Lets a client fetch a subset: [code]"core"[/code] before spawning,
## [code]"hd_textures"[/code] in the background afterwards. A file in no group is
## always required.
@export var groups: PackedStringArray = PackedStringArray()

## Platform feature tags this file is for. Empty means every platform.
##
## Matched against [method OS.has_feature], so [code]"web"[/code],
## [code]"android"[/code], [code]"mobile"[/code] all work. The point is not to
## download a 300 MB desktop texture set onto a phone that will never mount it.
@export var platforms: PackedStringArray = PackedStringArray()

## When false, a failure to fetch this file is logged and tolerated.
##
## For content that improves the experience without gating it — a music pack, a
## localisation. Everything needed to enter the game must stay required.
@export var required: bool = true

## Per-file override for where to fetch it, appended to a mirror base URL.
##
## Empty means [member sha256] is used to build a content-addressed URL, which is
## what a CDN wants: immutable paths cache forever. Set this when serving content
## from a directory laid out by name instead.
@export var url_path: String = ""


static func from_dict(d: Dictionary) -> DotResult:
	var f := DotCloudFile.new()

	f.path = str(d.get("path", ""))
	f.sha256 = str(d.get("sha256", "")).to_lower()
	f.size = int(d.get("size", 0))
	f.required = bool(d.get("required", true))
	f.url_path = str(d.get("url_path", ""))

	for g in d.get("groups", []):
		f.groups.append(str(g))
	for p in d.get("platforms", []):
		f.platforms.append(str(p))

	var checked := f.validate()
	if not checked.ok:
		return checked

	return DotResult.success(f)


func to_dict() -> Dictionary:
	var d := {
		"path": path,
		"sha256": sha256,
		"size": size,
	}
	# Defaults are omitted so a manifest for 900 files does not carry 900 copies
	# of `"required": true`; over a real content set that is a measurable
	# fraction of the manifest's size.
	if not required:
		d["required"] = false
	if not groups.is_empty():
		d["groups"] = Array(groups)
	if not platforms.is_empty():
		d["platforms"] = Array(platforms)
	if url_path != "":
		d["url_path"] = url_path
	return d


## Checks everything a hostile or broken manifest could get wrong.
##
## Called on every entry at parse time, before anything is fetched. A manifest
## with one bad entry is refused whole: partially trusting a document that is
## demonstrably wrong about itself is how a traversal gets through.
func validate() -> DotResult:
	var safe := DotPaths.safe_relative(path)
	if not safe.ok:
		return safe.wrap("Manifest entry has an unsafe path.")
	path = safe.value

	if sha256.length() != 64 or not sha256.is_valid_hex_number(false):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Manifest entry has a malformed SHA-256.",
			"%s: '%s'" % [path, sha256]
		)

	if size < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Manifest entry has a negative size.",
			path
		)

	if url_path != "":
		var safe_url := DotPaths.safe_relative(url_path)
		if not safe_url.ok:
			return safe_url.wrap("Manifest entry has an unsafe url_path.")

	return DotResult.success(true)


## Whether this file should be fetched on the current platform.
func wanted_on_this_platform() -> bool:
	if platforms.is_empty():
		return true
	for tag in platforms:
		if OS.has_feature(tag):
			return true
	return false


## Whether this file is in any of [param selected] groups.
##
## An ungrouped file is always wanted — treating "no group" as "no group
## selected it" would make the common manifest fetch nothing.
func in_groups(selected: PackedStringArray) -> bool:
	if groups.is_empty():
		return true
	for g in groups:
		if selected.has(g):
			return true
	return false


## The cache-relative object path for this file's content.
##
## Sharded by the first two hex characters: a flat directory with 50,000 entries
## is slow to enumerate on every filesystem in the target set, and on some of
## them slow to open a single file in.
func object_path() -> String:
	return "%s/%s" % [sha256.substr(0, 2), sha256]


func _to_string() -> String:
	return "DotCloudFile(%s, %s, %s)" % [
		path, sha256.substr(0, 12), DotPaths.format_bytes(size)
	]
