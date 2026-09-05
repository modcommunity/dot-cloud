@tool
class_name DotCloudManifest
extends Resource

## The description of one downloadable content set.
##
## A server hands a client a manifest URL; the client fetches this document,
## works out what it is missing, downloads it, verifies it, and mounts it. The
## manifest is therefore the whole trust boundary — everything downstream trusts
## the hashes in here, so the document itself has to be trustworthy. See
## [DotCloudSignature].
##
## [b]The mount prefix is the load-bearing field.[/b] Content mounts at
## [code]res://<mount_root>/<content_id>/<version>/[/code], and that namespacing
## is what makes hot-swapping content possible at all — see [DotCloudMounter] for
## why, and [DotCloudPacker] for the packing side that has to agree with it.

const CHANNEL := "cloud"

## Manifest schema version. Bumped when the wire format changes incompatibly.
const FORMAT_VERSION := 1

## Stable identifier for this content set, e.g. [code]"dm_arena"[/code].
##
## Slug-safe: it becomes a path component. Validated on parse.
@export var content_id: String = ""

## Version of this content. Any string, but semver sorts usefully.
##
## Part of the mount path, so publishing a new version mounts alongside the old
## one rather than trying to replace it in place.
@export var version: String = "0.0.0"

## Human-readable name for progress UI and server listings.
@export var display_name: String = ""

## Where content mounts under [code]res://[/code].
##
## Kept out of the way of a host project's own [code]res://[/code] tree so
## downloaded content can never shadow shipped content — which would otherwise
## be an obvious attack: publish a manifest containing
## [code]scripts/autoload.gd[/code] and wait.
@export var mount_root: String = "dot_cloud"

## Base URLs content is fetched from, tried in order.
##
## Several means failover. The first that responds is preferred for subsequent
## files, so one slow mirror does not halve throughput.
@export var mirrors: PackedStringArray = PackedStringArray()

## Files in this content set.
@export var files: Array[DotCloudFile] = []

## Entry scene, relative to the mount prefix.
##
## What dot-server tells clients to load once content is ready. Empty for
## manifests that are pure assets with no scene of their own.
@export var entry_scene: String = ""

## Minimum Godot version this content needs.
##
## Checked before mounting. A pack built against a newer engine can fail to load
## a scene in ways that look like content corruption, so refusing early with an
## accurate reason is worth the field.
@export var min_engine_version: String = ""

## Free-form metadata passed through untouched, for a host project's own use.
@export var metadata: Dictionary = {}

## Format version the document declared.
var format_version: int = FORMAT_VERSION

## Signature from the enclosing [DotCloudEnvelope]. Empty for unsigned content.
##
## Not an [code]@export[/code] and not part of [method to_dict]: the signature
## lives outside the document it signs, so that verification never has to
## re-serialise. See [DotCloudEnvelope].
var signature: String = ""

## Key id from the enclosing envelope. A hint, not a trusted claim.
var signature_key_id: String = ""

## The exact bytes the signature covers — the envelope's payload.
##
## Signature verification runs over these, never over a re-serialisation of the
## parsed object: any difference in key order, whitespace or number formatting
## would break a signature that is in fact valid.
var raw_bytes: PackedByteArray = PackedByteArray()


# --- Parsing ---------------------------------------------------------------

## Parses a published manifest, signed or not.
##
## Handles the [DotCloudEnvelope] transparently: the single entry point for
## reading a manifest, so no caller can forget to unwrap and end up verifying a
## signature against the envelope instead of the payload.
##
## [member raw_bytes] is set to the [b]payload[/b] bytes — exactly what was
## signed — which is what [method DotCloudClient.verify_manifest] checks.
static func from_json_bytes(bytes: PackedByteArray) -> DotResult:
	var unwrapped := DotCloudEnvelope.unwrap(bytes)
	if not unwrapped.ok:
		return unwrapped

	var env: Dictionary = unwrapped.value
	var payload: PackedByteArray = env["payload"]

	var json := JSON.new()
	var err := json.parse(payload.get_string_from_utf8())
	if err != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The manifest is not valid JSON.",
			"line %d: %s" % [json.get_error_line(), json.get_error_message()]
		)

	if not (json.data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "The manifest must be a JSON object."
		)

	var res := from_dict(json.data as Dictionary)
	if not res.ok:
		return res

	var m := res.value as DotCloudManifest
	m.raw_bytes = payload
	m.signature = str(env["signature"])
	m.signature_key_id = str(env["key_id"])

	return res


