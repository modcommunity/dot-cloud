extends Control

## Drives [DotCloudSourceNetchan] — the in-band content fallback — for real.
##
## [b]Why this exists.[/b] [code]sync_demo[/code] covers the pipeline through
## [DotCloudSourceLocal] and [code]http_demo[/code] covers HTTP. The netchan
## source had neither, and it is the one source that cannot fall back to another:
## it is what a browser client on a home-hosted server uses, and when it fails
## there is nothing after it. Its 200-odd lines were read-only code, including a
## [member DotCloudSourceNetchan.chunk_timeout_sec] the inspector advertised and
## nothing enforced.
##
## The delegate is [code]examples/netchan_chunk_server.gd[/code], the shape
## dot-server supplies, reduced to reading published objects off disk. dot-cloud
## must not depend on dot-server, so the real one lives in another repository and
## cannot be reached from here.
##
## 1. Publishes a content set, then acquires it with netchan as the only source.
## 2. Does it again with a delegate that never suspends — the case that breaks
##    naive fan-out code, and what a server holding the file in memory does.
## 3. Resumes a half-written partial and checks the peer was asked to start from
##    the middle rather than from zero.
## 4. Points it at a peer that answers nothing and checks the transfer times out
##    instead of hanging the acquire forever.
## 5. Fails mid-file and checks the partial survives for a later resume.
## 6. Lets the peer over-serve past the declared size and checks the result is
##    still rejected or trimmed rather than silently corrupt.
## 7. Points it at a peer that is slow but never wrong, which no per-chunk
##    deadline can catch, and checks the whole-file deadline ends it.
## 8. Trips the netchan circuit breaker and checks the failure names it, rather
##    than blaming an HTTP source that was never configured for anything.
##
## [codeblock]
## godot --headless --path . res://examples/netchan_demo.tscn
## [/codeblock]

const ChunkServer := preload("res://examples/netchan_chunk_server.gd")

const WORK := "user://dot_cloud_netchan_demo"

## Awaited by the hanging delegate. Never emitted, on purpose.
signal never_fires

@onready var _output: RichTextLabel = $Output

var _failures: int = 0

var _key_pair: Dictionary = {}
var _publish_dir: String = ""
var _manifest: DotCloudManifest = null

## Sections that suspend, and the ones that reported reaching their end. A
## section called without [code]await[/code] stops at its first suspension while
## the summary still says everything passed; counting arrivals makes that visible.
var _sections_entered: int = 0
var _sections_completed: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	_line("[b]dot-cloud in-band (netchan) transfer[/b]")
	_line("")

	DotPaths.remove_tree(WORK)

	var prepared := await _prepare()
	if not prepared:
		await _finish(1)
		return

	await _section_happy_path()
	await _section_synchronous_delegate()
	await _section_resume()
	await _section_timeout()
	await _section_failure_keeps_partial()
	await _section_overserving_peer()
	await _section_slow_peer()
	await _section_skipped_sources()

	_line("")
	_check(
		"every suspending section ran to completion",
		_sections_entered == _sections_completed,
		"%d/%d" % [_sections_completed, _sections_entered]
	)

	_line("")
	_line("done" if _failures == 0 else "[b]%d FAILED[/b]" % _failures)
	await _finish(1 if _failures > 0 else 0)


# --- setup -----------------------------------------------------------------


