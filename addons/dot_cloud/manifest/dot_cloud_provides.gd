class_name DotCloudProvides
extends RefCounted

## The `provides` block: what a pack offers a game, parsed and validated.
##
## The author writes `provides.json` at the root of the pack source; [DotCloudPublisher]
## validates it with [method parse] and [method check_files], adds the computed `runs_code`
## and signs it into the manifest. The contract is `docs/workshop.md`.
##
## [b]Two strictness levels, on purpose.[/b] [method parse] with [code]strict = true[/code] is
## the publisher's: a typo is the author's to fix, so it fails. [method normalize] is the
## client's: a pack from a newer writer is the normal case, so unknown kinds, unknown fields
## and a higher schema are all kept, and only what cannot be read at all is dropped. Changes to
## the schema are additive only, so an old reader never misreads a new document.

const SCHEMA := 1

const KINDS: Array[String] = [
	"map", "weapon", "prop", "npc", "entity", "tool", "sound", "script", "addon", "game",
]

## Kinds whose entries are code by definition, whatever the files look like.
const CODE_KINDS: Array[String] = ["entity", "tool", "script"]

## Entry fields that name a file inside the pack. Checked for every entry, any kind, so a
## consumer that adds a kind later gets the same traversal protection for free.
const PATH_FIELDS: Array[String] = ["scene", "def", "thumbnail", "script", "stream"]


## Validates an author's document and returns the normalised block (without `runs_code`).
## Value: the cleaned dictionary.
static func parse(d: Dictionary, strict: bool = true) -> DotResult:
	var out := {"schema": int(d.get("schema", SCHEMA))}
	out["title"] = str(d.get("title", ""))

	var games: Variant = d.get("games", "*")
	if games is Array:
		var list: Array = []
		for g: Variant in (games as Array):
			list.append(str(g))
		out["games"] = list
	else:
		out["games"] = "*"

	var kinds: Array = []
	var raw_kinds: Variant = d.get("kinds", [])
	if raw_kinds is Array:
		for k: Variant in (raw_kinds as Array):
			kinds.append(str(k))
	out["kinds"] = kinds

	var cats: Array = []
	var cat_ids := {}
	var raw_cats: Variant = d.get("categories", [])
	if raw_cats is Array:
		for c: Variant in (raw_cats as Array):
			if not (c is Dictionary) or str((c as Dictionary).get("id", "")) == "":
				if strict:
					return DotResult.fail(DotError.CODE_INVALID, "A category needs an id.")
				continue
			cats.append((c as Dictionary).duplicate(true))
			cat_ids[str((c as Dictionary)["id"])] = true
	out["categories"] = cats

	var entries: Array = []
	var seen := {}
	var raw_entries: Variant = d.get("entries", [])
	if raw_entries is Array:
		for e: Variant in (raw_entries as Array):
			if not (e is Dictionary):
				if strict:
					return DotResult.fail(DotError.CODE_INVALID, "Each entry must be an object.")
				continue
			var ed := e as Dictionary
			var kind := str(ed.get("kind", ""))
			var id := str(ed.get("id", ""))
			if strict:
				var ok := _check_entry(ed, kind, id, cat_ids, seen)
				if not ok.ok:
					return ok
			elif kind == "" or id == "":
				continue
			entries.append(ed.duplicate(true))
			if strict and not kinds.has(kind):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"An entry's kind is missing from 'kinds'.",
					"%s/%s: kinds lists %s" % [kind, id, ", ".join(PackedStringArray(kinds))]
				)
	out["entries"] = entries

	if d.get("accepts") is Dictionary:
		out["accepts"] = (d["accepts"] as Dictionary).duplicate(true)
	return DotResult.success(out)


