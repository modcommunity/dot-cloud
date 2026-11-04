class_name DotCloudInventoryBridge
extends RefCounted

## Answers an embedding page's requests about downloaded content. Transport-free: [method handle] takes a decoded message and the sender's origin, so the web shell feeds it postMessage events and tests feed it dictionaries.
## Schema: dot-server-deploy docs/web-inventory-bridge.md.

const CHANNEL := "cloud.inventory"
const PROTOCOL := "dot-inventory"
const VERSION := 1
const OPS: PackedStringArray = ["list", "quota", "pin", "pin_game", "delete", "clear", "clear_all"]

var store: DotCloudStore

## Origins allowed to ask. Empty answers nobody; "*" is never honoured.
var allowed_origins: PackedStringArray = PackedStringArray()

## Optional [code]func() -> DotResult[/code] for [code]clear_all[/code], when the host must also remount or reload.
var clear_all_fn: Callable = Callable()


func _init(p_store: DotCloudStore, p_origins: PackedStringArray = PackedStringArray()) -> void:
	store = p_store
	allowed_origins = p_origins


func is_origin_allowed(origin: String) -> bool:
	return origin != "" and origin != "*" and origin != "null" and allowed_origins.has(origin)


## Whether [param message] is addressed to this bridge, so a transport can ignore unrelated page traffic.
static func is_request(message: Variant) -> bool:
	return message is Dictionary and message.get("dot") == PROTOCOL and message.has("op")


## Returns the reply dictionary, or an empty one when the origin is not allowed (no reply: an unlisted page learns nothing, not even that a bridge exists).
func handle(message: Dictionary, origin: String) -> Dictionary:
	if not is_origin_allowed(origin):
		DotLog.warn(CHANNEL, "request from an origin not on the list", {"origin": origin})
		return {}
	var rid: Variant = message.get("id")
	var op := str(message.get("op", ""))
	var v: Variant = message.get("v", VERSION)
	if not (v is int or v is float) or int(v) != VERSION:
		return _reply(rid, op, DotResult.fail(DotError.CODE_VERSION, "Unsupported bridge version."))
	if not OPS.has(op):
		return _reply(rid, op, DotResult.fail(DotError.CODE_INVALID, "Unknown op."))
	return _reply(rid, op, await _run(op, message))


func _run(op: String, m: Dictionary) -> DotResult:
	var id := str(m.get("pack", ""))
	match op:
		"list":
			return DotResult.success({"packs": store.inventory(), "pinned_games": Array(store.packs.pinned_games)})
		"quota":
			return DotResult.success(await store.quota_report())
		"pin":
			if id == "" or not (m.get("pinned") is bool):
				return DotResult.fail(DotError.CODE_INVALID, "pin needs pack and pinned.")
			return store.set_pinned(id, m["pinned"])
		"pin_game":
			var game := str(m.get("game", ""))
			if game == "" or not (m.get("pinned") is bool):
				return DotResult.fail(DotError.CODE_INVALID, "pin_game needs game and pinned.")
			return store.set_game_pinned(game, m["pinned"])
		"delete":
			if id == "":
				return DotResult.fail(DotError.CODE_INVALID, "delete needs pack.")
			return store.delete(id, str(m.get("version", "")), m.get("force") == true)
		"clear":
			return store.clear_unpinned()
		"clear_all":
			if clear_all_fn.is_valid():
				return await clear_all_fn.call()
			return store.clear_all()
	return DotResult.fail(DotError.CODE_INVALID, "Unknown op.")


func _reply(rid: Variant, op: String, res: DotResult) -> Dictionary:
	var out := {"dot": PROTOCOL, "v": VERSION, "id": rid, "op": op, "ok": res.ok}
	if res.ok:
		out["value"] = res.value
	else:
		out["error"] = {"code": res.error.code, "message": res.error.message}
	return out
