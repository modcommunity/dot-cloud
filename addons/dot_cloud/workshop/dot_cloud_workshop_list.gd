class_name DotCloudWorkshopList
extends RefCounted

## One game's resolved subscription list, as the site answered it: the items, the revision, the
## entries it says are not on for this game and why, and the game's [code]accepts[/code].
##
## A wrapper over the response dictionary, so the cache file holds the response verbatim and a
## newer site that adds a field does not need a newer client to keep it.

var response: Dictionary = {}


static func from_response(p_response: Dictionary) -> DotCloudWorkshopList:
	var l := DotCloudWorkshopList.new()
	l.response = p_response
	return l


func revision() -> String:
	return str(response.get("revision", ""))


func account() -> String:
	return str(response.get("account", ""))


## The game's [code]accepts[/code] block, or an empty dictionary when it takes no subscriptions.
func accepts() -> Dictionary:
	var game: Variant = response.get("game", {})
	if game is Dictionary:
		var a: Variant = (game as Dictionary).get("accepts", null)
		if a is Dictionary:
			return a
	return {}


func items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = response.get("items", [])
	if raw is Array:
		for it in raw as Array:
			if it is Dictionary and (it as Dictionary).get("pack", null) is Dictionary:
				out.append(it)
	return out


func removed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = response.get("removed", [])
	if raw is Array:
		for it in raw as Array:
			if it is Dictionary:
				out.append(it)
	return out


## The item for a pack, or an empty dictionary.
func item_for(content_id: String) -> Dictionary:
	for it in items():
		if str((it["pack"] as Dictionary).get("contentId", "")) == content_id:
			return it
	return {}


static func pack_of(item: Dictionary) -> Dictionary:
	var p: Variant = item.get("pack", {})
	return p if p is Dictionary else {}