static func _check_entry(ed: Dictionary, kind: String, id: String, cat_ids: Dictionary, seen: Dictionary) -> DotResult:
	if kind == "" or id == "":
		return DotResult.fail(DotError.CODE_INVALID, "An entry needs a kind and an id.")
	if not _is_id(id):
		return DotResult.fail(
			DotError.CODE_INVALID, "An entry id must be lowercase letters, digits and _.", "'%s'" % id
		)
	var sk := "%s/%s" % [kind, id]
	if seen.has(sk):
		return DotResult.fail(DotError.CODE_INVALID, "Two entries share a kind and id.", sk)
	seen[sk] = true
	var cat := str(ed.get("category", ""))
	if cat != "" and not cat_ids.has(cat):
		return DotResult.fail(DotError.CODE_INVALID, "An entry names an unknown category.", "%s: '%s'" % [sk, cat])
	for f in PATH_FIELDS:
		if ed.has(f):
			var safe := safe_pack_path(ed[f])
			if not safe.ok:
				return safe.wrap("Entry %s field '%s'." % [sk, f])
	if kind == "addon" and ed.has("dir"):
		var safe_dir := safe_pack_path(ed["dir"])
		if not safe_dir.ok:
			return safe_dir.wrap("Entry %s field 'dir'." % sk)
	return DotResult.success(true)


static func _is_id(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		var good := (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95
		if not good:
			return false
	return true


## A path inside the pack: relative, no `..`, not a `res://` or other scheme.
static func safe_pack_path(v: Variant) -> DotResult:
	if not (v is String) or (v as String) == "":
		return DotResult.fail(DotError.CODE_INVALID, "A path must be a non-empty string.")
	var p := v as String
	if p.contains("://") or p.begins_with("/") or p.contains(":"):
		return DotResult.fail(DotError.CODE_INVALID, "A pack path must be relative to the pack.", p)
	return DotPaths.safe_relative(p)


## Every path an entry or category names, as pack-relative strings.
static func paths_in(provides: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for e: Variant in provides.get("entries", []):
		if not (e is Dictionary):
			continue
		for f in PATH_FIELDS:
			if (e as Dictionary).has(f):
				out.append(str((e as Dictionary)[f]))
	for c: Variant in provides.get("categories", []):
		if c is Dictionary and (c as Dictionary).has("icon"):
			out.append(str((c as Dictionary)["icon"]))
	return out


## Publish-time: every named file is in the pack. [param exists] is a Callable taking a
## pack-relative path and returning bool (the publisher answers for shipped files and for the
## sources of imported assets); [param dir_exists] does the same for an addon's `dir`.
static func check_files(provides: Dictionary, exists: Callable, dir_exists: Callable) -> DotResult:
	for p in paths_in(provides):
		var safe := safe_pack_path(p)
		if not safe.ok:
			return safe.wrap("provides names a bad path.")
		if not bool(exists.call(p)):
			return DotResult.fail(
				DotError.CODE_INVALID, "provides names a file the pack does not ship.", p
			)
	for e: Variant in provides.get("entries", []):
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "addon":
			var dir := str((e as Dictionary).get("dir", ""))
			var safe_dir := safe_pack_path(dir)
			if not safe_dir.ok:
				return safe_dir.wrap("An addon entry needs a dir.")
			if not bool(dir_exists.call(dir)):
				return DotResult.fail(DotError.CODE_INVALID, "An addon entry names a directory the pack does not ship.", dir)
	return DotResult.success(true)


## True when any entry's kind always runs code.
static func has_code_kind(provides: Dictionary) -> bool:
	for e: Variant in provides.get("entries", []):
		if e is Dictionary and CODE_KINDS.has(str((e as Dictionary).get("kind", ""))):
			return true
	return false


## Whether the block asks for the process root: an `addon` entry, or a pack file that is an
## addon's `plugin.cfg`. [param file_paths] are the manifest's paths.
static func is_root_overlay(provides: Dictionary, file_paths: PackedStringArray) -> bool:
	for e: Variant in provides.get("entries", []):
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "addon":
			return true
	for p in file_paths:
		if p.begins_with("addons/") and p.ends_with("/plugin.cfg"):
			return true
	return false


## The client's reader: tolerant of everything a newer writer may add.
static func normalize(d: Dictionary) -> Dictionary:
	var r := parse(d, false)
	var out: Dictionary = r.value if r.ok else {}
	if d.has("runs_code"):
		out["runs_code"] = bool(d["runs_code"])
	return out
