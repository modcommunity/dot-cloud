class_name DotCloudAddonSet
extends RefCounted

## Newer addons for a build that already shipped, as packs, applied at the next boot.
##
## [b]The point: an addon release should not need a new client build.[/b] Every addon tag
## is already published as a signed pack (`modcommunity/dot-ui@0.1.5`). A server says which
## addon versions it runs; a client whose build is older fetches those packs, lays them
## over its own `res://addons/<addon>/` in one overlay pack, and restarts into it -- a
## page reload in a browser, a relaunch on desktop.
##
## [b]Why a restart, and not a mount on the spot.[/b] Measured on an exported build: a
## script the process has already compiled keeps running its old code after a newer file
## is mounted over it, `CACHE_MODE_REPLACE` and `Script.reload()` included. The shell has
## compiled most of the addons by the time a server answers. So the overlay is mounted by
## `boot/dot_cloud_boot.gd` -- a main scene that names no addon -- before anything else
## loads, and the rest of the process never sees the older copy.
##
## [b]What the overlay has to carry, besides the files.[/b] Both measured on an exported
## build, both silent when missing:
##
## - [b]A `.remap` per resource[/b], pointing at itself. An export stores `x.gd` as
##   `x.gdc` behind `x.gd.remap`, and `x.tscn` as a binary `.scn` behind `x.tscn.remap`;
##   the loader follows the build's remap to the build's bytes, and a newer `x.gd` mounted
##   beside it is never read.
## - [b]The global class list[/b], with this set's entries swapped in. See
##   [DotCloudScriptClass].
##
## [b]Only ever upward.[/b] A server running an older addon than this build has keeps
## this build's: a client newer than its server is the case the envelope negotiation
## already handles, and following a server DOWN would let any server pin its players to a
## version with a bug that was fixed. Only signed packs from [member namespaces] are taken.

const CHANNEL := "cloud.addons"

## Where the overlay and its plan live. Fixed, and outside the content cache, because the
## boot script reads it before any configuration exists -- and a session-only content
## cache (`--content-cache off`) must not take a player's addons with it.
const DIR := "user://dot_cloud_addons"
const PLAN := "user://dot_cloud_addons/plan.json"

## The build's own class list, saved by the boot script before an overlay replaces it.
const SHELL_CLASSES := "user://dot_cloud_addons/shell_classes.cfg"

## The file an export carries that says which addon versions it was built from.
const BUILT_LOCK := "res://addons.lock"

const FORMAT := 1

## Plan states. `booting` is written before the mount and cleared by [method confirm_boot];
## a boot that finds it still set knows the last one never reached the shell, and skips
## the overlay rather than looping on it.
const STATE_READY := "ready"
const STATE_BOOTING := "booting"
const STATE_OK := "ok"
const STATE_FAILED := "failed"

## The extensions a build may have remapped. Each one in the overlay gets a `.remap`
## pointing at itself; anything else is read with FileAccess and needs none.
const REMAPPED := ["gd", "tscn", "tres", "scn", "res", "gdshader", "shader"]

## Where an addon pack may come from: an owner (`modcommunity/`, ending in a slash) or one
## exact content id. The signature says who published a pack; this says whose packs may
## replace this build's code, which is a narrower question.
var namespaces: PackedStringArray = PackedStringArray(["modcommunity/"])

## The client that fetches and verifies the packs.
var cloud: DotCloudClient = null


func _init(p_cloud: DotCloudClient = null) -> void:
	cloud = p_cloud


# --- What this build is ------------------------------------------------------

## The addon versions this build shipped with: repo -> version, from [constant BUILT_LOCK].
## Empty when the build carries no lock, which turns this whole mechanism off: without a
## baseline there is no way to say what is newer.
static func built_versions() -> Dictionary:
	var text := FileAccess.get_file_as_string(BUILT_LOCK)
	var out := {}

	for raw in text.split("\n"):
		var line := raw.strip_edges()

		if line == "" or line.begins_with("#"):
			continue

		var parts := line.split("\t", false)

		if parts.size() >= 2:
			out[parts[0].strip_edges()] = parts[1].strip_edges().trim_prefix("v")

	return out