func _prepare() -> bool:
	var keys := DotCloudSignature.generate_keypair(2048)
	if not keys.ok:
		_check("keypair generated", false, str(keys.error))
		return false
	_key_pair = keys.value

	var source_dir := WORK.path_join("source")
	_publish_dir = WORK.path_join("published")

	# Deliberately larger than one chunk, so the loop runs more than once and
	# resume has somewhere to resume from. A single-chunk file would pass every
	# check below without the loop ever iterating.
	var payload := PackedByteArray()
	payload.resize(20000)
	for i in range(payload.size()):
		payload[i] = (i * 31 + 7) & 0xFF

	var wrote := DotPaths.write_bytes(source_dir.path_join("big.bin"), payload)
	if not wrote.ok:
		_check("source content written", false, str(wrote.error))
		return false

	wrote = DotPaths.write_bytes(
		source_dir.path_join("small.txt"), "in-band".to_utf8_buffer()
	)
	if not wrote.ok:
		_check("source content written", false, str(wrote.error))
		return false

	var pub := DotCloudPublisher.new()
	pub.content_id = "netchan_arena"
	pub.version = "1.0.0"
	pub.display_name = "Netchan Arena"
	pub.signing_key_pem = str(_key_pair["private"])

	var published := pub.publish(source_dir, _publish_dir)
	if not published.ok:
		_check("published", false, str(published.error))
		return false

	var pd: Dictionary = published.value
	var bytes := DotPaths.read_bytes(str(pd["manifest_path"]))
	if not bytes.ok:
		_check("manifest read", false, str(bytes.error))
		return false

	var parsed := DotCloudManifest.from_json_bytes(bytes.value)
	if not parsed.ok:
		_check("manifest parsed", false, str(parsed.error))
		return false

	_manifest = parsed.value
	_line("  published        %d files -> %d objects" % [
		int(pd["files"]), int(pd["objects"])
	])
	_line("")
	return true


# --- sections --------------------------------------------------------------


func _section_happy_path() -> void:
	_sections_entered += 1
	_line("[section] a peer that answers")

	var server := _server()
	var client := await _client("happy", server)
	if client == null:
		return

	var got := await client.acquire_manifest(_manifest)
	_check("acquired over the game channel", got.ok, _why(got))
	_check("the peer was actually asked", server.requests.size() > 0,
		"%d chunk requests" % server.requests.size())

	# More than one round trip, or the chunking loop never ran.
	_check("the transfer was chunked", server.requests.size() > 1,
		"%d requests for %d B" % [server.requests.size(), server.served])

	_check("every object landed in the cache", _all_cached(client))
	_check("the bytes survived the trip", _payload_intact(client))

	_drop(client)
	_sections_completed += 1


func _section_synchronous_delegate() -> void:
	_sections_entered += 1
	_line("[section] a peer that answers without suspending")

	# The family's documented trap: a worker that finishes before the waiter
	# exists. Here the delegate returns a value with no await in it at all, so
	# the source's chunk request completes before it can start waiting on one.
	var server := _server()
	server.suspends = false

	var client := await _client("sync", server)
	if client == null:
		return

	var got := await client.acquire_manifest(_manifest)
	_check("a synchronous peer did not hang the transfer", got.ok, _why(got))
	_check("every object landed in the cache", _all_cached(client))

	_drop(client)
	_sections_completed += 1


func _section_resume() -> void:
	_sections_entered += 1
	_line("[section] resuming a half-written partial")

	var server := _server()
	var client := await _client("resume", server)
	if client == null:
		return

	var target := _largest_file()
	var whole := _object_bytes(target)
	var half := whole.slice(0, whole.size() / 2)

	DotPaths.write_bytes(client.store.partial_path(target.sha256), half)
	_check("a partial was staged", client.store.partial_size(target.sha256) == half.size())

	var got := await client.acquire_manifest(_manifest)
	_check("acquired from the partial", got.ok, _why(got))

	# The point of the whole section: the peer must be asked to start from the
	# middle. A source that ignored the partial would ask for offset 0 and the
	# transfer would still succeed, which is why the byte count is checked too.
	var first_for_target := _first_offset_for(server, target.sha256)
	_check("the peer was asked to resume", first_for_target >= half.size(),
		"first offset %d of %d" % [first_for_target, whole.size()])
	_check("only the missing half moved", server.served < whole.size(),
		"%d B for a %d B object" % [server.served, whole.size()])
	_check("the resumed object verified", client.store.has(target.sha256))
	_check("no partial was left behind", client.store.partial_size(target.sha256) == 0)

	_drop(client)
	_sections_completed += 1


