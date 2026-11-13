extends Node

## DotCloudSourceHttp under a CDN that answers 429/503: waits (Retry-After first), retries the same base,
## never lets a later base's 404 end the download, and stops after a bounded number of tries.
## Runs the web download path (in memory through DotHttp._request), the one the web shell uses.
## Run: godot --headless --path . res://examples/http_throttle_selftest.tscn

const TestServer := preload("res://examples/http_test_server.gd")
const WORK := "user://dot_cloud_http_throttle"
const CHECKS := 21

var _failures := 0
var _checks := 0
var _cdn: Node = null
var _empty: Node = null
var _engine_wrote := true


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_engine_wrote = DotHttp._engine_writes_downloads
	DotHttp._engine_writes_downloads = false
	_test_delay_rules()
	DotPaths.remove_tree(WORK)
	var objects := _publish("objects", 3, false)
	var bundled := _publish("bundled", 10, true)
	_cdn = _serve(WORK.path_join("objects"))
	_empty = _serve(WORK.path_join("empty"))
	if objects != null and bundled != null and _cdn != null and _empty != null:
		await _test_throttled_then_served(objects)
		await _test_endless_throttle(objects)
		await _test_server_error(objects)
		_cdn.root = WORK.path_join("bundled")
		await _test_bundle_throttled(bundled)
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	DotHttp._engine_writes_downloads = _engine_wrote
	for s in [_cdn, _empty]:
		if s != null:
			s.stop()
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _test_delay_rules() -> void:
	var s := DotCloudSourceHttp.new()
	s.backoff_base_sec = 0.5
	s.backoff_max_sec = 20.0
	var told := DotError.from_http(429)
	told.retry_after = 3.0
	_check("Retry-After is the wait", is_equal_approx(s.backoff_delay(1, told), 3.0), str(s.backoff_delay(1, told)))
	told.retry_after = 600.0
	_check("a huge Retry-After is capped", is_equal_approx(s.backoff_delay(1, told), 20.0))
	var bare := DotError.from_http(429)
	var d1 := s.backoff_delay(1, bare)
	var d3 := s.backoff_delay(3, bare)
	_check("no Retry-After: exponential with jitter", d1 >= 0.4 and d1 <= 0.6 and d3 >= 1.6 and d3 <= 2.4, "%f %f" % [d1, d3])
	_check("429 and 5xx retry, 404 does not",
		s.retry_limit(DotError.from_http(429)) == s.throttle_retries
		and s.retry_limit(DotError.from_http(503)) == s.server_error_retries
		and s.retry_limit(DotError.from_http(404)) == 0 and s.retry_limit(null) == 0)


## The live failure: every object 429s a few times on the CDN, and the next base 404s all of them.
func _test_throttled_then_served(manifest: DotCloudManifest) -> void:
	_cdn.throttle_retry_after = 1
	_cdn.throttle_paths = _object_paths(manifest, 3)
	_cdn.log.clear()
	var client := await _client("served", [_cdn.base_url(), _empty.base_url()])
	var t0 := Time.get_ticks_msec()
	var got: DotResult = await client.acquire_manifest(manifest)
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	_check("throttled objects are acquired, not lost to the 404 base", got.ok, str(got.error))
	_check("every object was asked again until served", _count(_cdn.log, "-> 429") == 3 * _object_paths(manifest, 1).size(), str(_cdn.log))
	_check("Retry-After was waited out", secs >= 2.0, "%.2f s" % secs)
	var src := _source(client)
	_check("the throttled base stays preferred", str(src.health()["preferred"]) == _cdn.base_url(), str(src.health()))
	_check("and is not demoted as failing", (src.health()["cooling_bases"] as Array).is_empty(), str(src.health()))
	_drop(client)


## A host that never stops answering 429: retries end, and the reported error is the 429, not the next base's 404.
func _test_endless_throttle(manifest: DotCloudManifest) -> void:
	_cdn.throttle_retry_after = -1
	_cdn.throttle_paths = _object_paths(manifest, 1000)
	_cdn.log.clear()
	var client := await _client("endless", [_cdn.base_url(), _empty.base_url()])
	var src := _source(client)
	src.throttle_retries = 1
	src.backoff_base_sec = 0.05
	src.http.retry_base_sec = 0.05
	var t0 := Time.get_ticks_msec()
	var got: DotResult = await client.acquire_manifest(manifest)
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	_check("an endless 429 gives up", not got.ok)
	_check("reporting the throttle, not the 404", not got.ok and _rooted_in(got, DotError.CODE_RATE_LIMITED), str(got.error))
	var per_file := (src.throttle_retries + 1) * (src.http.max_retries + 1) * client.config.max_attempts_per_file
	var most := per_file * _object_paths(manifest, 1).size()
	_check("in a bounded number of requests", _count(_cdn.log, "-> 429") <= most, "%d > %d" % [_count(_cdn.log, "-> 429"), most])
	_check("and bounded time", secs < 30.0, "%.1f s" % secs)
	_cdn.throttle_paths = {}
	_drop(client)


