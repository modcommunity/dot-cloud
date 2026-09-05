extends Control

## Drives [DotCloudSourceHttp] against a real HTTP server, over a real socket.
##
## [b]Why this exists.[/b] [code]sync_demo[/code] covers the pipeline but routes
## every byte through [DotCloudSourceLocal], which resolves synchronously,
## builds no URL, parses no response and resumes nothing. HTTP is the source
## every shipped game uses and it had no executable coverage at all: mirror
## failover, the sticky preferred base, the content-addressed URL layout, range
## resume and the restart-from-zero fallback were all read-only code.
##
## The server is [code]examples/http_test_server.gd[/code], a ~250-line static
## file server in GDScript, so this runs offline, headless and with nothing
## installed.
##
## 1. Publishes a content set and serves the published directory over HTTP.
## 2. Probes the base URL.
## 3. Acquires through a dead mirror followed by a live one, and checks the
##    dead one was tried, the live one won, and the URLs were the
##    content-addressed ones.
## 4. Re-acquires and checks the sticky preference skips the dead mirror.
## 5. Resumes a half-downloaded object and checks the server was asked for a
##    range and sent fewer bytes than the object holds.
## 6. Does it again against a host that refuses ranges, and checks it restarts
##    rather than failing.
## 7. Points the client at a mirror serving corrupted bytes and checks the
##    transfer is rejected by hash rather than accepted.
##
## [codeblock]
## godot --headless --path . res://examples/http_demo.tscn
## [/codeblock]

const TestServer := preload("res://examples/http_test_server.gd")

const WORK := "user://dot_cloud_http_demo"

## A port nothing listens on. Connecting is refused immediately, which is the
## mirror failure worth testing — a black-holed port would just be a timeout.
const DEAD_BASE := "http://127.0.0.1:1"

@onready var _output: RichTextLabel = $Output

var _failures: int = 0
var _server: Node = null

## Sections that suspend, and the ones that reported reaching their end.
##
## The bug this guards against cost dot-net a check that never ran once: a
## section called without [code]await[/code] stops at its first suspension and
## the summary still says everything passed. Counting arrivals makes a dropped
## section visible.
var _sections_entered: int = 0
var _sections_completed: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	_line("[b]dot-cloud over HTTP[/b]")
	_line("")

	DotPaths.remove_tree(WORK)

	var source_dir := WORK.path_join("source")
	var publish_dir := WORK.path_join("published")

	# --- publish ---------------------------------------------------------
	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		await _fail("keygen", keys)
		return
	var key_pair: Dictionary = keys.value

	var made := _write_source_content(source_dir)
	if not made.ok:
		await _fail("writing content", made)
		return

	var pub := DotCloudPublisher.new()
	pub.content_id = "http_arena"
	pub.version = "1.0.0"
	pub.display_name = "HTTP Arena"
	pub.entry_scene = "arena.txt"
	pub.signing_key_pem = str(key_pair["private"])

	var published := pub.publish(source_dir, publish_dir)
	if not published.ok:
		await _fail("publish", published)
		return

	var pd: Dictionary = published.value
	_line("  published        %d files -> %d objects" % [
		int(pd["files"]), int(pd["objects"])
	])

	var manifest_bytes := DotPaths.read_bytes(str(pd["manifest_path"]))
	if not manifest_bytes.ok:
		await _fail("reading manifest", manifest_bytes)
		return

	var reparsed := DotCloudManifest.from_json_bytes(manifest_bytes.value)
	if not reparsed.ok:
		await _fail("parsing manifest", reparsed)
		return
	var manifest: DotCloudManifest = reparsed.value

	# --- serve -----------------------------------------------------------
	_server = TestServer.new()
	_server.name = "TestHttpServer"
	_server.root = publish_dir
	add_child(_server)

	var listening: DotResult = _server.start(0)
	if not listening.ok:
		await _fail("starting the test server", listening)
		return

	var base: String = _server.base_url()
	_line("  serving          %s -> %s" % [publish_dir, base])
	_line("")

	await _test_probe(base, key_pair)
	await _test_failover(base, key_pair, manifest)
	await _test_resume(base, key_pair, manifest)
	await _test_poisoned_partial(base, key_pair, manifest)
	await _test_no_range_support(base, key_pair, manifest)
	await _test_corrupt_mirror(base, key_pair, manifest)

	# --- summary ---------------------------------------------------------
	_check(
		"every suspending section ran to completion",
		_sections_completed == _sections_entered,
		"%d/%d" % [_sections_completed, _sections_entered]
	)

	_line("")
	if _failures > 0:
		_line("[b]%d check(s) FAILED[/b]" % _failures)
	else:
		_line("[b]done[/b]")

	await _finish(1 if _failures > 0 else 0)


