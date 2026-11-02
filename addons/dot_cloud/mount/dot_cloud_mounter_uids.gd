extends RefCounted

## The UID registration of [DotCloudMounter], in a file of their own so the mounter stays inside the size
## budget. Nothing here is used on its own.

const CHANNEL := "cloud.mount"


## Points every UID this pack declares at the file inside the mount.
##
## [b]An imported asset carries a dependency this addon cannot rewrite, and until this
## existed nothing could load one.[/b] The publisher rewrites `res://` strings inside TEXT
## resources and says so; a `.glb`, a `.png` or anything else the engine imports becomes a
## BINARY `.scn`/`.ctex` under `.godot/imported/`, and its references to its own siblings
## are recorded as a UID with the authored path as a fallback. Neither survives being
## mounted somewhere else: the UID is not registered in the host, so the loader falls back
## to the path — and the path names the project the asset was authored in.
##
## [codeblock]
## invalid UID: 'uid://reboanwombd2' - using text path instead:
##     'res://assets/kenney/survival/Textures/colormap.png'
## Resource file not found: res://assets/kenney/survival/Textures/colormap.png
## [/codeblock]
##
## Measured in game-buses-from-hell, the first game in this family to vendor art: the
## crates' meshes loaded, their texture did not, and the scene node the model was
## instanced under "vanished" — a game that plays perfectly and appears to have shipped
## with no art. [b]Nothing reported it as an error[/b]; both lines above are warnings, and
## the pack, the mount and the scene load all succeeded.
##
## The fix is the half the engine leaves to the host: `ResourceUID` is writable at
## runtime, and every import marker in the pack names both a UID and the file it belongs
## to. So on mount, each one is pointed at the mounted copy, and the binary form's own
## reference resolves — with no rewriting of bytes anywhere.
##
## [b]A pack may claim a UID nothing else owns, and may not TAKE one.[/b] `ResourceUID` is
## global to the process, so registering an id the host already uses would re-point every
## `load("uid://…")` in the build at a file inside downloaded content — an addon's script,
## a shell's scene — which is a mounted pack reaching outside its own prefix by another
## route. That is the thing `enforce_mount_prefix` exists to stop, so the same rule applies
## here: an id whose current path is outside any mount is refused and reported, and one
## that points into content (this pack, or an earlier version of it) is updated.
##
## Returns how many were registered, for the mount's log line.
##
## [b]`add_only` (a subscription's mount) is stricter still.[/b] The rule above lets an id
## move when it points into any mounted content, which is right for a second version of the
## same pack and wrong for a stranger's pack that happens to reuse an id of a game pack or a
## server's map: it would re-point that content for the rest of the process, online sessions
## included. So under `add_only` an id already registered to a path outside THIS content id's
## own mounts is skipped and counted in [param skipped], and only unknown ids are added.
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

		# [b]The SOURCE file, not the imported output.[/b] An import marker's `uid` is the
		# identity of the thing a scene refers to — `res://…/colormap.png` — and the
		# engine resolves that id and then follows the marker beside it to the imported
		# bytes. Registering the `.scn` instead would hand back an imported resource where
		# a texture was asked for.
		var source := marker.trim_suffix(".import")

		if not ResourceLoader.exists(source) and not FileAccess.file_exists(source):
			continue

		# `set_id` when the host already knows the id and `add_id` when it does not: the
		# two are separate calls and the wrong one is an error rather than an update. A
		# host that mounted an earlier version of the same pack knows it — and that is the
		# ONLY case an existing id may be moved, per the note above.
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
