extends RefCounted

## The pure checks and the plan summary of [DotCloudAddonSet], in a file of their own so the addon set stays inside the
## size budget. Nothing here is used on its own.

const _Overlay := preload("dot_cloud_addon_set_overlay.gd")


## Whether an IDBFS record (`{timestamp, mode, contents}`) holds what [param expected] says.
static func record_matches(bridge: Object, record: Variant, expected: Dictionary) -> bool:
	if record == null:
		return false

	var contents: Variant = record.contents

	if contents == null or int(contents.byteLength) != int(expected["size"]):
		return false

	if str(expected["sha"]) == "":
		return true

	var bytes: PackedByteArray = bridge.call("js_buffer_to_packed_byte_array", contents)
	return DotHash.sha256_bytes(bytes) == str(expected["sha"])


## Whether [param manifest] is the addon this build keeps under `res://addons/<dir>/`.
##
## [b]The server names the directory and the pack separately, and nothing else ties them
## together.[/b] A list saying `dir: dot_ui` with the GameSpice Net pack would lay GameSpice Net's files
## over this build's GameSpice UI and drop GameSpice UI's classes from the list -- signed code, so no
## worse than a broken client, but a server must not be able to do even that to its own
## players. So the pack's own `plugin.cfg` names its plugin script, and a directory the
## build already has must already hold that script. A directory the build does not have is
## a new addon and replaces nothing.
static func is_that_addon(cloud: DotCloudClient, dir: String, manifest: DotCloudManifest) -> DotResult:
	var cfg_sha := ""
	var cfg_path := _Overlay.base(manifest, dir) + "plugin.cfg"

	for f in manifest.files:
		if f.path == cfg_path:
			cfg_sha = f.sha256

	var cfg := ConfigFile.new()

	if cfg_sha == "" or cfg.load(cloud.store.path_for(cfg_sha)) != OK:
		return DotResult.fail(DotError.CODE_INVALID, "%s has no readable plugin.cfg." % manifest.key())

	var script := str(cfg.get_value("plugin", "script", "")).get_file()
	var root := "res://addons/%s" % dir

	if not DirAccess.dir_exists_absolute(root):
		return DotResult.success(true)

	if script != "" and ResourceLoader.exists(root.path_join(script)):
		return DotResult.success(true)

	return DotResult.fail(
		DotError.CODE_INVALID,
		"%s is not the addon at %s." % [manifest.key(), root],
		"its plugin script %s is not there" % script
	)


static func same_set(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary and b is Dictionary):
		return false

	var x := a as Dictionary
	var y := b as Dictionary

	if x.size() != y.size():
		return false

	for dir in x:
		if not y.has(dir) or str((x[dir] as Dictionary).get("version", "")) != str((y[dir] as Dictionary).get("version", "")):
			return false

	return true


static func is_component(name: String) -> bool:
	if name == "":
		return false

	for i in range(name.length()):
		var c := name.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or c == 95

		if not ok:
			return false

	return true


static func summary(wanted: Dictionary) -> Dictionary:
	var out := {}
	for dir: String in wanted:
		out[dir] = str((wanted[dir] as Dictionary).get("version", ""))
	return out


## The name a pack goes by in [method built_versions] whichever id spells it: the last path
## part without the old `dot-` prefix, so `gamespice-platform/combat`, `modcommunity/dot-combat`
## and a lock's `gs-combat` or `combat` are all `combat`.
static func pack_key(name: String) -> String:
	return name.strip_edges().get_file().trim_prefix("dot-")


## The key of [param versions] (repo -> version) that [param names] (a repo, an id, or both)
## stand for, in the spelling the dictionary already uses; "" when none does. Exact matches win,
## so a lock that spells both ids apart keeps its own entries.
static func version_key(versions: Dictionary, names: Array) -> String:
	for name: String in names:
		if name != "" and versions.has(name):
			return name

	for name: String in names:
		var want := pack_key(name)

		if want == "":
			continue

		for key: String in versions:
			if pack_key(key) == want:
				return key

	return ""
