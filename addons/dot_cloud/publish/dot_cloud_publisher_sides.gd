extends RefCounted

## The side rules and `provides.json` steps of [DotCloudPublisher], in a file of their own so the publisher
## stays inside the size budget. Nothing here is used on its own.

const CHANNEL := "cloud.pub"


## Reads, validates and completes the pack's `provides.json`; empty when the source has none.
## `runs_code` is computed here and never taken from the author's file, because a pack that says it is
## data and ships a script is what the scan exists to catch. Paths are checked against what ships.
static func provides_for(
	pub: DotCloudPublisher,
	source_dir: String,
	relatives: PackedStringArray,
	extra: Dictionary,
	dropped: Dictionary
) -> DotResult:
	var file := source_dir.path_join(DotCloudPublisher.PROVIDES_FILE)
	if not FileAccess.file_exists(file):
		return DotResult.success({})

	var read := DotPaths.read_json(file)
	if not read.ok:
		return read.wrap("Could not read %s." % DotCloudPublisher.PROVIDES_FILE)
	if not (read.value is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "%s must be a JSON object." % DotCloudPublisher.PROVIDES_FILE)

	var parsed := DotCloudProvides.parse(read.value as Dictionary, true)
	if not parsed.ok:
		return parsed.wrap("%s is invalid." % DotCloudPublisher.PROVIDES_FILE)
	var provides: Dictionary = parsed.value

	var shipped := {}
	for rel in relatives:
		shipped[rel] = true
	var exists := func(p: String) -> bool:
		return shipped.has(p) or dropped.has(p) or extra.has(p)
	var dir_exists := func(d: String) -> bool:
		var prefix := d.trim_suffix("/") + "/"
		for rel in relatives:
			if rel.begins_with(prefix):
				return true
		return false
	var checked := DotCloudProvides.check_files(provides, exists, dir_exists)
	if not checked.ok:
		return checked.wrap("%s does not match the pack." % DotCloudPublisher.PROVIDES_FILE)

	var reader := func(rel: String) -> PackedByteArray:
		return FileAccess.get_file_as_bytes(str(extra.get(rel, source_dir.path_join(rel))))
	var scanned := DotCloudScriptScan.scan(relatives, reader, provides)
	if not scanned.ok:
		return scanned
	provides["runs_code"] = bool((scanned.value as Dictionary)["runs_code"])
	if provides["runs_code"]:
		DotLog.info(CHANNEL, "pack runs code", {
			"content": pub.content_id, "why": ", ".join((scanned.value as Dictionary)["reasons"]),
		})
	return DotResult.success(provides)


## The side rules from [member DotCloudPublisher.side_rules] and the source's sides.json, as pattern -> side.
static func _load_rules(pub: DotCloudPublisher, source_dir: String) -> DotResult:
	var rules := {}
	for pattern: Variant in pub.side_rules:
		rules[str(pattern)] = str(pub.side_rules[pattern])

	var file := source_dir.path_join(DotCloudPublisher.SIDES_FILE)
	if FileAccess.file_exists(file):
		var read := DotPaths.read_json(file)
		if not read.ok:
			return read.wrap("Could not read %s." % DotCloudPublisher.SIDES_FILE)
		if not (read.value is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "%s must be a JSON object." % DotCloudPublisher.SIDES_FILE)
		var doc: Dictionary = read.value
		for key: Variant in doc:
			if not str(key) in [DotCloudFile.SIDE_CLIENT, DotCloudFile.SIDE_SERVER]:
				return DotResult.fail(
					DotError.CODE_INVALID,
					"%s: unknown key '%s'." % [DotCloudPublisher.SIDES_FILE, key],
					"expected client and server, each a list of patterns"
				)
			if not (doc[key] is Array):
				return DotResult.fail(
					DotError.CODE_INVALID, "%s: '%s' must be a list." % [DotCloudPublisher.SIDES_FILE, key]
				)
			for pattern: Variant in (doc[key] as Array):
				var p := str(pattern)
				if rules.has(p) and rules[p] != str(key):
					return DotResult.fail(
						DotError.CODE_INVALID,
						"%s: '%s' is listed for both sides." % [DotCloudPublisher.SIDES_FILE, p]
					)
				rules[p] = str(key)
	return DotResult.success(rules)


