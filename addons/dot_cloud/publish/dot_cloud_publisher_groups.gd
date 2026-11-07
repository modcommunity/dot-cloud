extends RefCounted

## The `groups.json` rules of [DotCloudPublisher], in a file of their own so the publisher stays inside
## the size budget. Nothing here is used on its own.

const _Sides := preload("dot_cloud_publisher_sides.gd")


## Reads the source's `groups.json` and returns pack path -> PackedStringArray of the groups the file
## joins from it (a path in no rule is absent). Two shapes, mixable: [code]{"group": ["prefix/",
## "glob*"]}[/code] and [code]{"prefix/": "group"}[/code], the shape of `sides.json` and of
## [member DotCloudPublisher.group_rules]. Patterns follow the sides rules (a trailing `/` is a directory
## prefix; anything else is a `String.match` glob over the pack path, where `*` crosses `/`), and an
## `.import` marker also matches by the path of the asset it stands for. Refused as CODE_INVALID: a
## pattern that matches nothing (a typo would publish the files ungrouped and say nothing), an empty
## group, a pattern that is not a pack path, a malformed entry.
static func groups_for(pub: DotCloudPublisher, source_dir: String, relatives: PackedStringArray) -> DotResult:
	var file := source_dir.path_join(DotCloudPublisher.GROUPS_FILE)
	if not FileAccess.file_exists(file):
		return DotResult.success({})
	var read := DotPaths.read_json(file)
	if not read.ok:
		return read.wrap("Could not read %s." % DotCloudPublisher.GROUPS_FILE)
	if not (read.value is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "%s must be a JSON object." % DotCloudPublisher.GROUPS_FILE)

	var rules := _rules(read.value as Dictionary)
	if not rules.ok:
		return rules

	var hits := {}
	var out := {}
	for rel in relatives:
		var names := PackedStringArray([rel])
		if rel.ends_with(".import"):
			names.append(rel.trim_suffix(".import"))
		var groups := PackedStringArray()
		for rule: Array in rules.value:
			for n in names:
				if _Sides.pattern_matches(rule[0], n):
					hits[rule[0]] = true
					if not groups.has(rule[1]):
						groups.append(rule[1])
					break
		if not groups.is_empty():
			out[rel] = groups

	for rule: Array in rules.value:
		if not hits.has(rule[0]):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Group rule '%s' (group '%s') matches nothing in the pack." % [rule[0], rule[1]],
				"a typo here publishes the files ungrouped and says nothing"
			)
	DotLog.debug(DotCloudPublisher.CHANNEL, "group rules applied", {"content": pub.content_id, "grouped": out.size()})
	return DotResult.success(out)


## The file's entries as [[pattern, group], ...], validated.
static func _rules(doc: Dictionary) -> DotResult:
	var list: Array = []
	for key: Variant in doc:
		var value: Variant = doc[key]
		var pairs: Array = []
		if value is Array:
			if (value as Array).is_empty():
				return _bad("group '%s' lists no pattern" % key)
			for pattern: Variant in (value as Array):
				pairs.append([str(pattern), str(key)])
		elif value is String:
			pairs.append([str(key), str(value)])
		else:
			return _bad("'%s' must be a list of patterns or a group name" % key)
		for pair: Array in pairs:
			var pattern: String = pair[0]
			if str(pair[1]).strip_edges() == "":
				return _bad("an empty group name")
			if pattern.strip_edges() == "" or pattern.begins_with("res://") or pattern.begins_with("/"):
				return _bad("'%s' is not a pack path (relative to the source root, like worlds/ or worlds/a.*)" % pattern)
			list.append(pair)
	return DotResult.success(list)


static func _bad(why: String) -> DotResult:
	return DotResult.fail(DotError.CODE_INVALID, "%s: %s." % [DotCloudPublisher.GROUPS_FILE, why])