# --- Sections --------------------------------------------------------------


## The reachability probe, which is the call meant to run before a large sync.
func _test_probe(base: String, key_pair: Dictionary) -> void:
	_sections_entered += 1
	_line("[section] probe")

	var client := await _make_client("probe", key_pair, PackedStringArray([base]))
	if client == null:
		return

	var source := _http_source(client)
	if source == null:
		_check("client built an HTTP source", false)
		return

	var probed := await source.probe_base(base)
	_check("base URL probes ok", probed.ok, "" if probed.ok else str(probed.error))

	var dead := await source.probe_base(DEAD_BASE)
	_check("an unreachable base fails cleanly", not dead.ok)

	# probe_base requests the bare base URL, so "reachable" here means the root
	# answers — not that objects under it do. Object hosts that 404 or 403 their
	# root (a plain S3 bucket, most CDN origins) are reported unreachable while
	# serving content perfectly. The test server answers its root deliberately;
	# see the run report for 2026-08-18.
	var missing_root := await source.probe_base(base + "/no_such_prefix")
	_check("a base whose root is absent is reported unreachable", not missing_root.ok)

	_drop(client)
	_sections_completed += 1


## Mirror failover, the URL layout, and the sticky preference afterwards.
func _test_failover(
	base: String, key_pair: Dictionary, manifest: DotCloudManifest
) -> void:
	_sections_entered += 1
	_line("")
	_line("[section] failover")

	_server.log.clear()

	var client := await _make_client(
		"failover", key_pair, PackedStringArray([DEAD_BASE, base])
	)
	if client == null:
		return

	# Through acquire() rather than acquire_manifest(): fetching the manifest
	# over HTTP is itself a path sync_demo never takes — it reads the document
	# off disk — and a manifest served as bytes has to parse and verify the same.
	var acquired := await client.acquire(base + "/manifest.json")
	_check(
		"acquired over HTTP", acquired.ok,
		"" if acquired.ok else str(acquired.error)
	)

	if not acquired.ok:
		_drop(client)
		return

	_check("manifest was fetched over HTTP", _served("GET /manifest.json"))

	# The layout is a contract with every CDN this ever points at: objects live
	# at <base>/objects/<first two hex>/<full hash>. Asserting on the URL the
	# server actually saw is the only way to catch a change to it.
	var first: DotCloudFile = manifest.files[0]
	var want := "GET /objects/%s" % first.object_path()
	_check("objects use content-addressed URLs", _served(want), want)

	_check(
		"every object was served",
		_object_requests() >= manifest.unique_hashes().size(),
		"%d requests for %d objects" % [
			_object_requests(), manifest.unique_hashes().size()
		]
	)

	var source := _http_source(client)
	_check(
		"the live mirror became preferred",
		source != null and str(source.health()["preferred"]) == base,
		"" if source == null else str(source.health()["preferred"])
	)

	_drop(client)

	# The dead mirror is first in the list, so failover is the only thing that
	# can have made the acquire above work — provided the dead base really is
	# dead. Proving that needs its own client, because health()["failures"] is a
	# live circuit-breaker count that note_success() has already reset to zero.
	var doomed := await _make_client(
		"doomed", key_pair, PackedStringArray([DEAD_BASE])
	)
	if doomed != null:
		var never := await doomed.acquire_manifest(manifest)
		_check("the dead mirror alone cannot acquire", not never.ok)
		_drop(doomed)
	_sections_completed += 1


