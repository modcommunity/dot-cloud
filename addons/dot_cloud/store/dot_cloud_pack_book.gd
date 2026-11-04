class_name DotCloudPackBook
extends RefCounted

## Which packs the store holds, for the inventory: id, version, kind, game, the objects each needs, last use and whether the player pinned it.
## Objects are shared between packs, so the store alone cannot say what a pack is; this sidecar can. Disposable like the index: losing it loses names, not content.

const CHANNEL := "cloud.store"
const VERSION := 1
const KINDS: PackedStringArray = ["game", "map", "weapon", "workshop"]

## key ("id@version") -> {id, version, kind, game, name, hashes:Array, last_used:int, pinned:bool}
var records: Dictionary = {}

## Games whose packs start pinned ("Keep content downloaded").
var pinned_games: PackedStringArray = PackedStringArray()

var path: String = ""
var dirty: bool = false


func _init(p_path: String) -> void:
	path = p_path


func load_file() -> void:
	records.clear()
	pinned_games = PackedStringArray()
	var res := DotPaths.read_json(path)
	if not res.ok or not (res.value is Dictionary):
		return
	var d := res.value as Dictionary
	if int(d.get("version", 0)) != VERSION or not (d.get("packs") is Dictionary):
		return
	for k in (d["packs"] as Dictionary):
		var e: Variant = d["packs"][k]
		if e is Dictionary and str(e.get("id", "")) != "" and e.get("hashes") is Array:
			records[str(k)] = e
	if d.get("pinned_games") is Array:
		for g in (d["pinned_games"] as Array):
			pinned_games.append(str(g))


func save() -> void:
	if not dirty:
		return
	var written := DotPaths.write_json(path, {"version": VERSION, "packs": records, "pinned_games": Array(pinned_games)}, false)
	if written.ok:
		dirty = false
	else:
		DotLog.warn(CHANNEL, "could not write the pack inventory", {"detail": written.error.detail})


## Notes that [param manifest] is in the store, creating or refreshing its record.
func record(manifest: DotCloudManifest, now: int) -> void:
	var key := manifest.key()
	var kind := str(manifest.metadata.get("kind", "game"))
	var game := str(manifest.metadata.get("game", ""))
	var existing: Dictionary = records.get(key, {})
	records[key] = {
		"id": manifest.content_id,
		"version": manifest.version,
		"kind": kind if kind in KINDS else "game",
		"game": game if game != "" else manifest.content_id,
		"name": manifest.display_name,
		"hashes": Array(manifest.unique_hashes()),
		"last_used": now,
		"pinned": bool(existing.get("pinned", false)) or (game != "" and game in pinned_games),
	}
	dirty = true


func touch(key: String, now: int) -> void:
	if records.has(key):
		records[key]["last_used"] = now
		dirty = true


## Every object hash a pinned pack needs.
func pinned_hashes() -> Dictionary:
	var out := {}
	for k in records:
		if bool(records[k]["pinned"]):
			for h in (records[k]["hashes"] as Array):
				out[str(h)] = true
	return out


func any_pinned() -> bool:
	for k in records:
		if bool(records[k]["pinned"]):
			return true
	return false


## Hashes some record other than those in [param except_keys] still needs.
func hashes_used_outside(except_keys: PackedStringArray) -> Dictionary:
	var out := {}
	for k in records:
		if k in except_keys:
			continue
		for h in (records[k]["hashes"] as Array):
			out[str(h)] = true
	return out


func keys_for_id(id: String, version: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	for k in records:
		if records[k]["id"] == id and (version == "" or records[k]["version"] == version):
			out.append(str(k))
	return out
