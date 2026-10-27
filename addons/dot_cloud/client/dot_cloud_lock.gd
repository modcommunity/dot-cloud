class_name DotCloudLock
extends RefCounted

## A repository's `content.lock.json` read the way dot-bootstrap/tools/fetch_lock.sh reads it: which packs to fetch and
## from where. [method DotCloudClient.ensure_locked] mounts the result. Format and rules: docs/cdn-publish.md.

const CHANNEL := "dot_cloud.lock"
const DEFAULT_ORIGIN := "https://dotgames.org/content"

## Parsed `packs` entries that are wanted: {id, version, manifest_sha256, into, kind, optional}.
var packs: Array[Dictionary] = []
## Entries left out, as {id, version, why}.
var skipped: Array[Dictionary] = []
## Where to look, best first: a URL, or a folder holding `<id>/<version>/manifest.json`.
var bases: PackedStringArray = PackedStringArray()
## The lock's folder name, one of the item names `only` / `skip` match.
var repo: String = ""

var _removed: PackedStringArray = PackedStringArray()
var _named: Variant = null


## Reads [param lock_path] (empty list when absent: nothing is pinned). [param opts]: `from`, `cdn`, `cfg` (default `<lock folder>/cfg`),
## `env_file` (default `../dot-bootstrap/.env` beside the lock), `only` and `skip` (Array of ITEM globs), `environment` (a Dictionary that
## stands in for the process environment, for tests).
static func load_file(lock_path: String, opts: Dictionary = {}) -> DotResult:
	var out := DotCloudLock.new()
	if not FileAccess.file_exists(lock_path):
		return DotResult.success(out)
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(lock_path))
	if not (doc is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "%s is not a JSON object." % lock_path)
	if int((doc as Dictionary).get("format", 0)) != 1:
		return DotResult.fail(DotError.CODE_INVALID, "%s: unsupported lock format." % lock_path)
	var dir := _abs(lock_path).get_base_dir()
	out.repo = dir.get_file()
	var cfg := str(opts.get("cfg", dir.path_join("cfg")))
	out._read_cfg(cfg)
	out.bases = resolve_bases(doc, opts, str(opts.get("env_file", dir.get_base_dir().path_join("dot-bootstrap/.env"))))
	var only: Array = opts.get("only", [])
	var skip: Array = opts.get("skip", [])
	for p: Variant in (doc as Dictionary).get("packs", []):
		if not (p is Dictionary) or not (p as Dictionary).has("id") or not (p as Dictionary).has("version"):
			return DotResult.fail(DotError.CODE_INVALID, "%s: a pack entry needs an id and a version." % lock_path)
		var entry: Dictionary = p
		var why := out.why_not(entry, cfg, only, skip)
		if why != "":
			out.skipped.append({"id": entry["id"], "version": entry["version"], "why": why})
		else:
			out.packs.append(entry)
	return DotResult.success(out)


## The CDN precedence of fetch_lock.sh, first set wins: `from` / DOT_PACKS_FROM (`none` fetches nothing), `cdn` / DOT_CDN_URL, the
## env file's DOT_CDN_URL then DOT_PACKS_FROM, the lock's `origin` then `mirrors`, https://dotgames.org. A CDN URL is the site root, so
## "/content" is added unless it ends in it. Empty array for `none`.
static func resolve_bases(doc: Dictionary, opts: Dictionary, env_file: String) -> PackedStringArray:
	var environment: Dictionary = opts.get("environment", {})
	var from := str(opts.get("from", ""))
	if from == "":
		from = _env(environment, "DOT_PACKS_FROM")
	var cdn := str(opts.get("cdn", ""))
	if cdn == "":
		cdn = _env(environment, "DOT_CDN_URL")
	if from == "none":
		return PackedStringArray()
	var file := parse_dotenv(env_file)
	if from == "" and cdn == "":
		cdn = str(file.get("DOT_CDN_URL", ""))
	if from == "" and cdn == "":
		from = str(file.get("DOT_PACKS_FROM", ""))
	if cdn != "" and from == "":
		from = cdn.rstrip("/")
		if from.contains("://") and not from.ends_with("/content"):
			from += "/content"
	if from == "none":
		return PackedStringArray()
	var out := PackedStringArray()
	if from != "":
		out.append(from.rstrip("/") if from.contains("://") else from)
		return out
	out.append(str(doc.get("origin", DEFAULT_ORIGIN)).rstrip("/") if str(doc.get("origin", "")) != "" else DEFAULT_ORIGIN)
	for m: Variant in doc.get("mirrors", []):
		out.append(str(m).rstrip("/"))
	return out