static func from_dict(d: Dictionary) -> DotResult:
	var m := DotCloudManifest.new()

	m.format_version = int(d.get("format_version", 1))
	if m.format_version > FORMAT_VERSION:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This manifest needs a newer version of dot-cloud.",
			"manifest format %d, supported up to %d"
				% [m.format_version, FORMAT_VERSION]
		)

	m.content_id = str(d.get("content_id", ""))
	m.version = str(d.get("version", "0.0.0"))
	m.display_name = str(d.get("display_name", ""))
	m.mount_root = str(d.get("mount_root", "dot_cloud"))
	m.entry_scene = str(d.get("entry_scene", ""))
	m.min_engine_version = str(d.get("min_engine_version", ""))
	if d.get("metadata") is Dictionary:
		m.metadata = d["metadata"]

	for u in d.get("mirrors", []):
		m.mirrors.append(str(u))

	var raw_files: Variant = d.get("files", [])
	if not (raw_files is Array):
		return DotResult.fail(
			DotError.CODE_PARSE, "The manifest's 'files' must be an array."
		)

	var seen_paths := {}
	for entry in (raw_files as Array):
		if not (entry is Dictionary):
			return DotResult.fail(
				DotError.CODE_PARSE, "Each manifest file entry must be an object."
			)

		var parsed := DotCloudFile.from_dict(entry as Dictionary)
		if not parsed.ok:
			return parsed

		var f := parsed.value as DotCloudFile

		# Two entries for one path is unresolvable: whichever mounted last would
		# win, and which that is depends on download order. Refuse rather than
		# make the outcome depend on the network.
		if seen_paths.has(f.path):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"The manifest lists '%s' twice." % f.path
			)
		seen_paths[f.path] = true

		m.files.append(f)

	var checked := m.validate()
	if not checked.ok:
		return checked

	return DotResult.success(m)


func validate() -> DotResult:
	if content_id == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "The manifest has no content_id."
		)

	# content_id and version are path components, so they get the same treatment
	# as any other server-supplied path segment.
	var id_slug := DotPaths.slugify(content_id)
	if id_slug != content_id:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"content_id must be lowercase alphanumeric with - or _.",
			"got '%s', expected something like '%s'" % [content_id, id_slug]
		)

	# The version is not slug-checked the way content_id is, because a slug of
	# "1.0.0" is "1_0_0" and requiring equality would refuse every semver ever
	# published. It still lands in the mount prefix verbatim, so it gets the
	# same traversal treatment as any other server-supplied path segment —
	# safe_relative for "..", and a separator check because a version is one
	# path *component*, not a path. Without both, version "../.." validated
	# happily and mount_prefix() came out as "res://", which is precisely the
	# shadowing that mount_root exists to prevent.
	var ver_slug := DotPaths.slugify(version)
	if ver_slug == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "The manifest has no usable version."
		)

	var ver_safe := DotPaths.safe_relative(version)
	if not ver_safe.ok:
		return ver_safe.wrap("The manifest's version is unsafe.")

	if "/" in version or "\\" in version:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The manifest's version must be a single path component.",
			"got '%s'" % version
		)

	var root_safe := DotPaths.safe_relative(mount_root)
	if not root_safe.ok:
		return root_safe.wrap("The manifest's mount_root is unsafe.")

	if entry_scene != "":
		var entry_safe := DotPaths.safe_relative(entry_scene)
		if not entry_safe.ok:
			return entry_safe.wrap("The manifest's entry_scene is unsafe.")

	if min_engine_version != "":
		var need := DotSemVer.parse(min_engine_version)
		if need.valid and DotSemVer.engine().is_older_than(need):
			return DotResult.fail(
				DotError.CODE_VERSION,
				"This content needs Godot %s or newer." % min_engine_version,
				"running %s" % DotSemVer.engine()
			)

	return DotResult.success(true)


