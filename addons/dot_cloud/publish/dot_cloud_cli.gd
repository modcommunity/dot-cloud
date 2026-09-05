extends SceneTree

## Headless CLI for publishing content. Runs in CI.
##
## [codeblock]
## godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
##     publish --source content/dm_arena --out dist/dm_arena \
##     --id dm_arena --version 1.2.0 --entry arena.tscn \
##     --key keys/content.key --mirror https://cdn.example.com/dm_arena
##
## godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
##     keygen --private keys/content.key --public keys/content.pub
##
## godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
##     verify --manifest dist/dm_arena/manifest.json --public keys/content.pub
## [/codeblock]
##
## Extends [SceneTree] rather than being a plain script so [code]--script[/code]
## runs it as the main loop: it gets a working [code]user://[/code], resource
## loading and a clean exit code, none of which a bare script does.
##
## Exit codes: 0 success, 1 usage error, 2 operation failed. CI needs to be able
## to tell "you called it wrong" from "the content is bad".

const EXIT_OK := 0
const EXIT_USAGE := 1
const EXIT_FAILED := 2


func _initialize() -> void:
	DotLog.timestamps = false
	DotLog.set_level(DotLog.Level.INFO)

	var args := _user_args()

	if args.is_empty() or args[0] == "help" or args[0] == "--help":
		_usage()
		quit(EXIT_USAGE)
		return

	var command := args[0]
	var opts := _parse_options(args.slice(1))

	var code := EXIT_OK

	match command:
		"publish":
			code = _publish(opts)
		"keygen":
			code = _keygen(opts)
		"verify":
			code = _verify(opts)
		"inspect":
			code = _inspect(opts)
		_:
			printerr("Unknown command '%s'." % command)
			_usage()
			code = EXIT_USAGE

	quit(code)


# --- Commands --------------------------------------------------------------

func _publish(opts: Dictionary) -> int:
	var missing := _require(opts, ["source", "out", "id"])
	if missing != "":
		printerr("publish needs --%s" % missing)
		return EXIT_USAGE

	var pub := DotCloudPublisher.new()
	pub.content_id = str(opts["id"])
	pub.version = str(opts.get("version", "0.0.0"))
	pub.display_name = str(opts.get("name", ""))
	pub.entry_scene = str(opts.get("entry", ""))
	pub.mount_root = str(opts.get("mount-root", "dot_cloud"))
	pub.min_engine_version = str(opts.get("min-engine", ""))

	for m in _multi(opts, "mirror"):
		pub.mirrors.append(m)

	if opts.has("key"):
		var key_path := str(opts["key"])
		if not FileAccess.file_exists(key_path):
			printerr("Signing key not found: %s" % key_path)
			return EXIT_FAILED
		pub.signing_key_pem = FileAccess.get_file_as_string(key_path)
		pub.signing_key_id = str(opts.get("key-id", "default"))

	# --optional and --group accept repeated values, because a real content set
	# has several optional trees and hand-editing the manifest afterwards defeats
	# the point of a publisher.
	for prefix in _multi(opts, "optional"):
		pub.optional_prefixes.append(prefix)

	for rule in _multi(opts, "group"):
		var parts := rule.split("=", true, 1)
		if parts.size() == 2:
			pub.group_rules[parts[0]] = parts[1]
		else:
			printerr("--group expects prefix=name, got '%s'" % rule)
			return EXIT_USAGE

	for rule in _multi(opts, "platform"):
		var parts := rule.split("=", true, 1)
		if parts.size() == 2:
			pub.platform_rules[parts[0]] = parts[1].split(",", false)
		else:
			printerr("--platform expects prefix=tag[,tag], got '%s'" % rule)
			return EXIT_USAGE

	var res := pub.publish(str(opts["source"]), str(opts["out"]))

	if not res.ok:
		printerr("publish failed: %s" % str(res.error))
		return EXIT_FAILED

	var d: Dictionary = res.value
	print("")
	print("published %s" % (d["manifest"] as DotCloudManifest).key())
	print("  manifest    %s" % d["manifest_path"])
	print("  files       %d" % int(d["files"]))
	print("  objects     %d (%d written, %d deduplicated)" % [
		int(d["objects"]), int(d["objects_written"]), int(d["deduped"])
	])
	print("  size        %s" % DotPaths.format_bytes(int(d["bytes"])))
	print("  signed      %s" % ("yes" if bool(d["signed"]) else "NO"))

	if not bool(d["signed"]):
		print("")
		print("  A client with default settings will REFUSE this content.")
		print("  Sign it with --key, or set require_signed_manifests = false.")

	return EXIT_OK


func _keygen(opts: Dictionary) -> int:
	var private_path := str(opts.get("private", "content_signing.key"))
	var public_path := str(opts.get("public", "content_signing.pub"))

	if FileAccess.file_exists(private_path) and not opts.has("force"):
		printerr(
			"%s already exists. Pass --force to overwrite it — "
			% private_path
			+ "every client trusting the old key will refuse content signed "
			+ "with the new one."
		)
		return EXIT_FAILED

	var res := DotCloudPublisher.generate_keys(private_path, public_path)
	if not res.ok:
		printerr("keygen failed: %s" % str(res.error))
		return EXIT_FAILED

	print("")
	print("wrote %s (private — keep it secret)" % private_path)
	print("wrote %s (public — ship it in the client)" % public_path)
	print("")
	print("Add the public key to the client's DotCloudConfig.trusted_keys:")
	print("  config.trusted_keys[\"default\"] = <contents of %s>" % public_path)

	return EXIT_OK


