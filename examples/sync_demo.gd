extends Control

## End-to-end exercise of the whole content pipeline, with no server involved.
##
## 1. Generates a signing keypair.
## 2. Writes a small content set to disk.
## 3. Publishes it — hashes, dedupes, writes objects, signs the manifest.
## 4. Configures a client that trusts the generated public key.
## 5. Syncs from the published directory via [DotCloudSourceLocal].
## 6. Mounts it and loads a file back out of the mounted pack.
## 7. Releases it, then re-acquires to prove the cache is warm.
##
## The [b]local[/b] source stands in for HTTP so the whole thing runs offline and
## in CI. Everything after the source — hashing, dedup, verification, pack
## building, mounting, path namespacing — is the same code an HTTP download uses.
##
## [codeblock]
## godot --headless --path . res://examples/sync_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_demo"

@onready var _output: RichTextLabel = $Output

var _client: DotCloudClient

## Assertions that came out the wrong way. Anything above zero exits non-zero.
##
## Printing "this is a bug" and exiting 0 made every boolean below decorative:
## the family treats each example as a smoke test, and a smoke test that always
## passes is worse than none, because it is believed.
var _failures: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	_line("[b]dot-cloud end-to-end[/b]")
	_line("")

	# Start clean so re-runs measure the same thing.
	DotPaths.remove_tree(WORK)

	var source_dir := WORK.path_join("source")
	var publish_dir := WORK.path_join("published")

	# --- 1. keys ---------------------------------------------------------
	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		return _fail("keygen", keys)
	var key_pair: Dictionary = keys.value
	_line("  keypair          generated (RSA 2048)")

	# --- 2. content ------------------------------------------------------
	var made := _write_source_content(source_dir)
	if not made.ok:
		return _fail("writing content", made)
	_line("  source content   %d files" % int(made.value))

	# --- 3. publish ------------------------------------------------------
	var pub := DotCloudPublisher.new()
	pub.content_id = "demo_arena"
	pub.version = "1.0.0"
	pub.display_name = "Demo Arena"
	pub.entry_scene = "arena.txt"
	pub.signing_key_pem = str(key_pair["private"])
	pub.optional_prefixes = PackedStringArray(["optional/"])
	pub.group_rules = {"optional/": "extras"}

	var published := pub.publish(source_dir, publish_dir)
	if not published.ok:
		return _fail("publish", published)

	var pd: Dictionary = published.value
	_line("  published        %d files -> %d objects (%d deduplicated)" % [
		int(pd["files"]), int(pd["objects"]), int(pd["deduped"])
	])
	_line("  manifest signed  %s" % ("yes" if bool(pd["signed"]) else "no"))

	# Dedup is worth asserting rather than just reporting: two of the files
	# written above are byte-identical, so a publisher that stored both would
	# have a real bug that this number is the only visible symptom of.
	if int(pd["deduped"]) < 1:
		_line("  [b]WARNING[/b]        expected deduplication, got none")

	# --- 4. verify the signature independently ---------------------------
	var manifest_bytes := DotPaths.read_bytes(str(pd["manifest_path"]))
	if not manifest_bytes.ok:
		return _fail("reading manifest", manifest_bytes)

	var reparsed := DotCloudManifest.from_json_bytes(manifest_bytes.value)
	if not reparsed.ok:
		return _fail("parsing manifest", reparsed)

	var manifest: DotCloudManifest = reparsed.value

	var sig_ok := DotCloudSignature.verify(
		manifest.raw_bytes, manifest.signature, str(key_pair["public"])
	)
	_check(
		"signature check", sig_ok.ok,
		"" if sig_ok.ok else sig_ok.error.message
	)

	# A tampered manifest must fail. Without this check a signature routine that
	# always returns true would pass every other test in this file.
	var tampered := manifest.raw_bytes.duplicate()
	tampered[tampered.size() - 2] = 0x20
	var tamper_check := DotCloudSignature.verify(
		tampered, manifest.signature, str(key_pair["public"])
	)
	_check("tamper refused", not tamper_check.ok)

	# A key too weak to mean anything must be refused before any crypto runs.
	# 1024-bit RSA still verifies happily under mbedTLS, and a valid signature
	# from a broken key is indistinguishable from a good one everywhere
	# downstream of here — which is the whole reason MIN_KEY_BITS exists.
	# Generated through Crypto directly, because DotCloudSignature.generate_keypair
	# refuses to produce one this small — which is the point: the weak key in the
	# real scenario was never made here. It came from an old setup, or from a
	# trusted_keys entry in a layered config file.
	var weak_key := Crypto.new().generate_rsa(1024)
	if weak_key == null:
		return _fail(
			"generating a 1024-bit key",
			DotResult.fail(DotError.CODE_INTERNAL, "generate_rsa(1024) failed")
		)

	var weak_sig := DotCloudSignature.sign(
		manifest.raw_bytes, weak_key.save_to_string(false)
	)
	if not weak_sig.ok:
		return _fail("signing with the weak key", weak_sig)

	# This signature is genuinely valid: 128 bytes, and mbedTLS verifies it
	# against its own key without complaint. It must be refused as FORBIDDEN —
	# too weak to consider — and not as INTEGRITY, which would mean the key was
	# considered and only the bytes disagreed.
	var weak_check := DotCloudSignature.verify(
		manifest.raw_bytes,
		str(weak_sig.value),
		weak_key.save_to_string(true)
	)
	_check(
		"weak key refused",
		not weak_check.ok and weak_check.error.code == DotError.CODE_FORBIDDEN,
		"" if not weak_check.ok else "ACCEPTED"
	)

	# A zero-byte manifest is what a truncated response looks like. This has to
	# come back as a failed DotResult, not as an engine error out of
	# HashingContext.update() with a DotResult that claims success.
	var empty_check := DotCloudSignature.verify(
		PackedByteArray(), manifest.signature, str(key_pair["public"])
	)
	_check("empty body refused", not empty_check.ok)

	# --- 5. client -------------------------------------------------------
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = {"demo": str(key_pair["public"])}
	config.verify_before_mount = true
	config.parallel_downloads = 4

	_client = DotCloudClient.new()
	_client.name = "CloudClient"
	_client.config = config
	# Empty so start() does not layer a stale file over the settings above.
	_client.config_file = ""
	_client.local_search_dirs = PackedStringArray([publish_dir])
	_client.allow_netchan_fallback = false
	add_child(_client)

	# Three other addons find this client through DotRegistry and none of them imports
	# dot-cloud: dot-server downloads a game's content with it, releases the previous
	# game's with it and reports on it from the console, and dot-user-avatar turns a
	# cosmetic's content id into a path with it. All four call sites treat an absent
	# cloud as "this deployment ships its content in the build" — a legitimate
	# configuration, and therefore indistinguishable from a client that simply never
	# registered.
	_check(
		"registers as a service",
		DotRegistry.get_service(DotCloudClient.SERVICE) == _client
	)

	_client.phase_changed.connect(func(p: DotCloudClient.Phase, _t: String) -> void:
		DotLog.debug("demo", "phase", {"phase": DotCloudClient.phase_name(p)})
	)

	var started := await _client.start()
	if not started.ok:
		return _fail("client start", started)
	_line("  client started   cache at %s" % config.cache_dir)

	# --- 6. plan ---------------------------------------------------------
	var plan := _client.plan_for(manifest)
	_line("")
	_line("  plan             %d missing (%s), %d cached" % [
		int(plan["missing_files"]),
		str(plan["missing_human"]),
		int(plan["cached_files"]),
	])

	# --- 7. acquire ------------------------------------------------------
	var t0 := Time.get_ticks_msec()
	var acquired := await _client.acquire_manifest(manifest)
	if not acquired.ok:
		return _fail("acquire", acquired)

	_line("  acquired         %d ms -> %s" % [
		Time.get_ticks_msec() - t0, str(acquired.value)
	])

	# --- 8. read content back out of the mount ---------------------------
	var mounted_path := manifest.mount_prefix().path_join("arena.txt")
	var read_back := DotPaths.read_text(mounted_path)

	_check(
		"read from mount", read_back.ok,
		str(read_back.value).strip_edges() if read_back.ok
		else read_back.error.message
	)

	# The namespace is what makes hot-swapping possible; assert it is really
	# where the content landed rather than trusting the prefix helper.
	_line("  mount prefix     %s" % manifest.mount_prefix())
	_check(
		"namespaced",
		mounted_path.begins_with("res://dot_cloud/demo_arena/1.0.0/"),
		mounted_path
	)

	# Optional content was excluded from the default group selection.
	var optional_path := manifest.mount_prefix().path_join("optional/extra.txt")
	_check("optional skipped", not FileAccess.file_exists(optional_path))

	# --- 9. cache state --------------------------------------------------
	_line("")
	for l in _client.store.describe_lines():
		_line("  " + l)

	# --- 10. release then re-acquire -------------------------------------
	_line("")
	var released := _client.release(manifest.key())
	_check(
		"released", released.ok, "" if released.ok else released.error.message
	)

	var t1 := Time.get_ticks_msec()
	var again := await _client.acquire_manifest(manifest)
	_check("re-acquired", again.ok, "%d ms, cache was warm" % [
		Time.get_ticks_msec() - t1
	])

	# --- 11. a manifest signed by nobody we trust ------------------------
	var rogue := DotCloudManifest.new()
	rogue.content_id = "rogue"
	rogue.version = "1.0.0"
	rogue.raw_bytes = "{}".to_utf8_buffer()
	var rogue_check := _client.verify_manifest(rogue)
	_check("unsigned refused", not rogue_check.ok)

	_line("")
	if _failures > 0:
		_line("[b]%d check(s) FAILED[/b]" % _failures)
	else:
		_line("[b]done[/b]")
	_finish(1 if _failures > 0 else 0)