## `KEY=value` lines; `#` comments and surrounding quotes dropped.
static func parse_dotenv(path: String) -> Dictionary:
	var out := {}
	if path == "" or not FileAccess.file_exists(path):
		return out
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var t := line.strip_edges()
		if t == "" or t.begins_with("#") or not t.contains("="):
			continue
		var kv := t.split("=", true, 1)
		out[kv[0].strip_edges()] = kv[1].strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
	return out


## "" when [param p] is wanted, else why not (the wording fetch_lock.sh --list prints).
func why_not(p: Dictionary, cfg: String, only: Array = [], skip: Array = []) -> String:
	if not only.is_empty() and not _hit(p, only):
		return "not in --only"
	if _hit(p, skip):
		return "--skip"
	if _hit(p, Array(_removed)):
		return "removed in cfg/content"
	var half := str(p["id"]).get_slice("/", str(p["id"]).get_slice_count("/") - 1)
	if cfg != "" and FileAccess.file_exists(cfg.path_join("content").path_join(half).path_join("disabled")):
		return "cfg/content/%s/disabled" % half
	if _named != null and str(p.get("kind", "pack")) == "pack":
		var ok := false
		for g: String in _named:
			if str(p["id"]).match(g) or half.match(g):
				ok = true
		if not ok:
			return "not named in cfg/content"
	return ""


## Parses the subset of yml the download lists use: {merge, remove: [[kind, id]], entries: [[kind, id]]}. Entries are bare, `repo:` or
## `pack:` items in flow or block form; `@pin` suffixes are dropped.
static func parse_list(text: String) -> Dictionary:
	var merge := false
	var rem: Array = []
	var ents: Array = []
	var key := ""
	for raw in text.split("\n"):
		var ln: String = raw.split(" #")[0].rstrip(" \t\r")
		var t := ln.strip_edges()
		if t == "" or t.begins_with("#"):
			continue
		if not ln.begins_with(" ") and not ln.begins_with("-") and t.contains(":"):
			var kv := t.split(":", true, 1)
			key = kv[0].strip_edges()
			var v := kv[1].strip_edges()
			if key == "merge":
				merge = v.to_lower() == "true"
			elif (key == "remove" or key == "entries") and v.begins_with("["):
				for x in v.trim_prefix("[").trim_suffix("]").split(","):
					if x.strip_edges() != "":
						(rem if key == "remove" else ents).append(["pack" if x.contains("/") else "repo", _ident(x)])
			continue
		if t.begins_with("- "):
			t = t.substr(2).strip_edges()
		elif t.begins_with("-"):
			t = t.substr(1).strip_edges()
		if t.contains(":"):
			var kv2 := t.split(":", true, 1)
			var k := kv2[0].strip_edges()
			if (k == "repo" or k == "pack") and key == "entries":
				ents.append([k, _ident(kv2[1])])
		elif key == "remove":
			rem.append(["pack" if t.contains("/") else "repo", _ident(t)])
		elif key == "entries":
			ents.append(["pack" if t.contains("/") else "repo", _ident(t)])
	return {"merge": merge, "remove": rem, "entries": ents}


func _read_cfg(cfg: String) -> void:
	if cfg == "":
		return
	for kind in ["addons", "games"]:
		for layer in ["content", "server/content"]:
			var f := cfg.path_join(layer).path_join(kind + ".yml")
			if not FileAccess.file_exists(f):
				continue
			var l := parse_list(FileAccess.get_file_as_string(f))
			for r: Array in l["remove"]:
				_removed.append(r[1])
			var named := PackedStringArray()
			for e: Array in l["entries"]:
				if e[0] == "pack":
					named.append(e[1])
			if not l["merge"] and not named.is_empty():
				_named = named
			elif l["merge"] and not named.is_empty() and _named != null:
				_named = PackedStringArray(Array(_named) + Array(named))


func _hit(p: Dictionary, pats: Array) -> bool:
	var id := str(p["id"])
	var names: Array = [id, id.get_slice("/", id.get_slice_count("/") - 1), str(p.get("into", "")), str(p.get("kind", "pack")), repo]
	for g: Variant in pats:
		for n: String in names:
			if n != "" and n.match(str(g)):
				return true
	return false


static func _ident(v: String) -> String:
	return v.strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'").split("@")[0]


static func _env(environment: Dictionary, key: String) -> String:
	return str(environment[key]) if environment.has(key) else OS.get_environment(key)


static func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path.simplify_path()