func _verify(opts: Dictionary) -> int:
	var missing := _require(opts, ["manifest", "public"])
	if missing != "":
		printerr("verify needs --%s" % missing)
		return EXIT_USAGE

	var manifest_path := str(opts["manifest"])
	var read := DotPaths.read_bytes(manifest_path)
	if not read.ok:
		printerr("could not read manifest: %s" % str(read.error))
		return EXIT_FAILED

	var parsed := DotCloudManifest.from_json_bytes(read.value)
	if not parsed.ok:
		printerr("manifest is invalid: %s" % str(parsed.error))
		return EXIT_FAILED

	var manifest: DotCloudManifest = parsed.value

	var pem := FileAccess.get_file_as_string(str(opts["public"]))
	if pem == "":
		printerr("could not read public key: %s" % opts["public"])
		return EXIT_FAILED

	var res := DotCloudSignature.verify(
		manifest.raw_bytes, manifest.signature, pem
	)

	if not res.ok:
		printerr("SIGNATURE INVALID: %s" % str(res.error))
		return EXIT_FAILED

	print("signature OK for %s" % manifest.key())
	return EXIT_OK


func _inspect(opts: Dictionary) -> int:
	var missing := _require(opts, ["manifest"])
	if missing != "":
		printerr("inspect needs --%s" % missing)
		return EXIT_USAGE

	var read := DotPaths.read_bytes(str(opts["manifest"]))
	if not read.ok:
		printerr("could not read manifest: %s" % str(read.error))
		return EXIT_FAILED

	var parsed := DotCloudManifest.from_json_bytes(read.value)
	if not parsed.ok:
		printerr("manifest is invalid: %s" % str(parsed.error))
		return EXIT_FAILED

	var manifest: DotCloudManifest = parsed.value
	var d := manifest.describe()

	print("")
	var keys := d.keys()
	keys.sort()
	for k in keys:
		print("  %-14s %s" % [str(k), str(d[k])])

	if bool(opts.get("files", false)):
		print("")
		for f in manifest.files:
			print("  %-10s %-64s %s" % [
				DotPaths.format_bytes(f.size), f.path, f.sha256.substr(0, 16)
			])

	return EXIT_OK


# --- Argument handling ----------------------------------------------------

## Arguments after [code]--[/code].
##
## Godot consumes everything before it; the separator is the only reliable way to
## pass flags of our own without them being interpreted as engine options.
func _user_args() -> PackedStringArray:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		return args

	# Fall back to scanning for our own commands, so a run without `--` still
	# does something useful rather than printing usage and confusing the caller.
	var all := OS.get_cmdline_args()
	for i in range(all.size()):
		if ["publish", "keygen", "verify", "inspect", "help"].has(all[i]):
			return all.slice(i)

	return PackedStringArray()


## Parses [code]--key value[/code], [code]--key=value[/code] and bare
## [code]--flag[/code]. Repeated keys collect into an [Array].
func _parse_options(args: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0

	while i < args.size():
		var arg := args[i]
		i += 1

		if not arg.begins_with("--"):
			continue

		var body := arg.substr(2)
		var key := body
		var value: Variant = true

		if body.contains("="):
			var parts := body.split("=", true, 1)
			key = parts[0]
			value = parts[1]
		elif i < args.size() and not args[i].begins_with("--"):
			value = args[i]
			i += 1

		if out.has(key):
			if out[key] is Array:
				(out[key] as Array).append(value)
			else:
				out[key] = [out[key], value]
		else:
			out[key] = value

	return out


## The first missing required option, or [code]""[/code].
func _require(opts: Dictionary, keys: Array) -> String:
	for k in keys:
		if not opts.has(k) or opts[k] is bool:
			return str(k)
	return ""


## Every value for a possibly-repeated option.
func _multi(opts: Dictionary, key: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not opts.has(key):
		return out

	var v: Variant = opts[key]
	if v is Array:
		for item in (v as Array):
			out.append(str(item))
	elif not (v is bool):
		out.append(str(v))

	return out


func _usage() -> void:
	print("""
dot-cloud content publisher

  godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- <command> [options]

Commands

  publish   Build a manifest and object tree from a directory.
    --source DIR         content to publish                        (required)
    --out DIR            output directory                          (required)
    --id NAME            content id, lowercase [a-z0-9_-]          (required)
    --version V          content version                           (0.0.0)
    --name TEXT          display name
    --entry PATH         entry scene, relative to the content root
    --mount-root NAME    res:// subdirectory to mount under        (dot_cloud)
    --min-engine V       minimum Godot version
    --mirror URL         base URL clients fetch from  (repeatable)
    --key PATH           private key PEM; omit to publish unsigned
    --key-id NAME        key identifier written into the manifest  (default)
    --optional PREFIX    mark files under PREFIX optional (repeatable)
    --group PREFIX=NAME  assign files under PREFIX to a group (repeatable)
    --platform PREFIX=TAGS  restrict files under PREFIX to platform tags

  keygen    Generate an RSA signing keypair.
    --private PATH       where to write the private key
    --public PATH        where to write the public key
    --force              overwrite an existing private key

  verify    Check a published manifest's signature.
    --manifest PATH      manifest.json                             (required)
    --public PATH        public key PEM                            (required)

  inspect   Print a manifest's contents.
    --manifest PATH      manifest.json                             (required)
    --files              also list every file

Exit codes: 0 ok, 1 usage error, 2 operation failed.
""".strip_edges())