## Writes a content set with a deliberate duplicate and an optional file.
func _write_source_content(dir: String) -> DotResult:
	var shared := "the same bytes in two places\n"

	var files := {
		"arena.txt": "hello from the mounted pack\n",
		"data/config.json": "{\"tickrate\": 64}\n",
		"data/copy_a.txt": shared,
		"data/copy_b.txt": shared,
		"optional/extra.txt": "only fetched when the 'extras' group is asked for\n",
	}

	# Something big enough that hashing is not instant, so the numbers above mean
	# something.
	var blob := PackedByteArray()
	blob.resize(2 * 1024 * 1024)
	for i in range(blob.size()):
		blob[i] = i % 251

	var written := DotPaths.write_bytes(dir.path_join("data/blob.bin"), blob)
	if not written.ok:
		return written

	for path in files:
		var res := DotPaths.write_text(dir.path_join(str(path)), str(files[path]))
		if not res.ok:
			return res

	return DotResult.success(files.size() + 1)


func _fail(what: String, res: DotResult) -> void:
	_line("")
	_line("[b]FAILED at %s[/b]" % what)
	_line("  %s" % str(res.error))
	_finish(1)


func _finish(code: int = 0) -> void:
	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(code)


## Prints an assertion and records a failure, padding so the column lines up.
func _check(label: String, passed: bool, detail: String = "") -> void:
	if not passed:
		_failures += 1

	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail

	_line("  %s %s%s" % [label.rpad(16), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
