extends RefCounted

## The `res://` rewrite of [DotCloudPublisher], in a file of its own so the publisher stays inside the size budget.
## Nothing here is used on its own.


## Rewrites `res://X` to the pack's mount prefix for every X in [param inside]; returns the staged path, or "" when nothing changed.
static func rewrite_paths(abs: String, staged: String, inside: Dictionary, mount_root: String, content_id: String, version: String) -> DotResult:
	var text := FileAccess.get_file_as_string(abs)
	if text == "" and FileAccess.get_open_error() != OK:
		return DotResult.fail(DotError.CODE_IO, "Could not read the file.", abs)

	var prefix := "res://%s/%s/%s/" % [mount_root, content_id, version]
	var out := ""
	var i := 0
	var changed := false

	while true:
		var at := text.find("res://", i)
		if at < 0:
			out += text.substr(i)
			break

		out += text.substr(i, at - i)

		# The reference ends at the first character that cannot be in a path. Scenes
		# quote them, but .tres and a stray comment do not always, so this stops at
		# whitespace and quotes rather than assuming a delimiter.
		var j := at + 6
		while j < text.length():
			var c := text[j]
			if c == '"' or c == "'" or c == " " or c == "\t" or c == "\n" or c == "\r" or c == ")":
				break
			j += 1

		var path := text.substr(at + 6, j - (at + 6))

		# Already under this version: leave it, or a republish buries the content a level deeper.
		var stale := _strip_other_version(path, mount_root, content_id, version)
		if stale != "" and inside.has(stale):
			out += prefix + str(inside[stale])
			changed = true
		elif inside.has(path) and not path.begins_with("%s/%s/%s/" % [mount_root, content_id, version]):
			out += prefix + str(inside[path])
			changed = true
		else:
			out += "res://" + path

		i = j

	var other := foreign_version(out, mount_root, content_id, version)
	if other != "":
		return DotResult.fail(DotError.CODE_INVALID, "'%s' still names pack version %s while publishing %s." % [abs, other, version], abs)

	if not changed:
		return DotResult.success("")

	var parent := DotPaths.ensure_parent_dir(staged)
	if not parent.ok:
		return parent

	var f := FileAccess.open(staged, FileAccess.WRITE)
	if f == null:
		return DotResult.fail(
			DotError.CODE_IO, "Could not write the rewritten file.", staged
		)
	f.store_string(out)
	f.close()

	return DotResult.success(staged)


## The path under another version of this pack ("" when it is not one): `dot_cloud/arena/0.1.24/a.gd` gives `a.gd`.
static func _strip_other_version(path: String, mount_root: String, content_id: String, version: String) -> String:
	var head := "%s/%s/" % [mount_root, content_id]
	if not path.begins_with(head) or path.begins_with(head + version + "/"):
		return ""
	var rest := path.substr(head.length())
	var slash := rest.find("/")
	return "" if slash < 0 else rest.substr(slash + 1)


## The first other version of this pack that [param text] names, or "". A pack that mounts must name only its own.
static func foreign_version(text: String, mount_root: String, content_id: String, version: String) -> String:
	var head := "res://%s/%s/" % [mount_root, content_id]
	var i := 0
	while true:
		var at := text.find(head, i)
		if at < 0:
			return ""
		var start := at + head.length()
		var slash := text.find("/", start)
		var v := text.substr(start, (slash if slash >= 0 else text.length()) - start)
		if v != version:
			return v
		i = start
	return ""