## Refuses a rule with an unknown side or a pattern that is not a pack path.
static func _validate_rules(rules: Dictionary) -> DotResult:
	for pattern: String in rules:
		var want: String = rules[pattern]
		if not want in [DotCloudFile.SIDE_CLIENT, DotCloudFile.SIDE_SERVER]:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Side rule '%s' names side '%s'." % [pattern, want],
				"a side is client or server; a file in no rule goes to both"
			)
		if pattern.strip_edges() == "" or pattern.begins_with("res://") or pattern.begins_with("/"):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Side rule '%s' is not a pack path." % pattern,
				"patterns are relative to the source root, like lightmaps/ or maps/*.res"
			)
	return DotResult.success()


## Each pack path's side, from `side_rules` and the source's `sides.json`; a path in no rule is absent
## (both sides). [param owners] maps a relocated imported output to the source asset it stands for.
static func sides_for(pub: DotCloudPublisher, source_dir: String, relatives: PackedStringArray, owners: Dictionary) -> DotResult:
	var loaded := _load_rules(pub, source_dir)
	if not loaded.ok:
		return loaded
	var rules: Dictionary = loaded.value

	var out := {}
	if rules.is_empty():
		return DotResult.success(out)

	var valid := _validate_rules(rules)
	if not valid.ok:
		return valid

	var hits := {}
	for rel in relatives:
		# The marker and the relocated output of an imported asset follow the asset, so a
		# rule written against the file a person sees covers what actually ships.
		var names := PackedStringArray([rel])
		if rel.ends_with(".import"):
			names.append(rel.trim_suffix(".import"))
		if owners.has(rel):
			names.append(str(owners[rel]))

		var side := DotCloudFile.SIDE_BOTH
		for pattern: String in rules:
			var matched := false
			for n in names:
				if pattern_matches(pattern, n):
					matched = true
					break
			if not matched:
				continue
			hits[pattern] = true
			if side != DotCloudFile.SIDE_BOTH and side != rules[pattern]:
				return DotResult.fail(
					DotError.CODE_INVALID,
					"'%s' is put on both sides by the side rules." % rel,
					"pattern '%s' says %s" % [pattern, rules[pattern]]
				)
			side = rules[pattern]

		if side == DotCloudFile.SIDE_BOTH:
			continue

		# Both sides read requires.json and provides.json before they mount; a client
		# loads the entry scene; a packer names what its own loader opens.
		var needs := pub.side_needs.duplicate()
		needs[DotAddonApi.REQUIREMENTS_FILE] = "both"
		needs[DotCloudPublisher.PROVIDES_FILE] = "both"
		if pub.entry_scene != "" and not needs.has(pub.entry_scene):
			needs[pub.entry_scene] = DotCloudFile.SIDE_CLIENT
		var need := str(needs.get(rel, ""))
		if need != "" and need != side:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"'%s' cannot be %s-only." % [rel, side],
				("the client and the server read it" if need == "both"
					else "the %s reads it" % need) + "; narrow the side rule"
			)
		out[rel] = side

	for pattern: String in rules:
		if not hits.has(pattern):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Side rule '%s' matches nothing in the pack." % pattern,
				"a typo here ships those files to both sides and says nothing"
			)

	DotLog.debug(CHANNEL, "side rules applied", {"content": pub.content_id, "sided": out.size()})
	return DotResult.success(out)


static func pattern_matches(pattern: String, rel: String) -> bool:
	if pattern.ends_with("/"):
		return rel.begins_with(pattern)
	return rel.match(pattern)
