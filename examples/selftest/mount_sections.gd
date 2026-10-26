extends RefCounted

## Sections of mount_demo.gd that only need its checker, in a file of their own so the demo stays inside
## the size budget. Each takes the demo node `h` and reports through its `_check`.


## The UIDs a pack declares, and the one it may not take.
##
## An imported asset's reference to its sibling is a UID, and registering one the HOST owns would re-point
## every `load("uid://…")` in the build into downloaded content: the mount prefix escaped by another route.
static func uids(h: Node) -> void:
	h._sections_started += 1
	h._line("[b]9. the uids a pack declares[/b]")

	var mounter := DotCloudMounter.new(h._config)

	# An id nothing in this project has ever used, which a pack is entitled to claim.
	var mine := ResourceUID.create_id()
	var mine_text := ResourceUID.id_to_text(mine)

	# And one the HOST owns: a real file in this build, registered here the way the
	# editor's own cache would have.
	var stolen := ResourceUID.create_id()
	var host_file := "res://addons/dot_cloud/mount/dot_cloud_mounter.gd"
	ResourceUID.add_id(stolen, host_file)

	var texture: PackedByteArray = h._blob("atlas", 256)
	h._store.put_bytes(texture, DotHash.sha256_bytes(texture))

	var marker := (
		"[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\n"
		+ "uid=\"%s\"\n" % mine_text
	).to_utf8_buffer()
	h._store.put_bytes(marker, DotHash.sha256_bytes(marker))

	var thief := (
		"[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\n"
		+ "uid=\"%s\"\n" % ResourceUID.id_to_text(stolen)
	).to_utf8_buffer()
	h._store.put_bytes(thief, DotHash.sha256_bytes(thief))

	var m: DotCloudManifest = h._manifest("uidpack", "1.0.0", [
		["atlas.png", texture, true],
		["atlas.png.import", marker, true],
		["stolen.png", texture, true],
		["stolen.png.import", thief, true],
	])

	var res: DotResult = await mounter.mount(m, h._store, h._scheduler)
	h._check("mounted", res.ok, str(res.error) if not res.ok else "")

	if not res.ok:
		h._line("")
		h._sections_finished += 1
		return

	h._check(
		"a uid the pack declares points into the mount",
		ResourceUID.has_id(mine)
			and ResourceUID.get_id_path(mine) == m.mount_prefix().path_join("atlas.png"),
		ResourceUID.get_id_path(mine) if ResourceUID.has_id(mine) else "unregistered"
	)

	# The whole point of the section.
	h._check(
		"and a uid the HOST owns is left exactly where it was",
		ResourceUID.get_id_path(stolen) == host_file,
		ResourceUID.get_id_path(stolen)
	)

	var described := mounter.describe()
	h._check(
		"one registered, one refused, and the mount says which",
		int(h._mount_row(described, m.key()).get("uids", -1)) == 1,
		str(h._mount_row(described, m.key()).get("uids", -1))
	)

	ResourceUID.remove_id(stolen)
	h._line("")
	h._sections_finished += 1


static func slice_loader(h: Node) -> void:
	h._sections_started += 1
	h._line("[b]12. slice loader yields between slices[/b]")

	var paths := PackedStringArray()
	for f in DirAccess.get_files_at("res://addons/dot_cloud/transfer"):
		if f.ends_with(".gd"):
			paths.append("res://addons/dot_cloud/transfer/" + f)
	h._check("have scripts to load", paths.size() >= 4, str(paths.size()))

	for threaded in [false, true]:
		var loader := DotCloudSliceLoader.new()
		loader.budget_msec = 0
		var seen := [0]
		var ticks := [0]
		loader.progress.connect(func(d: int, _t: int, _p: String) -> void: seen[0] = d)
		var counter := func() -> void: ticks[0] += 1
		h.get_tree().process_frame.connect(counter)
		var res := await loader.load_all(h.get_tree(), paths, threaded)
		h.get_tree().process_frame.disconnect(counter)
		var label := "threaded" if threaded else "sync"
		h._check("%s: loaded all" % label, res.ok and int(res.value) == paths.size())
		h._check("%s: progress reached total" % label, seen[0] == paths.size(), str(seen[0]))
		h._check("%s: holds what it loaded" % label, loader.loaded.size() == paths.size(), str(loader.loaded.size()))
		# The threaded pass finds everything cached by the first, so it may finish in no frame.
		h._check("%s: frames passed during the load" % label,
			threaded or (ticks[0] >= 1 and loader.frames_yielded >= 1),
			"%d ticks, %d yields" % [ticks[0], loader.frames_yielded])

	var bad := await DotCloudSliceLoader.new().load_all(h.get_tree(), PackedStringArray(["res://nope.gd"]), false)
	h._check("a missing path fails", not bad.ok)
	h._check("with CODE_IO", bad.error.code == DotError.CODE_IO)

	var probe := "user://slice_probe.gd"
	var f := FileAccess.open(probe, FileAccess.WRITE)
	f.store_string("extends Node\nvar a: DotCloudSliceLoader\nvar b: DotCloudWorkshopDevice\nvar c: NotAClass\n")
	f.close()
	var device := ""
	for entry in ProjectSettings.get_global_class_list():
		if entry["class"] == &"DotCloudWorkshopDevice":
			device = entry["path"]
	var named := DotCloudSliceLoader.named_class_scripts(PackedStringArray([probe]))
	h._check("named: an uncached class is listed, a cached one is not",
		named.has(device) == (not ResourceLoader.has_cached(device)) and named.size() <= 1, str(named))
	DirAccess.remove_absolute(probe)
	h._sections_finished += 1