## Range resume: a partial file on disk must be continued, not re-fetched.
func _test_resume(
	base: String, key_pair: Dictionary, manifest: DotCloudManifest
) -> void:
	_sections_entered += 1
	_line("")
	_line("[section] resume")

	var target := _largest_file(manifest)
	if target == null:
		_check("the manifest has a file to resume", false)
		return

	var client := await _make_client("resume", key_pair, PackedStringArray([base]))
	if client == null:
		return

	# Seed a partial that is exactly the first half of the real object, which is
	# what a download killed halfway leaves behind.
	var whole := FileAccess.get_file_as_bytes(
		_object_file(base, target)
	)
	var half := whole.slice(0, whole.size() / 2)

	var seeded := DotPaths.write_bytes(
		client.store.partial_path(target.sha256), half
	)
	if not seeded.ok:
		_check("seeded a partial download", false, str(seeded.error))
		_drop(client)
		return

	_check(
		"partial is on disk",
		client.store.partial_size(target.sha256) == half.size(),
		"%d B of %d B" % [half.size(), whole.size()]
	)

	_server.log.clear()
	_server.bytes_sent = 0
	_server.support_ranges = true

	var acquired := await client.acquire_manifest(manifest)
	_check(
		"acquired with a partial present", acquired.ok,
		"" if acquired.ok else str(acquired.error)
	)

	_check(
		"the server was asked for a range",
		_served_prefix("GET /objects/%s (range" % target.object_path())
	)

	_check("the resumed object verified", client.store.has(target.sha256))
	_check(
		"no partial was left behind",
		client.store.partial_size(target.sha256) == 0
	)

	# The only externally visible proof that the range was used for anything. A
	# resume that appends sends just the bytes still missing; one that truncates
	# and rewrites sends the object twice over, recovers silently via the
	# restart-from-zero path below, and passes every check above it.
	#
	# It was a printed line and not an assertion until 2026-08-28, on the
	# grounds that it measures DotHttp rather than anything dot-cloud decides.
	# It was also, for that whole time, printing "re-sent the object" —
	# HTTPRequest has no append mode and download_to_file wrote the ranged body
	# at offset zero, so resume across the family was inert and this was the one
	# place saying so. Asserting it is what stops that being true again.
	_line("    transferred      %d B for %d B of objects" % [
		_server.bytes_sent, _total_object_bytes(manifest),
	])
	_check(
		"the resume moved fewer bytes than the content, so the partial was reused",
		_server.bytes_sent < _total_object_bytes(manifest),
		"sent %d B for %d B of objects" % [
			_server.bytes_sent, _total_object_bytes(manifest)
		]
	)

	_drop(client)
	_sections_completed += 1


## A partial full of bytes that were never valid. It must not become content,
## and it must not make the content permanently unacquirable either.
##
## This is the dot-cloud contract on its own, independent of how the HTTP layer
## resumes: bytes on disk from an interrupted attempt have been verified by
## nothing, so a hash failure after a resume has to be blamed on them and
## retried from zero before the mirror is written off. With a single mirror —
## the normal deployment — the alternative is content that can never arrive.
func _test_poisoned_partial(
	base: String, key_pair: Dictionary, manifest: DotCloudManifest
) -> void:
	_sections_entered += 1
	_line("")
	_line("[section] poisoned partial")

	var target := _largest_file(manifest)
	if target == null:
		_check("the manifest has a file to poison", false)
		return

	var client := await _make_client("poison", key_pair, PackedStringArray([base]))
	if client == null:
		return

	var junk := PackedByteArray()
	junk.resize(64 * 1024)
	for i in junk.size():
		junk[i] = 0x5A

	DotPaths.write_bytes(client.store.partial_path(target.sha256), junk)

	_server.log.clear()
	_server.support_ranges = true

	var acquired := await client.acquire_manifest(manifest)

	_check(
		"acquired despite a poisoned partial", acquired.ok,
		"" if acquired.ok else str(acquired.error)
	)
	_check("the object verified", client.store.has(target.sha256))
	_check(
		"the poisoned partial is gone",
		client.store.partial_size(target.sha256) == 0
	)
	_check(
		"it restarted the transfer from zero",
		_served("GET /objects/%s" % target.object_path())
	)

	_drop(client)
	_sections_completed += 1


## A host that will not do ranges. The source must restart, not give up.
func _test_no_range_support(
	base: String, key_pair: Dictionary, manifest: DotCloudManifest
) -> void:
	_sections_entered += 1
	_line("")
	_line("[section] host without ranges")

	var target := _largest_file(manifest)
	if target == null:
		_check("the manifest has a file to resume", false)
		return

	var client := await _make_client("norange", key_pair, PackedStringArray([base]))
	if client == null:
		return

	var whole := FileAccess.get_file_as_bytes(_object_file(base, target))
	DotPaths.write_bytes(
		client.store.partial_path(target.sha256), whole.slice(0, whole.size() / 2)
	)

	_server.log.clear()
	_server.support_ranges = false

	var acquired := await client.acquire_manifest(manifest)

	# The point of the test: a host that ignores Range is common (plain S3
	# without range support, some caching proxies) and must degrade to a full
	# re-download rather than leaving the content unavailable forever.
	_check(
		"acquired from a host that refuses ranges", acquired.ok,
		"" if acquired.ok else str(acquired.error)
	)
	_check("the object still verified", client.store.has(target.sha256))

	_server.support_ranges = true
	_drop(client)
	_sections_completed += 1


