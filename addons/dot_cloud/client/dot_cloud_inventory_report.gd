class_name DotCloudInventoryReport
extends RefCounted

## The account site's downloaded-content inventory, from this client's side: turns [method DotCloudStore.inventory] into
## the body of the site's report (`PUT /api/app/v1/content-inventory`, tRPC `clientContent.report`) and carries out the
## actions the site answers with. Transport-free and network-free; the app and the web shell each add their own transport
## ([DotCloudInventoryBridge]'s `sync` op for the shell). Schema: website-city docs/api/content-inventory.md.

const CHANNEL := "cloud.inventory"
## The site refuses a report of more packs than this.
const MAX_PACKS := 2000
const MAX_ID := 160
const MAX_VERSION := 64
const MAX_NAME := 200
const MAX_KIND := 40
const MAX_GAME := 120
const ACTIONS: PackedStringArray = ["delete", "pin", "unpin"]


## The report body for [param inventory] (a [method DotCloudStore.inventory] result) and [param ack]
## (`[{packId, version, action}]`, actions that could never take effect and so must be settled by acknowledgement).
## The list is cut at [constant MAX_PACKS], most recently used first (the order [method DotCloudStore.inventory] gives).
static func body(inventory: Array, ack: Array = []) -> Dictionary:
	var packs: Array = []
	for r in inventory:
		if packs.size() >= MAX_PACKS:
			break
		if not (r is Dictionary):
			continue
		var id := str(r.get("id", ""))
		var version := str(r.get("version", ""))
		if id == "" or version == "" or id.length() > MAX_ID or version.length() > MAX_VERSION:
			continue
		var used := int(r.get("last_used", 0))
		var stamp: Variant = null
		if used > 0:
			stamp = Time.get_datetime_string_from_unix_time(used) + "Z"
		packs.append({
			"packId": id,
			"version": version,
			"name": str(r.get("name", "")).left(MAX_NAME),
			"kind": str(r.get("kind", "")).left(MAX_KIND),
			"game": str(r.get("game", "")).left(MAX_GAME),
			"bytes": maxi(0, int(r.get("bytes", 0))),
			"pinned": bool(r.get("pinned", false)),
			"lastUsed": stamp,
		})
	var acks: Array = []
	for a in ack:
		if acks.size() >= MAX_PACKS:
			break
		if a is Dictionary and ACTIONS.has(str(a.get("action", ""))) and str(a.get("packId", "")) != "":
			acks.append({"packId": str(a["packId"]), "version": str(a.get("version", "")), "action": str(a["action"])})
	return {"packs": packs, "ack": acks}


## Carries out the site's [param pending] (`[{packId, version, action}]`) on [param store] and returns
## `{done, refused, ack}`: counts, plus the actions to acknowledge. A refusal a restart will not cure (the pack is
## unknown here) is acknowledged, or its row would stay pending for ever; one caused by the pack being mounted or
## pinned ([code]CODE_STATE[/code]) is not, so it runs again on the next report. An unknown action is skipped.
## Delete never forces: a pinned pack is refused until the site unpins it. Pin and unpin cover every version of the id.
static func apply_pending(store: DotCloudStore, pending: Array) -> Dictionary:
	var done := 0
	var refused := 0
	var ack: Array = []
	for p in pending:
		if not (p is Dictionary):
			continue
		var action := str(p.get("action", ""))
		var id := str(p.get("packId", ""))
		var version := str(p.get("version", ""))
		if not ACTIONS.has(action) or id == "":
			continue
		var res: DotResult
		match action:
			"delete":
				res = store.delete(id, version)
			"pin":
				res = store.set_pinned(id, true)
			_:
				res = store.set_pinned(id, false)
		if res.ok:
			done += 1
			continue
		refused += 1
		DotLog.warn(CHANNEL, "pending action refused", {"action": action, "pack": id, "code": res.error.code})
		if res.error.code != DotError.CODE_STATE:
			ack.append({"packId": id, "version": version, "action": action})
	return {"done": done, "refused": refused, "ack": ack}