## Which build an overlay was made for. An overlay is only ever mounted over the build it
## was assembled against: over a newer one it could take an addon BACKWARDS.
static func build_fingerprint() -> String:
	var text := FileAccess.get_file_as_string(BUILT_LOCK)
	return text.sha256_text().substr(0, 16) if text != "" else ""


# --- The plan the boot script reads --------------------------------------------

static func read_plan() -> Dictionary:
	var text := FileAccess.get_file_as_string(PLAN)

	if text == "":
		return {}

	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


static func write_plan(plan: Dictionary) -> DotResult:
	var parent := DotPaths.ensure_parent_dir(PLAN)
	if not parent.ok:
		return parent

	var f := FileAccess.open(PLAN, FileAccess.WRITE)

	if f == null:
		return DotResult.fail(DotError.CODE_IO, "Could not write the addon plan.", PLAN)

	f.store_string(JSON.stringify(plan, "\t"))
	f.close()
	DotWeb.sync_filesystem()
	return DotResult.success(true)


## Says the shell came up on the overlay the boot script mounted. Call it once the shell
## has finished building itself: until then a broken addon is still a boot that did not
## arrive, and the next boot should come up without the overlay.
##
## [b]And it checks the overlay is what is running.[/b] The failure this exists to catch is
## silent: an overlay mounted while the build's compiled copy of an addon is still the one
## that loads -- a remap that did not take -- leaves the old code running under the new
## class list. In an exported build a script loaded from its compiled `.gdc` has no source,
## and one loaded from the overlay has its text, so one script per addon is asked
## (`probes`, recorded when the overlay was built). A miss marks the overlay failed, so the
## next start comes up on the build's own addons rather than on a mixture.
static func confirm_boot() -> void:
	var plan := read_plan()

	if str(plan.get("state", "")) != STATE_BOOTING:
		return

	var stale := PackedStringArray()

	# Outside an export every script is loaded from its source, so the question has no
	# answer there -- and nothing is compiled ahead to be wrongly preferred.
	if OS.has_feature("template"):
		var probes: Variant = plan.get("probes", {})

		if probes is Dictionary:
			for dir: String in probes:
				var script := load(str(probes[dir])) as Script

				if script == null or script.source_code == "":
					stale.append(dir)

	if not stale.is_empty():
		plan["state"] = STATE_FAILED
		write_plan(plan)
		DotLog.error(CHANNEL, "the addon overlay is mounted but these addons still run the build's own copy; it is off from the next start", {
			"addons": stale,
		})
		return

	plan["state"] = STATE_OK
	write_plan(plan)
	DotLog.info(CHANNEL, "booted on the addon overlay", {"addons": _summary(plan.get("addons", {}))})


## The addons running right now: the build's, overridden by the overlay if it is mounted.
## repo -> version.
static func running_versions() -> Dictionary:
	var out := built_versions()
	var plan := read_plan()

	if mounted_this_boot(plan):
		var addons: Dictionary = plan.get("addons", {})

		for dir: String in addons:
			var entry: Dictionary = addons[dir]
			out[str(entry.get("repo", ""))] = str(entry.get("version", ""))

	return out


## Whether the boot script mounted [param plan]'s overlay in this process.
static func mounted_this_boot(plan: Dictionary) -> bool:
	return ProjectSettings.get_setting("dot_cloud/addon_overlay", "") != "" \
		and str(ProjectSettings.get_setting("dot_cloud/addon_overlay", "")) == str(plan.get("pack", ""))


# --- Deciding ------------------------------------------------------------------