# --- Serialisation ---------------------------------------------------------

## The manifest as a plain dictionary.
##
## Carries no signature — that belongs to the [DotCloudEnvelope] wrapping this
## document, precisely so that signing and verifying never depend on how this
## function formats its output.
func to_dict() -> Dictionary:
	var d := {
		"format_version": FORMAT_VERSION,
		"content_id": content_id,
		"version": version,
		"mount_root": mount_root,
		"files": [],
	}

	if display_name != "":
		d["display_name"] = display_name
	if entry_scene != "":
		d["entry_scene"] = entry_scene
	if min_engine_version != "":
		d["min_engine_version"] = min_engine_version
	if not mirrors.is_empty():
		d["mirrors"] = Array(mirrors)
	if not metadata.is_empty():
		d["metadata"] = metadata

	# Sorted by hash so the serialisation is deterministic regardless of the
	# order the publisher walked the source directory. Without this, two
	# publishes of identical content produce different bytes and therefore
	# different signatures, and nothing downstream can cache on the manifest.
	var sorted := files.duplicate()
	sorted.sort_custom(func(a: DotCloudFile, b: DotCloudFile) -> bool:
		return a.sha256 < b.sha256
	)
	for f in sorted:
		d["files"].append(f.to_dict())

	return d


func to_json(pretty: bool = true) -> String:
	return JSON.stringify(to_dict(), "\t" if pretty else "", true, true)


## The bytes to sign, and to write as the envelope payload.
##
## The publisher signs exactly this and stores exactly this; the client verifies
## exactly what it received. No canonicalisation is involved anywhere, which is
## the whole point — see [DotCloudEnvelope].
func payload_bytes() -> PackedByteArray:
	return to_json(true).to_utf8_buffer()


# --- Queries ---------------------------------------------------------------

## Path under [code]res://[/code] where this content mounts.
##
## The version is in the path deliberately. See [DotCloudMounter].
func mount_prefix() -> String:
	return "res://%s/%s/%s" % [mount_root, content_id, version]


## Absolute path of a manifest entry once mounted.
func resource_path(file: DotCloudFile) -> String:
	return mount_prefix().path_join(file.path)


## Absolute path of the entry scene, or [code]""[/code] when there is none.
func entry_scene_path() -> String:
	if entry_scene == "":
		return ""
	return mount_prefix().path_join(entry_scene)


## A stable key for this exact content set, for cache indexes and log lines.
func key() -> String:
	return "%s@%s" % [content_id, version]


## Files this platform wants, filtered by group.
##
## The list the downloader actually works from. Filtering here rather than at
## download time means the progress total is right from the start, instead of a
## bar that shrinks as skipped files are discovered.
func wanted_files(groups: PackedStringArray = PackedStringArray()) -> Array[DotCloudFile]:
	var out: Array[DotCloudFile] = []
	for f in files:
		if not f.wanted_on_this_platform():
			continue
		if not f.in_groups(groups):
			continue
		out.append(f)
	return out


func total_bytes(groups: PackedStringArray = PackedStringArray()) -> int:
	var n := 0
	for f in wanted_files(groups):
		n += f.size
	return n


## Distinct groups mentioned by any file.
func group_names() -> PackedStringArray:
	var seen := {}
	for f in files:
		for g in f.groups:
			seen[g] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## Unique content hashes. Shorter than [member files] when a file appears twice
## under different paths, which deduplication makes free.
func unique_hashes() -> PackedStringArray:
	var seen := {}
	for f in files:
		seen[f.sha256] = true
	return PackedStringArray(seen.keys())


func describe() -> Dictionary:
	return {
		"content_id": content_id,
		"version": version,
		"files": files.size(),
		"unique": unique_hashes().size(),
		"bytes": total_bytes(),
		"mount": mount_prefix(),
		"signed": signature != "",
		"mirrors": mirrors.size(),
		"groups": Array(group_names()),
	}


func _to_string() -> String:
	return "DotCloudManifest(%s, %d files, %s)" % [
		key(), files.size(), DotPaths.format_bytes(total_bytes())
	]