func _section_timeout() -> void:
	_sections_entered += 1
	_line("[section] a peer that answers nothing")

	var server := _server()
	server.hangs = true

	var client := await _client("timeout", server)
	if client == null:
		return

	var netchan := _netchan(client)
	netchan.chunk_timeout_sec = 1.0

	var target := _largest_file()

	# Straight at the source. The downloader rebuilds the error it reports as a
	# generic "content could not be downloaded", so the timeout code is only
	# visible where it is produced.
	var started := Time.get_ticks_msec()
	var direct := await netchan.fetch(target, _manifest, client.store, client.scheduler)
	var elapsed := Time.get_ticks_msec() - started

	# The assertion that matters is that this line is reached at all. Before the
	# timeout existed the await above never returned, and the example hung until
	# the harness killed it — no failure, no output, no exit code.
	_check("a silent peer did not hang the transfer", true,
		"returned after %d ms" % elapsed)
	_check("the fetch failed", not direct.ok)
	_check("it failed as a timeout", _has_code(direct, DotError.CODE_TIMEOUT),
		_why(direct))
	_check("it gave up near the configured deadline", elapsed < 10000,
		"%d ms for a 1 s chunk timeout" % elapsed)

	# And the whole acquire above it also returns rather than hanging.
	var got := await client.acquire_manifest(_manifest)
	_check("the acquire failed instead of hanging", not got.ok)

	_drop(client)
	_sections_completed += 1


func _section_failure_keeps_partial() -> void:
	_sections_entered += 1
	_line("[section] a peer that drops mid-file")

	var server := _server()
	server.chunk_size = 1024
	server.fail_after_chunks = 3

	var client := await _client("drop", server)
	if client == null:
		return

	var target := _largest_file()

	var got := await client.acquire_manifest(_manifest)
	_check("the acquire failed", not got.ok, _why(got))
	_check("the object was not cached", not client.store.has(target.sha256))

	# Discarding on a transient drop restarts a large transfer over one lost
	# packet. The partial is keyed by content hash, so keeping it is safe.
	_check("the partial was kept for a retry",
		client.store.partial_size(target.sha256) > 0,
		"%d B held" % client.store.partial_size(target.sha256))

	var held := client.store.partial_size(target.sha256)
	_drop(client)

	# And it must be usable. Retrying on the same client would not show that:
	# three chunk failures trip the source's circuit breaker, so netchan — the
	# only source configured here — is unavailable for its whole cooldown, and
	# the acquire fails again for an unrelated reason. A second client over the
	# same cache directory is both the honest test and the real scenario: the
	# player closed the game and came back.
	var healthy := _server()
	healthy.chunk_size = 1024
	var resumed := await _client_on("retry", "drop", healthy)
	if resumed == null:
		_sections_completed += 1
		return

	_check("the partial survived the store being reopened",
		resumed.store.partial_size(target.sha256) == held,
		"%d B" % resumed.store.partial_size(target.sha256))

	var retry := await resumed.acquire_manifest(_manifest)
	_check("a retry finished from the partial", retry.ok, _why(retry))
	_check("the retried object verified", resumed.store.has(target.sha256))
	_check("the retry only fetched what was missing",
		healthy.served < target.size,
		"%d B for a %d B object" % [healthy.served, target.size])

	_drop(resumed)
	_sections_completed += 1


func _section_overserving_peer() -> void:
	_sections_entered += 1
	_line("[section] a peer that sends more than it was asked for")

	var server := _server()
	server.chunk_size = 1024
	server.overserves = true

	var client := await _client("overserve", server)
	if client == null:
		return

	var target := _largest_file()

	var got := await client.acquire_manifest(_manifest)

	# Either outcome is defensible; silently caching wrong bytes is not. The
	# store is content-addressed, so a file that ends up in it under this hash
	# has to actually hash to it.
	_check("an over-serving peer produced no corrupt cache entry",
		(not got.ok) or _sha256_of_cached(client, target) == target.sha256,
		"acquire %s" % ("ok" if got.ok else "refused"))

	_drop(client)
	_sections_completed += 1