## What a server's addon set asks of this process.
##
## [param server] is the server's list, as [method DotServer.addon_set] sends it: one
## `{dir, repo, id, version}` per addon. Returns `{wanted, refused}`: [code]wanted[/code]
## is the full set the next overlay should hold (dir -> entry) -- empty when nothing has
## to change -- and [code]refused[/code] says, per entry, why it was not taken.
func plan_for(server: Array) -> Dictionary:
	var built := built_versions()
	var refused := {}

	if built.is_empty():
		return {"wanted": {}, "refused": {"*": "this build carries no %s" % BUILT_LOCK}}

	var current := read_plan()
	var held: Dictionary = current.get("addons", {}) if mounted_this_boot(current) else {}
	var wanted := {}
	var missing := false

	for raw in server:
		if not (raw is Dictionary):
			continue

		var entry := raw as Dictionary
		var dir := str(entry.get("dir", ""))
		var repo := str(entry.get("repo", ""))
		var id := str(entry.get("id", ""))
		var version := str(entry.get("version", "")).trim_prefix("v")
		var why := _refusal(dir, repo, id, version)

		if why != "":
			refused[dir if dir != "" else repo] = why
			continue

		var have := str(built.get(repo, ""))

		if have != "" and compare_versions(version, have) <= 0:
			continue

		wanted[dir] = {"dir": dir, "repo": repo, "id": id, "version": version}

		var mounted: Variant = held.get(dir)

		if mounted == null or compare_versions(str((mounted as Dictionary).get("version", "")), version) < 0:
			missing = true

	if not missing:
		return {"wanted": {}, "refused": refused}

	# [b]Never narrower than what is running.[/b] An addon the overlay already raised and
	# this server does not mention stays raised: dropping it would take it backwards.
	for dir: String in held:
		var entry: Dictionary = held[dir]

		if not wanted.has(dir):
			wanted[dir] = entry
		elif compare_versions(str(entry.get("version", "")), str(wanted[dir]["version"])) > 0:
			wanted[dir] = entry

	return {"wanted": wanted, "refused": refused}


## Whether the last attempt at exactly this set failed to boot. A shell that would build
## it again would only reload into the same failure.
static func failed_before(wanted: Dictionary) -> bool:
	var plan := read_plan()
	return str(plan.get("state", "")) == STATE_FAILED \
		and str(plan.get("build", "")) == build_fingerprint() \
		and _same_set(plan.get("addons", {}), wanted)


## Forgets the overlay: the next start comes up on this build's own addons. The pack file
## stays until [method _prune] or a clear removes it, because this process may have it
## mounted.
static func forget() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PLAN))
	DotWeb.sync_filesystem()


## The engine's object store inside the IndexedDB database that mirrors `user://`
## (Emscripten's IDBFS names the store; the database is named for the mount point).
const IDB_STORE := "FILE_DATA"

## Files up to this size are compared byte for byte; a larger one by its length, which is
## enough for an overlay (named by the hash of its contents, so a file of that name and
## length is that overlay).
const PERSIST_COMPARE_BYTES := 256 * 1024


