class_name DotCloudScriptClass
extends RefCounted

## Godot's global class list, rebuilt for scripts the editor never saw.
##
## [b]A `class_name` is only a global if it is in
## `res://.godot/global_script_class_cache.cfg`.[/b] The editor writes that file when it
## imports a project; an exported build carries it; and when a pack is mounted the engine
## re-reads it (`ProjectSettings.load_resource_pack` refreshes the list). So an addon pack
## that brings a class the build does not have -- or moves one -- has to bring the cache
## too, and since the file is ONE list for the whole project, the overlay's copy has to be
## the build's list with that addon's entries swapped. Measured against an exported shell:
## without the file a new class is "not declared in the current scope"; with it, a script
## naming the class as a type compiles.
##
## [b]Nothing here runs the editor.[/b] An entry is seven fields and every one of them is
## on the first lines of the script: `class_name`, `extends`, `@tool`, `@abstract` and
## `@icon`. The examples suite checks this reading against the cache the editor itself
## wrote for every addon in the family, entry for entry, because a `base` that differs
## from the editor's is a type check that differs from the editor's.

## The file the engine reads the list from, in every project and every export.
const CACHE_PATH := "res://.godot/global_script_class_cache.cfg"

## What an entry records about a script's language. Only GDScript is read here.
const LANGUAGE := &"GDScript"


## The class a script declares, or an empty dictionary when it declares none.
##
## Returns `{class, extends, extends_path, is_tool, is_abstract, icon}`; `extends` is the
## name after `extends` and `extends_path` the string when it extends by path. Only the
## script's header is read -- the declarations GDScript allows before the first member --
## and comments, blank lines and `##` docs between them are skipped, as the parser does.
static func read_header(source: String) -> Dictionary:
	var out := {
		"class": "", "extends": "", "extends_path": "",
		"is_tool": false, "is_abstract": false, "icon": "",
	}

	for raw in source.split("\n"):
		var line := raw.strip_edges()

		if line == "" or line.begins_with("#"):
			continue

		# Annotations may share a line with what they annotate (`@tool extends Node`).
		while line.begins_with("@"):
			var taken := _take_annotation(line, out)

			if taken < 0:
				break

			line = line.substr(taken).strip_edges()

		if line == "":
			continue

		if line.begins_with("class_name "):
			var rest := line.substr(11).strip_edges()
			var name := _identifier(rest)
			out["class"] = name
			rest = rest.substr(name.length()).strip_edges()

			# `class_name X extends Y` is one line in GDScript 2.
			if rest.begins_with("extends "):
				_read_extends(rest.substr(8).strip_edges(), out)

			continue

		if line.begins_with("extends "):
			_read_extends(line.substr(8).strip_edges(), out)
			continue

		# The first line that is not a header line ends the header. Everything the
		# cache needs has been said by then -- GDScript refuses `class_name` or
		# `extends` after a member.
		break

	if out["class"] == "":
		return {}

	return out


## The cache entries for [param scripts] (`res://` path -> source), against [param known]
## (class name -> entry) for any base that is a global class declared elsewhere.
##
## Bases are resolved the way the editor resolves them: a global class by its name, an
## engine class by its name, and a script extended by path by that script's own class
## name -- or, when it has none, by whatever IT extends.
static func entries_for(scripts: Dictionary, known: Dictionary = {}) -> Array[Dictionary]:
	var headers := {}

	for path: String in scripts:
		var header := read_header(str(scripts[path]))
		header["path"] = path
		headers[path] = header

	var out: Array[Dictionary] = []

	for path: String in headers:
		var header: Dictionary = headers[path]

		if str(header.get("class", "")) == "":
			continue

		out.append({
			"base": StringName(_base_of(header, headers, 0)),
			"class": StringName(str(header["class"])),
			"icon": str(header["icon"]),
			"is_abstract": bool(header["is_abstract"]),
			"is_tool": bool(header["is_tool"]),
			"language": LANGUAGE,
			"path": path,
		})

	return out


