class_name DotCloudSuggested
extends RefCounted

## Content packs a game suggests but never requires (its separate map packs), and the one rule for
## who turns them off.
##
## A game declares entries [code]{group, id, version}[/code] (empty version: the newest published).
## The mode is [code]all[/code], [code]none[/code] or a comma list of groups. Where it comes from,
## strongest first: the command line ([code]--no-suggested-<group>[/code], [code]--suggested=<mode>[/code]),
## this device's override ([method DotCloudWorkshopDevice.suggested_mode]), then
## [member DotCloudWorkshopConfig.workshop_suggested] (defaults, JSON file, environment,
## [code]--cloud-workshop-suggested[/code]). Picking maps one by one is the per-pack device switch.

const MODE_ALL := "all"
const MODE_NONE := "none"


## A declaration for [param ids] of one [param group]; versions are looked up when synced.
static func from_ids(group: String, ids: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in ids:
		out.append({"group": group, "id": id, "version": ""})
	return out


## A declaration from `group=id` strings, as a game.yml lists them; no `group=` means `maps`.
static func from_entries(entries: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in entries:
		var eq := e.find("=")
		var group := "maps" if eq < 0 else e.substr(0, eq)
		out.append({"group": group, "id": e.substr(eq + 1), "version": ""})
	return out


## The mode the command line asks for, or [param fallback] when it asks for nothing.
static func mode_from_args(args: PackedStringArray, groups: PackedStringArray, fallback: String) -> String:
	var mode := fallback
	var off := PackedStringArray()
	for a in args:
		if a == "--no-suggested":
			return MODE_NONE
		if a.begins_with("--suggested="):
			mode = a.substr("--suggested=".length()).strip_edges().to_lower()
		for g in groups:
			if a == "--no-suggested-" + g:
				off.append(g)
	if off.is_empty():
		return mode
	var keep := PackedStringArray()
	for g in groups:
		if not off.has(g) and wants(mode, g):
			keep.append(g)
	return ",".join(keep) if not keep.is_empty() else MODE_NONE


## Whether [param mode] includes [param group].
static func wants(mode: String, group: String) -> bool:
	var m := mode.strip_edges().to_lower()
	if m == MODE_ALL or m == "":
		return true
	if m == MODE_NONE:
		return false
	for g in m.split(","):
		if g.strip_edges() == group:
			return true
	return false


## The entries of [param declared] that [param mode] keeps.
static func select(declared: Array, mode: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in declared:
		if e is Dictionary and str(e.get("id", "")) != "" and wants(mode, str(e.get("group", ""))):
			out.append(e)
	return out


## Every group named in [param declared], sorted.
static func groups_of(declared: Array) -> PackedStringArray:
	var seen := {}
	for e in declared:
		if e is Dictionary:
			seen[str(e.get("group", ""))] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


static func valid_mode(mode: String) -> bool:
	for g in mode.split(","):
		var t := g.strip_edges()
		if t == "" or not (t == MODE_ALL or t == MODE_NONE or t.is_valid_ascii_identifier()):
			return false
	return true