## Waits until every file in [param paths] is in the browser's IndexedDB exactly as it is
## in `user://` now. Succeeds at once anywhere else, where a closed file is on disk.
##
## [b]What a browser restart has to wait for, and the only way to know.[/b] A browser's
## `user://` is an in-memory copy that reaches IndexedDB only through `FS.syncfs`, which
## the engine runs one at a time from its main loop ([method DotWeb.sync_filesystem] only
## asks for the next one) and which says nothing to a script when it is done. Each sync
## walks EVERY file under `user://` and writes what changed, so it takes as long as the
## player's cache is large: measured at 1 to 5 seconds with under 1 MiB cached, while the
## shell reloaded on a fixed three seconds. A reload in the middle of a sync loses that
## sync, so the plan and the overlay were never written and the page came back to download
## the same addons again. Reading the database itself is the one answer that is not a guess.
##
## Fails with [code]CODE_TIMEOUT[/code] when [param timeout_s] passes first, and with
## [code]CODE_UNSUPPORTED[/code] when the page has no IndexedDB copy of `user://` at all (a
## private window, storage refused): a restart there could only lose what was written, so
## the caller should not restart.
static func persisted(paths: PackedStringArray, timeout_s: float = 30.0) -> DotResult:
	if not DotWeb.available():
		return DotResult.success(true)

	var want := {}
	var db_name := ""

	for path in paths:
		if not FileAccess.file_exists(path):
			return DotResult.fail(DotError.CODE_IO, "There is no file to keep.", path)

		var key := ProjectSettings.globalize_path(path)
		var bytes := FileAccess.get_file_as_bytes(path)
		want[key] = {
			"size": bytes.size(),
			"sha": DotHash.sha256_bytes(bytes) if bytes.size() <= PERSIST_COMPARE_BYTES else "",
		}
		# `/userfs/godot/app_userdata/<name>/...` is kept in the database `/userfs`.
		var parts := key.split("/", false)
		db_name = "/" + parts[0] if parts.size() > 0 else ""

	if want.is_empty():
		return DotResult.success(true)

	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var waiting: Array = want.keys()

	while true:
		DotWeb.sync_filesystem()
		await tree.create_timer(0.5).timeout

		var read := await _idb_differs(db_name, want)

		if not read.ok:
			return read

		waiting = read.value

		if waiting.is_empty():
			return DotResult.success(true)

		if Time.get_ticks_msec() >= deadline:
			break

	return DotResult.fail(
		DotError.CODE_TIMEOUT,
		"The browser did not save the files a restart needs in time.",
		", ".join(PackedStringArray(waiting))
	)


## The keys of [param want] whose IndexedDB record is missing or not what is on disk.
## Through the page's `indexedDB` object and callbacks, never an eval: the player's page
## refuses `unsafe-eval` (see [method DotWeb.get_global]).
static func _idb_differs(db_name: String, want: Dictionary) -> DotResult:
	var idb: Variant = DotWeb.get_global("indexedDB")

	if idb == null or db_name == "":
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This page has no IndexedDB.")

	var tree := Engine.get_main_loop() as SceneTree
	# Containers, not scalars: a lambda captures a local by value (docs/gdscript-hazards).
	var state := {"db": null, "done": false, "error": ""}
	var request: Variant = idb.open(db_name)
	request.onsuccess = DotWeb.create_callback("dot_cloud_idb_open", func(_args: Array) -> void:
		state["db"] = request.result
		state["done"] = true
	)
	request.onerror = DotWeb.create_callback("dot_cloud_idb_open_error", func(_args: Array) -> void:
		state["error"] = "the database would not open"
		state["done"] = true
	)

	var give_up := Time.get_ticks_msec() + 10000

	while not state["done"] and Time.get_ticks_msec() < give_up:
		await tree.process_frame

	DotWeb.release_callback("dot_cloud_idb_open")
	DotWeb.release_callback("dot_cloud_idb_open_error")

	var db: Variant = state["db"]

	if db == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "The browser's copy of user:// could not be read.",
			str(state["error"]) if str(state["error"]) != "" else "no answer")

	# An empty database is one this call just created: the engine never had one, so nothing
	# written in this session is kept anywhere.
	if not bool(db.objectStoreNames.contains(IDB_STORE)):
		db.close()
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This page keeps nothing between loads.", db_name)

	var store: Variant = db.transaction(IDB_STORE, "readonly").objectStore(IDB_STORE)
	var differs: Array = []
	var answered: Array = []
	var bridge := DotWeb.bridge()

	for key: String in want:
		var ask: Variant = store.get(key)
		var name := "dot_cloud_idb_get_%d" % answered.size()
		answered.append(false)
		var slot := answered.size() - 1
		ask.onsuccess = DotWeb.create_callback(name, func(_args: Array) -> void:
			if not _record_matches(bridge, ask.result, want[key]):
				differs.append(key)
			answered[slot] = true
		)
		ask.onerror = DotWeb.create_callback(name + "_error", func(_args: Array) -> void:
			differs.append(key)
			answered[slot] = true
		)

	while answered.has(false) and Time.get_ticks_msec() < give_up:
		await tree.process_frame

	for i in answered.size():
		DotWeb.release_callback("dot_cloud_idb_get_%d" % i)
		DotWeb.release_callback("dot_cloud_idb_get_%d_error" % i)

	db.close()

	if answered.has(false):
		return DotResult.fail(DotError.CODE_TIMEOUT, "The browser's copy of user:// did not answer.")

	return DotResult.success(differs)


