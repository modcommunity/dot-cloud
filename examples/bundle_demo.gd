extends Control
## Proves the small-object bundle: a cold acquire is one archive request plus the big objects, a
## warm one is no request at all, and a corrupt archive falls back to per-file fetching.
## Run: godot --headless --path . res://examples/bundle_demo.tscn

const TestServer := preload("res://examples/http_test_server.gd")
const WORK := "user://dot_cloud_bundle_demo"
const SMALL := 40
const CHECKS := 19

@onready var _output: RichTextLabel = $Output

var _failures: int = 0
var _checks: int = 0
var _server: Node = null
var _key_pair: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	DotPaths.remove_tree(WORK)
	var keys := DotCloudSignature.generate_keypair(2048)
	_key_pair = keys.value
	var src := WORK.path_join("source")
	DotPaths.ensure_dir(src)
	for i in SMALL:
		var body := PackedByteArray()
		body.resize(200 + i)
		for j in body.size():
			body[j] = (i * 7 + j) & 0xFF
		DotPaths.write_bytes(src.path_join("imp/file_%03d.ctex" % i), body)
	var big := PackedByteArray()
	big.resize(3 * 1024 * 1024)
	for j in big.size():
		big[j] = (j * 13 + (j >> 9)) & 0xFF
	DotPaths.write_bytes(src.path_join("big.bin"), big)

	var pub := DotCloudPublisher.new()
	pub.content_id = "bundle_arena"
	pub.version = "1.0.0"
	pub.entry_scene = "big.bin"
	pub.signing_key_pem = str(_key_pair["private"])
	var published := pub.publish(src, WORK.path_join("published"))
	_check("published", published.ok, "" if published.ok else str(published.error))
	var manifest: DotCloudManifest = published.value["manifest"]
	var decl := manifest.usable_bundle()
	_check("manifest declares a bundle of the small objects", int(decl.get("count", 0)) == SMALL, str(decl.get("count")))
	_check("the bundle is far smaller than the pack", int(decl.get("size", 1 << 30)) < 3 * 1024 * 1024)

	var solo_meta := {"solo": true}
	var omitted := DotCloudRegistry.complete_body(1, 2, 3, "sha")
	var declared := DotCloudRegistry.complete_body(1, 2, 3, "sha", {}, DotCloudRegistry.solo_from_metadata(solo_meta))
	_check("solo is omitted from complete unless declared", not omitted.has("solo"))
	_check("metadata.solo true is sent as solo in complete", declared.get("solo", false) == true)
	_check("metadata without solo, or solo false, reads false",
		not DotCloudRegistry.solo_from_metadata({}) and not DotCloudRegistry.solo_from_metadata({"solo": false}))
	_check("the published manifest carries metadata", manifest.metadata is Dictionary)

	_server = TestServer.new()
	_server.root = WORK.path_join("published")
	add_child(_server)
	_server.start(0)
	var base: String = _server.base_url()

	await _cold_then_warm(base)
	await _corrupt_bundle(base)

	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	_line("done" if _failures == 0 else "%d check(s) FAILED" % _failures)
	_server.stop()
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


func _cold_then_warm(base: String) -> void:
	_server.log.clear()
	var client := await _make_client("shared", base)
	var acquired := await client.acquire(base + "/manifest.json")
	_check("cold acquire ok", acquired.ok, "" if acquired.ok else str(acquired.error))
	_check("one bundle request", _count("/bundles/") == 1, str(_count("/bundles/")))
	_check("only the oversized object fetched singly", _count("/objects/") == 1, str(_count("/objects/")))
	_drop(client)

	_server.log.clear()
	var again := await _make_client("shared", base)
	var re := await again.acquire(base + "/manifest.json")
	_check("warm acquire ok", re.ok)
	_check("warm acquire requests no bundle", _count("/bundles/") == 0)
	_check("warm acquire requests no objects", _count("/objects/") == 0)
	_check("manifest is the only request", _count("GET /manifest.json") == 1)
	_drop(again)


func _corrupt_bundle(base: String) -> void:
	var path := ""
	var dir := DirAccess.open(WORK.path_join("published/bundles"))
	for n in dir.get_files():
		path = "/bundles/" + n
	_server.corrupt_paths.append(path)
	_server.log.clear()
	var client := await _make_client("corrupt", base)
	var acquired := await client.acquire(base + "/manifest.json")
	_check("a corrupt bundle does not fail the acquire", acquired.ok, "" if acquired.ok else str(acquired.error))
	_check("it was requested once", _count("/bundles/") == 1)
	_check("every object fell back to its own request", _count("/objects/") == SMALL + 1, str(_count("/objects/")))
	_check("the mounted content is readable",
		FileAccess.file_exists("res://dot_cloud/bundle_arena/1.0.0/imp/file_000.ctex"))
	_drop(client)
	_server.corrupt_paths.clear()


func _count(needle: String) -> int:
	var n := 0
	for l in _server.log:
		if str(l).contains(needle):
			n += 1
	return n


func _make_client(tag: String, base: String) -> DotCloudClient:
	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache_%s" % tag)
	config.trusted_keys = {"demo": str(_key_pair["public"])}
	config.require_signed_manifests = true
	config.parallel_downloads = 4
	var client := DotCloudClient.new()
	client.config = config
	client.config_file = ""
	client.http_base_urls = PackedStringArray([base])
	client.allow_netchan_fallback = false
	add_child(client)
	await client.start()
	return client


func _drop(client: DotCloudClient) -> void:
	remove_child(client)
	client.queue_free()


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1
	_line("  %s %s%s" % [label.rpad(52), "ok" if passed else "FAILED", (" (%s)" % detail) if detail != "" else ""])


func _line(text: String) -> void:
	print(text)
	if _output != null:
		_output.append_text(text + "\n")