## A mirror serving the wrong bytes must be caught by the hash, not trusted.
func _test_corrupt_mirror(
	base: String, key_pair: Dictionary, manifest: DotCloudManifest
) -> void:
	_sections_entered += 1
	_line("")
	_line("[section] corrupt mirror")

	var target := _largest_file(manifest)
	if target == null:
		_check("the manifest has a file to corrupt", false)
		return

	var client := await _make_client("corrupt", key_pair, PackedStringArray([base]))
	if client == null:
		return

	_server.log.clear()
	_server.corrupt_paths = PackedStringArray(
		["/objects/%s" % target.object_path()]
	)

	var acquired := await client.acquire_manifest(manifest)

	# Right length, wrong bytes, correct HTTP status. Everything below the hash
	# check sees a perfectly successful transfer, so if this passes, content
	# verification is not actually running.
	_check("corrupted content was refused", not acquired.ok)
	_check(
		"the corrupt object was not cached", not client.store.has(target.sha256)
	)

	# The other files in the manifest are served intact, so a failure here would
	# mean one bad object poisoned the whole sync rather than one file.
	var other := _other_file(manifest, target)
	_check(
		"intact files from the same mirror still landed",
		other == null or client.store.has(other.sha256)
	)

	_server.corrupt_paths = PackedStringArray()
	_drop(client)
	_sections_completed += 1


# --- Helpers ---------------------------------------------------------------


## A started client with its own cache directory, or null after reporting why.
func _make_client(
	tag: String, key_pair: Dictionary, bases: PackedStringArray
) -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_%s" % tag)
	config.require_signed_manifests = true
	config.trusted_keys = {"demo": str(key_pair["public"])}
	config.verify_before_mount = true
	config.resume_downloads = true
	# One at a time so the server's request log reads in a deterministic order.
	config.parallel_downloads = 1
	config.file_timeout_sec = 10.0

	var client := DotCloudClient.new()
	client.name = "CloudClient_%s" % tag
	client.config = config
	client.config_file = ""
	client.http_base_urls = bases
	client.allow_netchan_fallback = false
	add_child(client)

	var started := await client.start()
	if not started.ok:
		_check("client '%s' started" % tag, false, str(started.error))
		client.queue_free()
		return null

	return client


## Removes a client from the tree. Each section uses its own cache, and a client
## left behind would keep its pack mounted and its store open.
func _drop(client: DotCloudClient) -> void:
	remove_child(client)
	client.queue_free()


func _http_source(client: DotCloudClient) -> DotCloudSourceHttp:
	for s in client.sources:
		var http := s as DotCloudSourceHttp
		if http != null:
			return http
	return null


func _served(line: String) -> bool:
	return Array(_server.log).has(line)


func _served_prefix(prefix: String) -> bool:
	for l in _server.log:
		if str(l).begins_with(prefix):
			return true
	return false


func _object_requests() -> int:
	var n := 0
	for l in _server.log:
		if str(l).contains("/objects/"):
			n += 1
	return n


## The biggest file in the manifest — the one whose halves are far enough apart
## for a byte count to prove anything.
func _largest_file(manifest: DotCloudManifest) -> DotCloudFile:
	var best: DotCloudFile = null
	for f in manifest.files:
		if best == null or f.size > best.size:
			best = f
	return best


func _other_file(
	manifest: DotCloudManifest, not_this: DotCloudFile
) -> DotCloudFile:
	for f in manifest.files:
		if f.sha256 != not_this.sha256:
			return f
	return null


func _total_object_bytes(manifest: DotCloudManifest) -> int:
	var seen := {}
	var total := 0
	for f in manifest.files:
		if seen.has(f.sha256):
			continue
		seen[f.sha256] = true
		total += f.size
	return total


func _object_file(_base: String, file: DotCloudFile) -> String:
	return WORK.path_join("published/objects/%s" % file.object_path())


## Content with one file big enough that half of it is a meaningful saving.
func _write_source_content(dir: String) -> DotResult:
	var made := DotPaths.ensure_dir(dir)
	if not made.ok:
		return made

	# 256 KiB of non-repeating bytes: large enough that a resumed transfer is
	# unambiguously smaller than a full one, small enough to stay instant.
	var big := PackedByteArray()
	big.resize(256 * 1024)
	for i in big.size():
		big[i] = (i * 31 + (i >> 8)) & 0xFF

	var wrote_big := DotPaths.write_bytes(dir.path_join("payload.bin"), big)
	if not wrote_big.ok:
		return wrote_big

	var files := {
		"arena.txt": "hello over http\n",
		"data/config.json": "{\"tickrate\": 64}\n",
	}

	for rel in files:
		var res := DotPaths.write_text(dir.path_join(rel), str(files[rel]))
		if not res.ok:
			return res

	return DotResult.success(files.size() + 1)


func _fail(what: String, res: DotResult) -> void:
	_line("")
	_line("[b]FAILED at %s[/b]" % what)
	_line("  %s" % str(res.error))
	_failures += 1
	await _finish(1)


func _finish(code: int = 0) -> void:
	if _server != null:
		_server.stop()

	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(code)


func _check(label: String, passed: bool, detail: String = "") -> void:
	if not passed:
		_failures += 1

	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail

	_line("  %s %s%s" % [label.rpad(46), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