## Whether an IDBFS record (`{timestamp, mode, contents}`) holds what [param expected] says.
static func _record_matches(bridge: Object, record: Variant, expected: Dictionary) -> bool:
	if record == null:
		return false

	var contents: Variant = record.contents

	if contents == null or int(contents.byteLength) != int(expected["size"]):
		return false

	if str(expected["sha"]) == "":
		return true

	var bytes: PackedByteArray = bridge.call("js_buffer_to_packed_byte_array", contents)
	return DotHash.sha256_bytes(bytes) == str(expected["sha"])


func _refusal(dir: String, repo: String, id: String, version: String) -> String:
	if not _is_component(dir) or dir.begins_with("."):
		return "not a directory name"

	if repo == "" or id == "" or version == "":
		return "incomplete"

	# The repository is what this build's lock is keyed by, so it decides "newer than what
	# I have" -- and it has to be the pack's own name, or a list could compare one addon's
	# version and fetch another's.
	if id.get_file() != repo:
		return "%s is not the repository %s" % [id, repo]

	var allowed := false

	# An entry ending in `/` is an owner, anything else one exact id: `alice/x` must not
	# also admit `alice/x-evil`.
	for entry in namespaces:
		if (entry.ends_with("/") and id.begins_with(entry)) or id == entry:
			allowed = true
			break

	if not allowed:
		return "%s is not in a namespace this client takes addons from" % id

	if not version.is_valid_filename() or version.contains("/") or version.contains(".."):
		return "not a version"

	return ""


## Numeric, dot by dot: `0.1.10` is newer than `0.1.9`. A part that is not a number
## compares as text. Returns -1, 0 or 1.
static func compare_versions(a: String, b: String) -> int:
	var x := a.trim_prefix("v").split(".")
	var y := b.trim_prefix("v").split(".")

	for i in range(maxi(x.size(), y.size())):
		var p := x[i] if i < x.size() else "0"
		var q := y[i] if i < y.size() else "0"

		if p.is_valid_int() and q.is_valid_int():
			if int(p) != int(q):
				return -1 if int(p) < int(q) else 1
		elif p != q:
			return -1 if p < q else 1

	return 0


# --- Building ------------------------------------------------------------------

