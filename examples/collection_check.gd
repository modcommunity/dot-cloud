extends Node

## Loads a published collection (a manifest with no payload beyond its licence that lists map packs) and reports the aggregate job.
## Resolves and verifies the collection and every dependency manifest, prints the totals the one progress bar
## would show; with --download also fetches everything into a temp cache and prints the final snapshot.
## Run: godot --headless --path . res://examples/collection_check.tscn -- --base URL --key PEM --key-id ID \
##        --id gamemann/game-arena-all-maps --version 1.0.0 [--download] [--min-packs N]

const CHANNEL := "collection_check"

var _failures := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	var args := _parse(OS.get_cmdline_user_args())
	if not args.has("base") or not args.has("id"):
		print("collection_check: pass --base URL --id ID --version V --key PEM|--key-b64 B64 [--key-id ID] [--download] [--min-packs N]; nothing to check")
		get_tree().quit(0)
		return
	await _run(args)
	get_tree().quit(1 if _failures > 0 else 0)


func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var k := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[k] = argv[i + 1]
				i += 1
			else:
				out[k] = true
		i += 1
	return out


func _check(name: String, ok: bool, detail: String = "") -> void:
	print("  %s  %s%s" % ["ok  " if ok else "FAIL", name, "" if ok or detail == "" else " (" + detail + ")"])
	if not ok:
		_failures += 1


func _run(args: Dictionary) -> void:
	var pem := Marshalls.base64_to_utf8(str(args["key-b64"])) if args.has("key-b64") else FileAccess.get_file_as_string(str(args.get("key", "")))
	var cache := OS.get_temp_dir().path_join("dot_cloud_collection_check_%d" % OS.get_process_id())
	var config := DotCloudConfig.new()
	config.cache_dir = cache
	config.require_signed_manifests = true
	config.trusted_keys = {str(args.get("key-id", "default")): pem}
	var client := DotCloudClient.new()
	client.config = config
	client.config_file = ""
	client.register_service = false
	client.allow_netchan_fallback = false
	client.http_base_urls = PackedStringArray([str(args["base"])])
	add_child(client)

	var id := StringName(str(args["id"]))
	var version := str(args.get("version", ""))
	var res := await client.resolve_manifest(id, version)
	_check("collection manifest verifies (signature, id, version)", res.ok, str(res.error) if not res.ok else "")
	if not res.ok:
		return
	var coll: DotCloudManifest = res.value
	_check("the collection carries at most its licence file", coll.files.size() <= 1, str(coll.files.size()))
	var deps: Array[Dictionary] = coll.dependencies
	_check("it names at least %d packs" % int(args.get("min-packs", 1)), deps.size() >= int(args.get("min-packs", 1)), str(deps.size()))

	var total_files := 0
	var total_bytes := 0
	var bad := PackedStringArray()
	for d in deps:
		var dr := await client.resolve_manifest(StringName(str(d["id"])), str(d["version"]))
		if not dr.ok:
			bad.append("%s@%s" % [d["id"], d["version"]])
			continue
		var m: DotCloudManifest = dr.value
		total_files += m.wanted_files().size()
		for f in m.wanted_files():
			total_bytes += f.size
	_check("every dependency manifest verifies", bad.is_empty(), ", ".join(bad))
	print("  plan: %d packs, %d files, %s" % [deps.size(), total_files, DotPaths.format_bytes(total_bytes)])

	if args.has("download"):
		var snaps: Array = []
		client.job_progress_changed.connect(func(s: Dictionary) -> void: snaps.append(s))
		client.begin_job("collection_check")
		var reg := await client.job_register(deps)
		_check("every pack registers before any byte moves", reg.ok and not snaps.is_empty(), str(reg.error) if not reg.ok else "")
		var from := snaps.size()
		var fixed := int(snaps[-1].get("total_bytes", 0)) if not snaps.is_empty() else 0
		var dl := await client.job_download()
		_check("the download pass completes", dl.ok and dl.value.is_empty(), str(dl.value))
		var ordered := true
		var prev := -1.0
		for s: Dictionary in snaps.slice(from):
			ordered = ordered and int(s["total_bytes"]) == fixed and float(s["fraction"]) >= prev and str(s["phase"]) == "download"
			prev = float(s["fraction"])
		_check("the total stayed fixed and the bar never went back", ordered and fixed > 0, "total %d" % fixed)
		var mid := snaps.size()
		client.job_begin_unpack()
		var got := await client.ensure(id, version)
		client.end_job()
		_check("the collection mounts from the store", got.ok, str(got.error) if not got.ok else "")
		var after_bytes := true
		for s: Dictionary in snaps.slice(mid):
			after_bytes = after_bytes and int(s["done_bytes"]) == fixed
		_check("unpacking moved no bytes", after_bytes)
		var s: Dictionary = snaps[-1]
		_check("one job counted every pack", int(s.get("total_packs", 0)) >= deps.size() and int(s.get("done_packs", 0)) == int(s.get("total_packs", 0)), str(s))
		print("  job: %d of %d packs, %d of %d bytes, unpacked %d of %d" % [s.get("done_packs", 0), s.get("total_packs", 0), s.get("done_bytes", 0), s.get("total_bytes", 0), s.get("unpack_done", 0), s.get("unpack_total", 0)])
	DotPaths.remove_tree(cache)
	print("\ncollection_check: %d failed" % _failures)
