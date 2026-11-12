extends RefCounted

## The inventory half of [DotCloudStore] (what packs it holds, pinning, deleting, the quota report), in a file of its own so the store stays
## inside the size budget. Nothing here is used on its own.

const CHANNEL := "cloud.store"


static func inventory(s: DotCloudStore) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var gone: Array = []
	for k in s.packs.records:
		var r: Dictionary = s.packs.records[k]
		var bytes := 0
		var present := 0
		for h in (r["hashes"] as Array):
			if s._index.has(h):
				bytes += int(s._index[h]["size"])
				present += 1
		if present == 0 and not (r["hashes"] as Array).is_empty():
			gone.append(k)
			continue
		out.append({
			"id": r["id"], "version": r["version"], "kind": r["kind"], "game": r["game"], "name": r["name"],
			"bytes": bytes, "last_used": int(r["last_used"]), "pinned": bool(r["pinned"]),
			"platform": "web" if DotPlatform.is_web() else "app",
		})
	for k in gone:
		s.packs.records.erase(k)
		s.packs.dirty = true
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["last_used"]) > int(b["last_used"]))
	return out


static func set_pinned(s: DotCloudStore, id: String, pinned: bool) -> DotResult:
	var keys := s.packs.keys_for_id(id)
	if keys.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No downloaded content with that id.", id)
	for k in keys:
		s.packs.records[k]["pinned"] = pinned
	s.packs.dirty = true
	s.flush_index()
	if pinned:
		s._request_persist()
	DotLog.info(CHANNEL, "pin changed", {"id": id, "pinned": pinned})
	return DotResult.success(keys.size())


static func set_game_pinned(s: DotCloudStore, game: String, pinned: bool) -> DotResult:
	if pinned and game.length() > DotCloudPackBook.MAX_GAME_ID:
		return DotResult.fail(DotError.CODE_INVALID, "Game id too long.")
	if pinned and s.packs.pinned_games.size() >= DotCloudPackBook.MAX_PINNED_GAMES and not s.packs.pinned_games.has(game):
		return DotResult.fail(DotError.CODE_INVALID, "Too many pinned games.")
	var n := 0
	for k in s.packs.records:
		if s.packs.records[k]["game"] == game:
			s.packs.records[k]["pinned"] = pinned
			n += 1
	var at := s.packs.pinned_games.find(game)
	if pinned and at < 0:
		s.packs.pinned_games.append(game)
	elif not pinned and at >= 0:
		s.packs.pinned_games.remove_at(at)
	s.packs.dirty = true
	s.flush_index()
	if pinned:
		s._request_persist()
	return DotResult.success(n)


static func delete(s: DotCloudStore, id: String, version: String = "", force: bool = false) -> DotResult:
	var keys := s.packs.keys_for_id(id, version)
	if keys.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No downloaded content with that id.", id)
	for k in keys:
		if not force and bool(s.packs.records[k].get("pinned", false)):
			return DotResult.fail(DotError.CODE_STATE, "That content is pinned; unpin it or force the delete.", k)
		if s.in_use_fn.is_valid() and bool(s.in_use_fn.call(k)):
			return DotResult.fail(DotError.CODE_STATE, "That content is in use; restart to delete it.", k)

	var shared := s.packs.hashes_used_outside(keys)
	var freed := 0
	for k in keys:
		for h in (s.packs.records[k]["hashes"] as Array):
			if shared.has(h) or not s._index.has(h):
				continue
			var size := int(s._index[h]["size"])
			if DirAccess.remove_absolute(s.path_for(h)) != OK and FileAccess.file_exists(s.path_for(h)):
				DotLog.warn(CHANNEL, "could not delete object", {"hash": str(h).substr(0, 12)})
				continue
			s._forget(h)
			freed += size
		s.release_refs(k)
		s.packs.records.erase(k)
	s.packs.dirty = true
	DotWeb.sync_filesystem()
	s.flush_index()
	DotLog.info(CHANNEL, "deleted content", {"id": id, "freed": DotPaths.format_bytes(freed)})
	return DotResult.success(freed)


static func quota_report(s: DotCloudStore) -> Dictionary:
	var free := await s.free_bytes()
	var quota := -1
	var usage := -1
	if DotPlatform.is_web():
		var est := await DotWeb.estimate_storage()
		if est.ok:
			quota = int((est.value as Dictionary).get("quota", -1))
			usage = int((est.value as Dictionary).get("usage", -1))
	var cause := ""
	if free < 0:
		cause = "unreadable"
	elif quota > 0 and (free < quota / 20 or free < 100 * 1024 * 1024):
		cause = "partitioned" if s._is_embedded() else "near-full"
	elif quota <= 0 and free < 100 * 1024 * 1024:
		cause = "partitioned" if s._is_embedded() else "near-full"
	return {"free": free, "quota": quota, "usage": usage, "quota_cause": cause}


static func clear_unpinned(s: DotCloudStore) -> DotResult:
	var freed := 0
	var ids := {}
	for k in s.packs.records.keys():
		var r: Dictionary = s.packs.records[k]
		if not bool(r["pinned"]) and not (s.in_use_fn.is_valid() and bool(s.in_use_fn.call(k))):
			ids[k] = r
	for k in ids:
		var done := s.delete(ids[k]["id"], ids[k]["version"])
		if done.ok:
			freed += int(done.value)
	return DotResult.success(freed)