## Fetches every pack in [param wanted] and writes the overlay and its plan.
##
## Nothing is mounted: the boot script does that, at the next start. [param resume] is
## kept in the plan for the shell to act on after the restart (where it was connecting).
func build(wanted: Dictionary, resume: Dictionary = {}) -> DotResult:
	if cloud == null:
		return DotResult.fail(DotError.CODE_STATE, "No content client to fetch addons with.")

	var fingerprint := build_fingerprint()

	if fingerprint == "":
		return DotResult.fail(DotError.CODE_STATE, "This build does not say which addons it has.", BUILT_LOCK)

	var manifests := {}

	for dir: String in wanted:
		var entry: Dictionary = wanted[dir]
		var resolved := await cloud.resolve_manifest(StringName(entry["id"]), str(entry["version"]))

		if not resolved.ok:
			return resolved.wrap("Could not find %s %s." % [entry["id"], entry["version"]])

		var manifest: DotCloudManifest = resolved.value

		# [b]An addon pack is the addon's directory, and it says so.[/b] Every addon has a
		# plugin.cfg at its root; a pack without one was published from somewhere else and
		# laid over `res://addons/<dir>/` would put its files at the wrong depth.
		if not _has_file(manifest, "plugin.cfg"):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"%s is not an addon pack." % manifest.key(),
				"it has no plugin.cfg at its root"
			)

		var downloaded := await cloud.download_manifest(manifest)

		if not downloaded.ok:
			return downloaded.wrap("Could not download %s." % manifest.key())

		var same := _is_that_addon(dir, manifest)

		if not same.ok:
			return same

		manifests[dir] = manifest

	var assembled := _assemble(manifests, fingerprint)

	if not assembled.ok:
		return assembled

	var plan := {
		"format": FORMAT,
		"build": fingerprint,
		"pack": str(assembled.value["pack"]),
		"addons": wanted,
		"uids": assembled.value["uids"],
		"probes": assembled.value["probes"],
		"state": STATE_READY,
		"resume": resume,
		"made": Time.get_datetime_string_from_system(true),
	}

	var written := write_plan(plan)
	if not written.ok:
		return written

	_prune(str(plan["pack"]))

	DotLog.info(CHANNEL, "addon overlay ready for the next start", {
		"pack": plan["pack"], "addons": _summary(wanted),
	})

	return DotResult.success(plan)


## The overlay: every file at `res://addons/<dir>/<path>`, a self-pointing remap per
## resource, and the merged class list.
func _assemble(manifests: Dictionary, fingerprint: String) -> DotResult:
	var made := DotPaths.ensure_dir(DIR)
	if not made.ok:
		return made

	# [b]Named by what is IN it[/b] -- every file's path and hash, and the build it is laid
	# over -- not by `id@version`. A version republished from a corrected source is how an
	# addon gets fixed, and dot-cloud's mounter learned the hard way that a cache keyed on
	# the version keeps serving the broken one. Same name therefore means same bytes, which
	# is what makes reusing an existing file safe -- and reuse is required, not merely
	# cheaper: the file of that name may be the overlay this very process has mounted, and
	# rewriting a mounted pack under a running engine corrupts what it reads next.
	var lines := PackedStringArray([fingerprint])
	for dir: String in manifests:
		for f in (manifests[dir] as DotCloudManifest).files:
			lines.append("%s/%s:%s" % [dir, f.path, f.sha256])
	lines.sort()

	var pack_path := DIR.path_join("overlay-%s.pck" % "\n".join(lines).sha256_text().substr(0, 16))
	var reuse := FileAccess.file_exists(pack_path)
	var scratch := DIR.path_join("staging")
	DotPaths.remove_tree(scratch)
	DotPaths.ensure_dir(scratch)

	var packer := PCKPacker.new()
	var err := OK if reuse else packer.pck_start(pack_path)

	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "creating the addon overlay"))

	var scripts := {}
	var uids: Array = []
	var probes := {}
	var replaced := PackedStringArray()
	var remap_index := 0

	for dir: String in manifests:
		var manifest: DotCloudManifest = manifests[dir]
		var root := "res://addons/%s" % dir
		replaced.append(root)

		for f in manifest.files:
			if not cloud.store.has(f.sha256):
				return DotResult.fail(DotError.CODE_STATE, "An addon file is not downloaded.", f.path)

			var target := root.path_join(f.path)
			var source := cloud.store.path_for(f.sha256)

			if not reuse:
				err = packer.add_file(target, source)
				if err != OK:
					return DotResult.failure(DotError.from_engine(err, "adding %s" % target))

			var ext := f.path.get_extension().to_lower()

			if ext in REMAPPED and not reuse:
				var remap := scratch.path_join("r%d.remap" % remap_index)
				remap_index += 1
				var w := FileAccess.open(remap, FileAccess.WRITE)
				w.store_string("[remap]\n\npath=\"%s\"\n" % target)
				w.close()
				err = packer.add_file(target + ".remap", remap)
				if err != OK:
					return DotResult.failure(DotError.from_engine(err, "adding %s.remap" % target))

			if ext == "gd":
				scripts[target] = FileAccess.get_file_as_string(source)

				# The script confirm_boot loads to see which copy is running: the addon's
				# API file when it has one -- constants, nothing that runs on load -- and
				# otherwise the first by path, so the choice is the same every build.
				var api := "%s_api.gd" % dir
				if f.path == api:
					probes[dir] = target
				elif not _has_file(manifest, api) and (not probes.has(dir) or target < str(probes[dir])):
					probes[dir] = target
			elif ext == "uid":
				var uid := FileAccess.get_file_as_string(source).strip_edges()
				if uid.begins_with("uid://"):
					uids.append([uid, target.trim_suffix(".uid")])

	if reuse:
		DotPaths.remove_tree(scratch)
		return DotResult.success({"pack": pack_path, "uids": uids, "probes": probes, "classes": 0, "reused": true})

	# The build's list as the build shipped it -- saved by the boot script before any
	# overlay replaced it -- and only then this set's entries.
	var base := DotCloudScriptClass.read_cache(SHELL_CLASSES)
	if base.is_empty():
		base = DotCloudScriptClass.read_cache()

	var known := {}
	for e in base:
		if e is Dictionary:
			known[str(e.get("class", ""))] = e

	var added := DotCloudScriptClass.entries_for(scripts, known)
	var merged := DotCloudScriptClass.merge(base, replaced, added)
	var cache_file := scratch.path_join("global_script_class_cache.cfg")
	var c := FileAccess.open(cache_file, FileAccess.WRITE)
	c.store_string(DotCloudScriptClass.cache_text(merged))
	c.close()

	err = packer.add_file(DotCloudScriptClass.CACHE_PATH, cache_file)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "adding the class list"))

	err = packer.flush(false)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "writing the addon overlay"))

	DotPaths.remove_tree(scratch)
	DotWeb.sync_filesystem()

	return DotResult.success({"pack": pack_path, "uids": uids, "probes": probes, "classes": added.size()})