## The build's list, with every entry under [param replaced_dirs] dropped and
## [param added] put in their place. Sorted by class, as the editor writes it.
static func merge(
	base_list: Array, replaced_dirs: PackedStringArray, added: Array[Dictionary]
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var taken := {}

	for entry: Dictionary in added:
		taken[str(entry["class"])] = true
		out.append(entry)

	for entry in base_list:
		if not (entry is Dictionary):
			continue

		var path := str(entry.get("path", ""))
		var dropped := false

		for dir in replaced_dirs:
			if path.begins_with(dir.trim_suffix("/") + "/"):
				dropped = true
				break

		# A class the overlay now declares wins over the build's, wherever the build had
		# it: two entries for one name is the engine picking one at random.
		if dropped or taken.has(str(entry.get("class", ""))):
			continue

		out.append(entry)

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["class"]) < str(b["class"]))

	return out


## The build's own list, read the way the engine reads it.
static func read_cache(path: String = CACHE_PATH) -> Array:
	var cfg := ConfigFile.new()

	if cfg.load(path) != OK:
		return []

	var list: Variant = cfg.get_value("", "list", [])
	return list if list is Array else []


## [param list] as the file the engine reads.
static func cache_text(list: Array[Dictionary]) -> String:
	var cfg := ConfigFile.new()
	cfg.set_value("", "list", list)
	return cfg.encode_to_text()


# --- Internals -----------------------------------------------------------------

static func _base_of(header: Dictionary, headers: Dictionary, depth: int) -> String:
	var named := str(header.get("extends", ""))

	if named != "":
		return named

	var by_path := str(header.get("extends_path", ""))

	if by_path == "":
		# No `extends` at all: GDScript's implicit base.
		return "RefCounted"

	var target := _resolve(by_path, str(header.get("path", "")))
	var parent: Variant = headers.get(target)

	if parent == null or depth > 32:
		# A parent outside the set this was asked about cannot be read from here. The
		# editor would have opened it; the honest fallback is the implicit base, and the
		# family's addons never extend across a pack by path (the suite would say so).
		return "RefCounted"

	if str((parent as Dictionary).get("class", "")) != "":
		return str((parent as Dictionary)["class"])

	return _base_of(parent, headers, depth + 1)


## A path `extends` names, relative to the script it is written in.
static func _resolve(target: String, from: String) -> String:
	if target.begins_with("res://"):
		return target.simplify_path()

	return from.get_base_dir().path_join(target).simplify_path()


static func _read_extends(rest: String, out: Dictionary) -> void:
	if rest.begins_with("\"") or rest.begins_with("'"):
		var quote := rest.substr(0, 1)
		var end := rest.find(quote, 1)

		if end > 0:
			out["extends_path"] = rest.substr(1, end - 1)

		return

	# `extends Foo.Bar` names an inner class; the cache records the outer name's chain the
	# same way, by the first identifier.
	out["extends"] = _identifier(rest)


## Consumes one annotation at the front of [param line] and returns how many characters it
## took, or -1 when the line does not start with a complete one.
static func _take_annotation(line: String, out: Dictionary) -> int:
	var name := _identifier(line.substr(1))
	var end := 1 + name.length()

	if end < line.length() and line[end] == "(":
		var close := line.find(")", end)

		if close < 0:
			return -1

		var argument := line.substr(end + 1, close - end - 1).strip_edges()

		if name == "icon":
			out["icon"] = argument.trim_prefix("\"").trim_suffix("\"") \
				.trim_prefix("'").trim_suffix("'")

		end = close + 1

	match name:
		"tool":
			out["is_tool"] = true
		"abstract":
			out["is_abstract"] = true

	return end


static func _identifier(text: String) -> String:
	var i := 0

	while i < text.length():
		var c := text.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95

		if not ok:
			break

		i += 1

	return text.substr(0, i)