func _section_slow_peer() -> void:
	_sections_entered += 1
	_line("[section] a peer that is slow but never wrong")

	# Every answer is correct, complete and inside the per-chunk deadline. That is
	# the whole point: the chunk timeout has nothing to fire on, `note_failure` is
	# never called so the circuit breaker never opens, and before
	# `file_timeout_sec` existed the only bound left was
	# max_chunks_per_file × chunk_timeout_sec — 16384 × 30 s, over 130 hours on
	# the in-band source, which is the game connection.
	var server := _server()
	server.chunk_size = 1024
	server.delay_sec = 0.2

	var client := await _client("slow", server)
	if client == null:
		return

	var netchan := _netchan(client)
	netchan.chunk_timeout_sec = 30.0
	netchan.file_timeout_sec = 1.0

	var target := _largest_file()

	# 20000 B at 1 KiB and 0.2 s a chunk is about four seconds of honest work,
	# against a one-second budget.
	var started := Time.get_ticks_msec()
	var direct := await netchan.fetch(target, _manifest, client.store, client.scheduler)
	var elapsed := Time.get_ticks_msec() - started

	_check("a slow peer did not hold the channel", not direct.ok, _why(direct))
	_check("it failed as a timeout", _has_code(direct, DotError.CODE_TIMEOUT),
		_why(direct))
	# Which deadline fired is the whole claim. The per-chunk one is set to 30 s
	# here and every answer arrives in 0.2, so a chunk-timeout message would mean
	# the file budget was being reported as something it is not.
	_check("the file deadline is what fired, not the chunk deadline",
		str(direct.error).contains("took too long"), _why(direct))
	_check("it stopped near the file deadline", elapsed < 3000,
		"%d ms for a 1 s file budget" % elapsed)

	# A slow peer is a reason to come back later, not a reason to throw away the
	# bytes it did manage to send.
	_check("the partial was kept for a retry",
		client.store.partial_size(target.sha256) > 0,
		"%d B held" % client.store.partial_size(target.sha256))

	# And zero must still mean "no limit", so a deployment that genuinely moves a
	# large file in band can opt out.
	var patient := _server()
	patient.chunk_size = 1024
	patient.delay_sec = 0.05

	var relaxed := await _client_on("patient", "patient", patient)
	if relaxed == null:
		_sections_completed += 1
		return

	var unbounded := _netchan(relaxed)
	unbounded.file_timeout_sec = 0.0

	var slow_ok := await unbounded.fetch(
		target, _manifest, relaxed.store, relaxed.scheduler
	)
	_check("zero still means no limit", slow_ok.ok, _why(slow_ok))

	_drop(relaxed)
	_drop(client)
	_sections_completed += 1


func _section_skipped_sources() -> void:
	_sections_entered += 1
	_line("[section] a source with nowhere to fetch from")

	# DotCloudClient always builds an HTTP source, whether or not it was given any
	# base URLs, because a manifest may carry its own mirrors. This manifest has
	# none and neither does the client, so that source cannot serve one byte —
	# and it sits at priority 50, ahead of netchan at 900.
	var server := _server()
	server.chunk_size = 1024
	server.fail_after_chunks = 0

	var client := await _client("skipped", server)
	if client == null:
		return

	var http_source: DotCloudSourceHttp = null
	for s in client.sources:
		var h := s as DotCloudSourceHttp
		if h != null:
			http_source = h

	_check("the client built an HTTP source anyway", http_source != null)
	if http_source == null:
		_sections_completed += 1
		return

	_check("it reports itself unable to serve this manifest",
		not http_source.can_serve(_manifest).ok,
		_why(http_source.can_serve(_manifest)))
	_check("it is still 'available' — nothing about it has failed",
		http_source.is_available())

	# The attempt budget is shared across sources, so a source that cannot serve
	# anything used to spend one of it per file on a guaranteed failure. Every
	# request the peer sees is one netchan got to make.
	var got := await client.acquire_manifest(_manifest)
	_check("the acquire failed", not got.ok)
	_check("netchan got the whole attempt budget",
		server.requests.size() == client.config.max_attempts_per_file,
		"%d requests for %d attempts" % [
			server.requests.size(), client.config.max_attempts_per_file
		])

	# Four failures with a threshold of three: netchan is now in cooldown and the
	# unusable HTTP source is the only candidate left. Its complaint used to be
	# the one the caller got.
	var netchan := _netchan(client)
	_check("netchan tripped its breaker", not netchan.is_available(),
		"%.0f s remaining" % netchan.cooldown_remaining_sec())

	var again := await client.acquire_manifest(_manifest)
	var why := _why(again)
	_check("the second acquire failed", not again.ok)
	_check("the failure names the source that backed off",
		why.contains("netchan") and why.contains("cooldown"), why)

	# Both sources are named, with what is wrong with each. What must not happen
	# is the old outcome: the unconfigured HTTP source speaking for the whole
	# download, because it was the only one still willing to be asked.
	_check("the HTTP source is listed as skipped, not as the cause",
		why.contains("No content source is available"), why)
	_check("the caller is told why, not only which file",
		why.contains("in cooldown for another"), why)

	# And the same thing structurally, which is the part a caller can branch on.
	# Everything above is a substring test against a sentence written for a
	# human; a game deciding whether to offer "Retry" or "Check your settings"
	# must not be doing that.
	var causes := client.downloader.last_failure_causes
	_check("every missing required file has a cause",
		causes.size() == 2, "got %d" % causes.size())
	_check("a cause names the file and a code",
		causes.size() == 2
			and causes[0].has("path") and causes[0].has("code"),
		str(causes))
	_check("the codes are DotError codes, not prose",
		client.downloader.failure_codes() == PackedStringArray([DotError.CODE_STATE]),
		str(client.downloader.failure_codes()))
	_check("describe() carries them too, for a bug report",
		(client.downloader.describe().get("failure_codes", PackedStringArray())
			as PackedStringArray).size() == 1,
		str(client.downloader.describe().get("failure_codes")))

	_drop(client)
	_sections_completed += 1