# --- Internals -----------------------------------------------------------------

## Deletes every overlay but [param keep] and the one mounted in this process. An old
## overlay is never mounted again -- the plan names one file -- so the rest is disk.
static func _prune(keep: String) -> void:
	var mounted := str(ProjectSettings.get_setting("dot_cloud/addon_overlay", ""))
	var dir := DirAccess.open(DIR)

	if dir == null:
		return

	for name in dir.get_files():
		var path := DIR.path_join(name)

		if name.begins_with("overlay-") and name.ends_with(".pck") and path != keep and path != mounted:
			DirAccess.remove_absolute(path)


## Whether [param manifest] is the addon this build keeps under `res://addons/<dir>/`.
##
## [b]The server names the directory and the pack separately, and nothing else ties them
## together.[/b] A list saying `dir: dot_ui` with the dot-net pack would lay dot-net's files
## over this build's dot-ui and drop dot-ui's classes from the list -- signed code, so no
## worse than a broken client, but a server must not be able to do even that to its own
## players. So the pack's own `plugin.cfg` names its plugin script, and a directory the
## build already has must already hold that script. A directory the build does not have is
## a new addon and replaces nothing.
func _is_that_addon(dir: String, manifest: DotCloudManifest) -> DotResult:
	var cfg_sha := ""

	for f in manifest.files:
		if f.path == "plugin.cfg":
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


static func _has_file(manifest: DotCloudManifest, path: String) -> bool:
	for f in manifest.files:
		if f.path == path:
			return true
	return false


static func _same_set(a: Variant, b: Variant) -> bool:
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


static func _is_component(name: String) -> bool:
	if name == "":
		return false

	for i in range(name.length()):
		var c := name.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or c == 95

		if not ok:
			return false

	return true


static func _summary(wanted: Dictionary) -> Dictionary:
	var out := {}
	for dir: String in wanted:
		out[dir] = str((wanted[dir] as Dictionary).get("version", ""))
	return out
