extends RefCounted

## The UID registration of [DotCloudMounter], in a file of their own so the mounter stays inside the size
## budget. Nothing here is used on its own.

const CHANNEL := "cloud.mount"


## Points every UID this pack declares at its file inside the mount, so an imported binary's UID references resolve.
## A pack may claim a UID nothing owns, not TAKE one (ids are process-global; `add_only` skips ids outside its own mounts).
## Returns how many were registered.
static func register(
	files: Array[DotCloudFile],
	prefix: String,
	mount_root: String,
	add_only: bool = false,
	content_id: String = "",
	skipped: Array = []
) -> int:
	var registered := 0
	var refused := 0
	var content_root := "res://%s/" % mount_root

	for f in files:
		if not f.path.to_lower().ends_with(".import"):
			continue

		var marker := prefix.path_join(f.path)
		var text := FileAccess.get_file_as_string(marker)

		if text == "":
			continue

		var uid_text := uid_in(text)

		if uid_text == "":
			continue

		var id := ResourceUID.text_to_id(uid_text)

		if id == ResourceUID.INVALID_ID:
			continue

		# The SOURCE file, not the imported output: the marker's uid identifies what a scene refers to, and the
		# engine follows the marker to the imported bytes. Registering the `.scn` would return it where a texture was asked for.
		var source := marker.trim_suffix(".import")

		if not ResourceLoader.exists(source) and not FileAccess.file_exists(source):
			continue

		# `set_id` when the host knows the id, `add_id` when not: the wrong one is an error, not an update.
		# Only a host that mounted an earlier version of this pack may have an id moved.
		if ResourceUID.has_id(id):
			var held := ResourceUID.get_id_path(id)

			if add_only and not held.begins_with("%s%s/" % [content_root, content_id]):
				skipped[0] = int(skipped[0]) + 1
				continue

			if not held.begins_with(content_root):
				DotLog.warn(CHANNEL, "a pack claims a uid the host already owns; refused", {
					"uid": uid_text, "held": held, "wanted": source,
				})
				refused += 1
				continue

			ResourceUID.set_id(id, source)
		else:
			ResourceUID.add_id(id, source)

		registered += 1

	if refused > 0:
		DotLog.error(CHANNEL, "a pack tried to take uids that are not its own", {
			"refused": refused, "prefix": prefix,
		})

	return registered


## The `uid="uid://…"` line of an import marker, or empty.
static func uid_in(text: String) -> String:
	for line in text.split("\n"):
		var trimmed := line.strip_edges()

		if not trimmed.begins_with("uid="):
			continue

		return trimmed.substr(4).strip_edges().trim_prefix("\"").trim_suffix("\"")

	return ""