# --- helpers ---------------------------------------------------------------


func _server() -> RefCounted:
	var s := ChunkServer.new()
	s.objects_dir = _publish_dir
	s.host = self
	return s


func _client(tag: String, delegate: RefCounted) -> DotCloudClient:
	return await _client_on(tag, tag, delegate)


## As [method _client], but with the cache directory named separately, so two
## clients can be pointed at one cache.
func _client_on(tag: String, cache_tag: String, delegate: RefCounted) -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_%s" % cache_tag)
	config.require_signed_manifests = true
	config.trusted_keys = {"demo": str(_key_pair["public"])}
	config.verify_before_mount = true
	config.resume_downloads = true
	# One at a time so the delegate's request log reads in a deterministic order.
	config.parallel_downloads = 1

	var client := DotCloudClient.new()
	client.name = "CloudClient_%s" % tag
	client.config = config
	client.config_file = ""
	# No HTTP bases and no local search dirs: netchan is the only source that can
	# supply anything, which is the deployment this file exists to cover.
	client.http_base_urls = PackedStringArray()
	client.local_search_dirs = PackedStringArray()
	client.allow_netchan_fallback = true
	add_child(client)

	var started := await client.start()
	if not started.ok:
		_check("client '%s' started" % tag, false, str(started.error))
		client.queue_free()
		return null

	client.set_netchan_delegate(delegate)

	if _netchan(client) == null:
		_check("client '%s' has a netchan source" % tag, false)
		_drop(client)
		return null

	return client


func _netchan(client: DotCloudClient) -> DotCloudSourceNetchan:
	for s in client.sources:
		var nc := s as DotCloudSourceNetchan
		if nc != null:
			return nc
	return null


func _drop(client: DotCloudClient) -> void:
	remove_child(client)
	client.queue_free()


func _largest_file() -> DotCloudFile:
	var best: DotCloudFile = null
	for f in _manifest.files:
		if best == null or f.size > best.size:
			best = f
	return best


func _object_bytes(file: DotCloudFile) -> PackedByteArray:
	var res := DotPaths.read_bytes(
		_publish_dir.path_join("objects").path_join(file.object_path())
	)
	return res.value if res.ok else PackedByteArray()


func _first_offset_for(server: RefCounted, _sha256: String) -> int:
	if server.requests.is_empty():
		return -1
	return int(server.requests[0].x)


func _all_cached(client: DotCloudClient) -> bool:
	for f in _manifest.files:
		if not client.store.has(f.sha256):
			return false
	return true


func _payload_intact(client: DotCloudClient) -> bool:
	var target := _largest_file()
	if not client.store.has(target.sha256):
		return false
	return _sha256_of_cached(client, target) == target.sha256


func _sha256_of_cached(client: DotCloudClient, file: DotCloudFile) -> String:
	var path := client.store.path_for(file.sha256)
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)


func _has_code(res: DotResult, code: String) -> bool:
	return not res.ok and res.error != null and res.error.code == code


func _why(res: DotResult) -> String:
	return "" if res.ok else str(res.error)


func _finish(code: int = 0) -> void:
	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(code)


func _check(label: String, passed: bool, detail: String = "") -> void:
	if not passed:
		_failures += 1

	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail

	_line("  %s %s%s" % [label.rpad(52), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
