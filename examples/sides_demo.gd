extends Node

## Client-only and server-only files in one signed pack (dot-cloud API 8).
##
## A source declares sides in `sides.json`; the publisher writes each entry's
## [member DotCloudFile.side] into the signed payload; a client fetches and mounts as the
## side its [member DotCloudConfig.side] says. Covered here: the tags as published, a
## flipped or dropped tag failing the signature, a server fetching no client-only object
## and still mounting with every required file of its side present, a client fetching no
## server-only object, `both`, the config's resolution and refusals, the publisher's
## refusals, and the parser (unknown side refused, an untagged entry serialised as before).
##
## [codeblock]
## godot --headless --path . res://examples/sides_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_sides_demo"

## Every check this suite runs, the closing count included. See docs/testing.md.
const CHECKS := 40
const SECTIONS := 8

const SIDES_JSON := '{"client": ["lightmaps/"], "server": ["server/*.json"]}'

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0

var _keys: Dictionary = {}
var _source := WORK.path_join("source")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	print("dot-cloud sides (API 8)")
	DotPaths.remove_tree(WORK)

	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		print("keygen failed: %s" % keys.error)
		_finish(1)
		return
	_keys = keys.value
	# Kept, so a build of an older dot-cloud can be pointed at this run's packs by hand and
	# shown to mount a tagged pack (docs/mounting.md, "An older build mounts a tagged pack").
	DotPaths.write_text(WORK.path_join("public.pem"), str(_keys["public"]))

	var made := _write_source(_source, SIDES_JSON)
	if not made.ok:
		print("writing the source failed: %s" % made.error)
		_finish(1)
		return

	await _section_published_tags()
	await _section_tampered_tag()
	await _section_server_fetch()
	await _section_client_fetch()
	await _section_both()
	await _section_config()
	await _section_publisher_refusals()
	await _section_parser()

	_check(
		"every section finished",
		_sections_started == SECTIONS and _sections_finished == SECTIONS,
		"%d started, %d finished, of %d" % [_sections_started, _sections_finished, SECTIONS]
	)
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])

	print("")
	print("%d checks, %d failed" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


# --- Sections ----------------------------------------------------------------

func _section_published_tags() -> void:
	_begin("published tags")
	var pub := _publish("1.0.0")
	if pub.is_empty():
		return
	var manifest: DotCloudManifest = pub["manifest"]
	var by_path := {}
	for f in manifest.files:
		by_path[f.path] = f.side

	_check("lightmap tagged client", by_path.get("lightmaps/hall.res", "?") == "client", str(by_path.get("lightmaps/hall.res", "?")))
	_check("nested lightmap tagged", by_path.get("lightmaps/deep/yard.res", "?") == "client")
	_check("server table tagged", by_path.get("server/rules.json", "?") == "server")
	_check("unmatched server file both", by_path.get("server/readme.txt", "?") == "")
	_check("game file both", by_path.get("game/main.txt", "?") == "")
	_check("published count", int(pub["result"]["sided"]) == 3, str(pub["result"]["sided"]))

	# The tag is inside the payload the signature covers, not beside it.
	var text := manifest.raw_bytes.get_string_from_utf8()
	_check("tag in signed payload", text.contains('"side": "client"') and text.contains('"side": "server"'))
	_end()


func _section_tampered_tag() -> void:
	_begin("tampered tag")
	var manifest := _read_manifest("1.0.0")
	if manifest == null:
		return

	var text := manifest.raw_bytes.get_string_from_utf8()

	# Same length on purpose: a flip that changes no byte count is the one a careless
	# check would miss.
	var flipped := text.replace('"side": "server"', '"side": "client"').to_utf8_buffer()
	var flip := DotCloudSignature.verify(flipped, manifest.signature, str(_keys["public"]))
	_check("flipped tag refused", not flip.ok)

	var dropped := text.replace(',\n\t\t\t"side": "client"', "").to_utf8_buffer()
	_check("tag was dropped", dropped.size() < manifest.raw_bytes.size())
	var drop := DotCloudSignature.verify(dropped, manifest.signature, str(_keys["public"]))
	_check("dropped tag refused", not drop.ok)

	# And through the client's own path: the envelope re-wrapped round the edited payload
	# with the original signature, parsed, then verified the way fetch_manifest does.
	var forged_bytes := DotCloudEnvelope.wrap(flipped, manifest.signature, "demo").to_utf8_buffer()
	var forged := DotCloudManifest.from_json_bytes(forged_bytes)
	var client := _make_client("verify", "client", _published("1.0.0"))
	var verdict := client.verify_manifest(forged.value) if forged.ok else forged
	_check("client refuses forged tag", not verdict.ok, str(verdict.error) if not verdict.ok else "ACCEPTED")
	var honest := client.verify_manifest(manifest)
	_check("client accepts the real one", honest.ok, str(honest.error) if not honest.ok else "")
	client.queue_free()
	_end()


func _section_server_fetch() -> void:
	_begin("server fetch")
	var manifest := _read_manifest("1.0.0")
	if manifest == null:
		return
	var client := _make_client("server", "server", _published("1.0.0"))

	# plan_for asks the store, which exists only once the client has started.
	var started: DotResult = await client.start()
	_check("client starts", started.ok, str(started.error) if not started.ok else "")
	var plan := client.plan_for(manifest)
	_check("plan leaves client files out", int(plan["missing_files"]) == 4, str(plan["missing_files"]))

	var got := await client.acquire_manifest(manifest)
	# Every lightmap is `required`: a server that skipped them and then reported them
	# missing (download check, mount check, readable-after-mount check) would fail here.
	_check("server mounts", got.ok, str(got.error) if not got.ok else "")

	_check("no client object cached", not _has_any(client, manifest, "client"))
	_check("server object cached", _has_all(client, manifest, "server"))
	var prefix := manifest.mount_prefix()
	_check("server table readable", FileAccess.file_exists(prefix.path_join("server/rules.json")))
	_check("lightmap not mounted", not FileAccess.file_exists(prefix.path_join("lightmaps/hall.res")))
	_check("game file readable", FileAccess.file_exists(prefix.path_join("game/main.txt")))
	client.queue_free()
	_end()


func _section_client_fetch() -> void:
	_begin("client fetch")
	# Another version: the virtual filesystem is one per process and the server section's
	# pack is in it for good, so "not mounted" has to be asked of a prefix it never touched.
	if _publish("1.0.1").is_empty():
		return
	var manifest := _read_manifest("1.0.1")
	if manifest == null:
		return
	var client := _make_client("client", "client", _published("1.0.1"))

	var got := await client.acquire_manifest(manifest)
	_check("client mounts", got.ok, str(got.error) if not got.ok else "")
	_check("no server object cached", not _has_any(client, manifest, "server"))
	_check("client object cached", _has_all(client, manifest, "client"))
	var prefix := manifest.mount_prefix()
	_check("lightmap readable", FileAccess.file_exists(prefix.path_join("lightmaps/deep/yard.res")))
	_check("server table not mounted", not FileAccess.file_exists(prefix.path_join("server/rules.json")))
	client.queue_free()
	_end()


func _section_both() -> void:
	_begin("both")
	if _publish("1.0.2").is_empty():
		return
	var manifest := _read_manifest("1.0.2")
	if manifest == null:
		return
	var client := _make_client("both", "both", _published("1.0.2"))
	var got := await client.acquire_manifest(manifest)
	_check("both mounts", got.ok, str(got.error) if not got.ok else "")
	_check("both fetched everything", _has_all(client, manifest, "client") and _has_all(client, manifest, "server"))
	client.queue_free()
	_end()


func _section_config() -> void:
	_begin("config")
	var c := DotCloudConfig.new()
	c.require_signed_manifests = false
	_check("auto is server headless", c.resolved_side() == ("server" if DotPlatform.is_headless() else "client"), c.resolved_side())
	c.side = "both"
	_check("both resolves to every entry", c.resolved_side() == "")
	c.side = "sever"
	var bad := c.validate()
	_check("a misspelt side refused", not bad.ok and bad.error.code == DotError.CODE_INVALID)
	_end()


func _section_publisher_refusals() -> void:
	_begin("publisher refusals")
	_check("pattern matching nothing", _refused('{"client": ["lightmap/"]}'))
	_check("file on both sides", _refused('{"client": ["server/"], "server": ["server/*.json"]}'))
	_check("unknown key", _refused('{"clients": ["lightmaps/"]}'))
	_check("requires.json tagged", _refused('{"server": ["requires.json"]}', true))

	var pub := _publisher("9.0.0")
	pub.entry_scene = "game/main.txt"
	pub.side_rules = {"game/": "server"}
	var res := pub.publish(_source, WORK.path_join("refused"))
	_check("server-only entry scene", not res.ok and res.error.code == DotError.CODE_INVALID)
	_end()


func _section_parser() -> void:
	_begin("parser")
	var base := {"path": "a.txt", "sha256": "ab".repeat(32), "size": 1}

	var plain := DotCloudFile.from_dict(base)
	_check("untagged is both", plain.ok and (plain.value as DotCloudFile).side == "")
	_check("untagged writes no side", plain.ok and not (plain.value as DotCloudFile).to_dict().has("side"))

	var odd := base.duplicate()
	odd["side"] = "sideways"
	var parsed := DotCloudFile.from_dict(odd)
	_check("unknown side refused", not parsed.ok and parsed.error.code == DotError.CODE_INVALID)
	_end()


# --- Helpers -----------------------------------------------------------------

func _published(version: String) -> String:
	return WORK.path_join("published_" + version)


func _publisher(version: String) -> DotCloudPublisher:
	var pub := DotCloudPublisher.new()
	pub.content_id = "sides_demo"
	pub.version = version
	pub.signing_key_pem = str(_keys["private"])
	pub.signing_key_id = "demo"
	return pub


## Publishes the source as [param version]; {} after recording a failure.
func _publish(version: String) -> Dictionary:
	var res := _publisher(version).publish(_source, _published(version))
	if not res.ok:
		_check("publish %s" % version, false, str(res.error))
		return {}
	return {"result": res.value, "manifest": _read_manifest(version)}


func _read_manifest(version: String) -> DotCloudManifest:
	var bytes := DotPaths.read_bytes(_published(version).path_join("manifest.json"))
	if not bytes.ok:
		_check("read manifest %s" % version, false, str(bytes.error))
		return null
	var parsed := DotCloudManifest.from_json_bytes(bytes.value)
	if not parsed.ok:
		_check("parse manifest %s" % version, false, str(parsed.error))
		return null
	return parsed.value


## Publishes a throwaway source with [param sides] as its sides.json; true when refused.
func _refused(sides: String, with_requires: bool = false) -> bool:
	var dir := WORK.path_join("refusal_src")
	DotPaths.remove_tree(dir)
	if not _write_source(dir, sides).ok:
		return false
	if with_requires:
		DotPaths.write_text(dir.path_join(DotAddonApi.REQUIREMENTS_FILE), "{}\n")
	var res := _publisher("9.0.1").publish(dir, WORK.path_join("refused"))
	return not res.ok and res.error.code == DotError.CODE_INVALID


func _make_client(tag: String, side: String, published: String) -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_" + tag)
	config.require_signed_manifests = true
	config.trusted_keys = {"demo": str(_keys["public"])}
	config.side = side

	var client := DotCloudClient.new()
	client.name = "Cloud_" + tag
	client.config = config
	client.config_file = ""
	client.register_service = false
	client.local_search_dirs = PackedStringArray([published])
	client.allow_netchan_fallback = false
	add_child(client)
	return client


func _has_any(client: DotCloudClient, manifest: DotCloudManifest, side: String) -> bool:
	for f in manifest.files:
		if f.side == side and client.store.has(f.sha256):
			return true
	return false


func _has_all(client: DotCloudClient, manifest: DotCloudManifest, side: String) -> bool:
	var n := 0
	for f in manifest.files:
		if f.side != side:
			continue
		n += 1
		if not client.store.has(f.sha256):
			return false
	return n > 0


## Every file's bytes are distinct, so "this side's object is absent" cannot be satisfied by
## a deduplicated twin from the other side.
func _write_source(dir: String, sides: String) -> DotResult:
	var files := {
		"game/main.txt": "the game\n",
		"lightmaps/hall.res": "baked light for the hall\n",
		"lightmaps/deep/yard.res": "baked light for the yard\n",
		"server/rules.json": "{\"horde\": 12}\n",
		"server/readme.txt": "not matched by server/*.json\n",
		"sides.json": sides + "\n",
	}
	for path: String in files:
		var res := DotPaths.write_text(dir.path_join(path), str(files[path]))
		if not res.ok:
			return res
	return DotResult.success(files.size())


func _begin(name: String) -> void:
	_sections_started += 1
	print("")
	print("[%s]" % name)


func _end() -> void:
	_sections_finished += 1


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("  %s %s%s" % [label.rpad(30), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])


func _finish(code: int) -> void:
	await get_tree().process_frame
	get_tree().quit(code)