## A 503 is retried on the same base once before failover.
func _test_server_error(manifest: DotCloudManifest) -> void:
	_cdn.unavailable_paths = _object_paths(manifest, 2)
	_cdn.log.clear()
	var client := await _client("unavailable", [_cdn.base_url(), _empty.base_url()])
	_source(client).backoff_base_sec = 0.05
	_source(client).http.retry_base_sec = 0.05
	var got: DotResult = await client.acquire_manifest(manifest)
	_check("objects behind a passing 503 are acquired", got.ok, str(got.error))
	_check("from the same base", _count(_cdn.log, "-> 503") == 2 * _object_paths(manifest, 1).size(), str(_cdn.log))
	_drop(client)


## The bundle request is throttled the same way, and still replaces the per-object requests.
func _test_bundle_throttled(manifest: DotCloudManifest) -> void:
	var path := "/" + str(manifest.usable_bundle()["url_path"]).trim_prefix("/")
	_cdn.throttle_retry_after = 1
	_cdn.throttle_paths = {path: 3}
	_cdn.log.clear()
	var client := await _client("bundle", [_cdn.base_url(), _empty.base_url()])
	var got: DotResult = await client.acquire_manifest(manifest)
	_check("a throttled bundle is acquired", got.ok, str(got.error))
	_check("the bundle was asked again until served", Array(_cdn.log).has("GET %s" % path), str(_cdn.log))
	_check("so no object went one by one", _count(_cdn.log, "/objects/") == 0, str(_cdn.log))
	_drop(client)


func _publish(tag: String, files: int, bundle: bool) -> DotCloudManifest:
	var src := WORK.path_join("src_" + tag)
	DotPaths.ensure_dir(src)
	DotPaths.ensure_dir(WORK.path_join("empty"))
	for i in files:
		DotPaths.write_text(src.path_join("f%02d.txt" % i), ("%s file %d\n" % [tag, i]).repeat(64))
	var pub := DotCloudPublisher.new()
	pub.content_id = "throttle_" + tag
	pub.version = "1.0.0"
	pub.entry_scene = "f00.txt"
	pub.write_bundle = bundle
	var out := pub.publish(src, WORK.path_join(tag))
	if not out.ok:
		_check("publish %s" % tag, false, str(out.error))
		return null
	var parsed := DotCloudManifest.from_json_bytes(DotPaths.read_bytes(str(out.value["manifest_path"])).value)
	_check("published %s" % tag, parsed.ok and (not bundle or not parsed.value.usable_bundle().is_empty()), str(parsed.error))
	return parsed.value if parsed.ok else null


func _serve(root: String) -> Node:
	var s: Node = TestServer.new()
	s.root = root
	add_child(s)
	var started: DotResult = s.start(0)
	if not started.ok:
		_check("server for %s" % root, false, str(started.error))
		return null
	return s


func _client(tag: String, bases: Array) -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_" + tag)
	config.require_signed_manifests = false
	config.file_timeout_sec = 20.0
	var client := DotCloudClient.new()
	client.config = config
	client.config_file = ""
	client.http_base_urls = PackedStringArray(bases)
	client.allow_netchan_fallback = false
	add_child(client)
	await client.start()
	return client


func _drop(client: DotCloudClient) -> void:
	remove_child(client)
	client.queue_free()


func _source(client: DotCloudClient) -> DotCloudSourceHttp:
	for s in client.sources:
		if s is DotCloudSourceHttp:
			return s
	return null


func _object_paths(manifest: DotCloudManifest, times: int) -> Dictionary:
	var out := {}
	for f in manifest.files:
		out["/objects/%s" % f.object_path()] = times
	return out


func _rooted_in(res: DotResult, code: String) -> bool:
	return res.code() == code or str(res.error).contains("[%s]" % code)


static func _count(lines: PackedStringArray, needle: String) -> int:
	var n := 0
	for l in lines:
		if l.contains(needle):
			n += 1
	return n


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	print("  %s  %s%s" % ["ok  " if passed else "FAIL", label, "" if passed or detail == "" else " (" + detail + ")"])
	if not passed:
		_failures += 1
