extends RefCounted

## Sections of mount_demo.gd that only need its checker, in a file of their own so the demo stays inside
## the size budget. Each takes the demo node `h` and reports through its `_check`.


## The UIDs a pack declares, and the one it may not take.
##
## Registering a UID the host owns would re-point every `load("uid://…")` in the build into downloaded content.
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

	# The pack steals a uid on purpose; the mounter's ERROR for it is the behaviour under test.
	DotLog.set_channel_level("cloud.mount", DotLog.Level.OFF)
	var res: DotResult = await mounter.mount(m, h._store, h._scheduler)
	DotLog.clear_channel_level("cloud.mount")
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

	# Batch cap: never more than max_per_frame resources between two frames, and the cover's frames keep ticking.
	var batched := DotCloudSliceLoader.new()
	batched.budget_msec = 100000
	batched.max_per_frame = 3
	var ticks_b := [0]
	var counter_b := func() -> void: ticks_b[0] += 1
	h.get_tree().process_frame.connect(counter_b)
	var bres := await batched.load_all(h.get_tree(), paths, false)
	h.get_tree().process_frame.disconnect(counter_b)
	h._check("batched: loaded all", bres.ok and batched.loaded.size() == paths.size())
	h._check("batched: at most 3 resources in any frame", batched.peak_per_frame <= 3 and batched.peak_per_frame >= 1,
		str(batched.peak_per_frame))
	h._check("batched: one frame passed per batch", ticks_b[0] >= paths.size() / 3 and batched.frames_yielded >= paths.size() / 3,
		"%d ticks, %d yields for %d paths" % [ticks_b[0], batched.frames_yielded, paths.size()])
	h._check("batched: no frame over 100 ms", batched.peak_frame_msec < 100, "%d ms" % batched.peak_frame_msec)

	var capped := DotCloudSliceLoader.new()
	capped.budget_msec = 0
	capped.deadline_msec = 1
	await h.get_tree().create_timer(0.01).timeout
	var cres := await capped.load_all(h.get_tree(), paths, false)
	var first := capped.loaded.size()
	h._check("a deadline loads at least one and defers the rest or finishes",
		cres.ok and first >= 1 and first + capped.remaining.size() == paths.size(), "%d + %d" % [first, capped.remaining.size()])
	await capped.load_rest(h.get_tree(), 0)
	h._check("load_rest finishes what the deadline left",
		capped.remaining.is_empty() and capped.loaded.size() == paths.size(), str(capped.loaded.size()))

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


## A mount refused for an object that rotted after it was committed, and accepted with the check off.
static func corrupt_object(h: Node) -> void:
	h._sections_started += 1
	h._line("[b]6. an object that rotted after it was committed[/b]")

	# commit_partial is the only hash check, so nothing re-reads a cached object; verify_before_mount alone
	# guards against a bad sector, and no test reached it.
	var body: PackedByteArray = h._blob("will-rot", 640)
	var hash := DotHash.sha256_bytes(body)
	h._store.put_bytes(body, hash)

	var m: DotCloudManifest = h._manifest("rotten", "1.0.0", [["data.txt", body, true]])

	var corrupted := DotPaths.write_bytes(h._store.path_for(hash), h._blob("not-it", 640))
	h._check("object corrupted underneath the cache", corrupted.ok)

	var mounter := DotCloudMounter.new(h._config)
	var res: DotResult = await mounter.mount(m, h._store, h._scheduler)
	h._check(
		"mount refused",
		not res.ok and res.error.code == DotError.CODE_INTEGRITY,
		str(res.error.code) if not res.ok else "MOUNTED"
	)
	h._check("nothing was mounted", not mounter.is_mounted(m.key()))

	# With the check off, the same mount goes through. Asserting this is what
	# stops verify_before_mount from being quietly ineffective: if it were, the
	# check above would pass for the wrong reason and this one would too.
	h._config.verify_before_mount = false
	var mounter2 := DotCloudMounter.new(h._config)
	var res2: DotResult = await mounter2.mount(m, h._store, h._scheduler)
	h._check("without the check it mounts (so the check is what caught it)", res2.ok,
		str(res2.error) if not res2.ok else "")
	h._config.verify_before_mount = true

	h._line("")
	h._sections_finished += 1


# 10. One id and version, two publishers

## Two parties claiming one `content_id@version`, in ONE process: one [DotCloudMounter] meeting two
## manifests that agree about id and version and about nothing else.
##
## `key()` derives nothing from the bytes, so the second was indistinguishable from a re-mount of the
## first and the player ran Alice's scripts on Mallory's server. A pack cannot be unmounted, so it is
## refused with something the caller can act on.
static func two_publishers(h: Node) -> void:
	h._sections_started += 1
	h._line("[b]10. one id and version, two publishers[/b]")

	var alice: PackedByteArray = h._blob("alice-build", 512)
	var mallory: PackedByteArray = h._blob("mallory-build", 512)
	h._store.put_bytes(alice, DotHash.sha256_bytes(alice))
	h._store.put_bytes(mallory, DotHash.sha256_bytes(mallory))

	# ONE mounter for the whole section. Two would be section 6.
	var mounter := DotCloudMounter.new(h._config)

	var m_alice: DotCloudManifest = h._manifest("contested", "1.0.0", [["level.txt", alice, true]])
	var first: DotResult = await mounter.mount(m_alice, h._store, h._scheduler)
	h._check("the first publisher mounts", first.ok, str(first.error) if not first.ok else "")

	# Same id, same version, same FILE NAME, different bytes.
	var m_mallory: DotCloudManifest = h._manifest("contested", "1.0.0", [["level.txt", mallory, true]])
	var second: DotResult = await mounter.mount(m_mallory, h._store, h._scheduler)

	h._check(
		"the second is refused",
		not second.ok,
		"mounted at %s" % str(second.value) if second.ok else ""
	)
	h._check(
		"as a conflict, not as a state or integrity failure",
		not second.ok and second.error.code == DotError.CODE_CONFLICT,
		second.error.code if not second.ok else ""
	)

	# The refusal is only worth having if the first publisher's content survived it.
	var read := DotPaths.read_bytes("res://dot_cloud/contested/1.0.0/level.txt")
	h._check("the first publisher's bytes are still what is mounted",
		read.ok and (read.value as PackedByteArray) == alice)
	h._check("and there is still one mount", mounter.mounted_keys().size() == 1)

	# [b]Identity is the content, not the object.[/b] A manifest re-read off the wire describing the
	# same files must still be the cheap no-op of section 3, or every legitimate reconnect is refused.
	var m_again: DotCloudManifest = h._manifest("contested", "1.0.0", [["level.txt", alice, true]])
	var again: DotResult = await mounter.mount(m_again, h._store, h._scheduler)
	h._check(
		"an equal manifest from a different object is still a no-op",
		again.ok and str(again.value) == m_alice.mount_prefix(),
		str(again.error) if not again.ok else str(again.value)
	)

	h._line("")
	h._sections_finished += 1


# 11. <owner>/<name> content ids

## An id that names who owns it, and the forms that must still be refused.
##
## "/" is a second directory level in the mount prefix, which keeps `alice_bob` + `x` apart from
## `alice` + `bob_x` and makes a key scoped `alice/*` exact. Two segments at most, none empty, no
## traversal, each still a slug.
static func namespaced_ids(h: Node) -> void:
	h._sections_started += 1
	h._line("[b]11. <owner>/<name> content ids[/b]")

	var body: PackedByteArray = h._blob("namespaced", 256)
	h._store.put_bytes(body, DotHash.sha256_bytes(body))

	var m: DotCloudManifest = h._manifest("alice/dot-controller", "1.0.0", [["a.txt", body, true]])

	h._check("a two-segment id validates", m.validate().ok,
		str(m.validate().error) if not m.validate().ok else "")
	h._check(
		"and its mount prefix nests",
		m.mount_prefix() == "res://dot_cloud/alice/dot-controller/1.0.0",
		m.mount_prefix()
	)

	var mounted: DotResult = await DotCloudMounter.new(h._config).mount(m, h._store, h._scheduler)
	h._check("it mounts", mounted.ok, str(mounted.error) if not mounted.ok else "")
	h._check(
		"and its file is readable at the nested path",
		FileAccess.file_exists("res://dot_cloud/alice/dot-controller/1.0.0/a.txt")
	)

	# A bare id is what every first-party pack already is, and must not have become
	# invalid by adding the two-segment form beside it.
	h._check("a one-segment id still validates",
		h._manifest("arena", "1.0.0", [["a.txt", body, true]]).validate().ok)

	# [b]The separator is the point, so the flattened spelling must stay distinct.[/b]
	# If these two ever compared equal, the ambiguity this whole form exists to remove
	# would be back.
	h._check(
		"owner/name and owner_name are different ids",
		h._manifest("alice/x", "1.0.0", []).key()
			!= h._manifest("alice_x", "1.0.0", []).key()
	)

	for bad in ["a/b/c", "alice/", "/alice", "alice//x", "../etc", "alice/../x", "Alice/x"]:
		var r = h._manifest(bad, "1.0.0", [["a.txt", body, true]]).validate()
		h._check("'%s' is refused" % bad, not r.ok,
			"ACCEPTED" if r.ok else r.error.code)

	# The scope glob has to select on the real separator, or the control that stops
	# one member publishing as another is decorative.
	var scoped := {"key": "-----BEGIN PUBLIC KEY-----", "content_ids": ["alice/*"]}
	h._check("alice/* covers alice's own id",
		DotCloudSignature.scope_allows(scoped, "alice/dot-controller"))
	h._check("and does not cover another member's",
		not DotCloudSignature.scope_allows(scoped, "alicebob/x"))
	h._check("nor the flattened lookalike",
		not DotCloudSignature.scope_allows(scoped, "alice_bob/x"))
	h._check("alice/* does not cover a deeper path",
		not DotCloudSignature.scope_allows(scoped, "alice/a/b"))
	var loose := {"key": "k", "content_ids": ["alice*"]}
	h._check("alice* does not cross a / into alice/x",
		not DotCloudSignature.scope_allows(loose, "alice/x"))
	h._check("alice* still covers a one-segment alice-bob",
		DotCloudSignature.scope_allows(loose, "alice-bob"))
	h._check("an exact id still matches",
		DotCloudSignature.scope_allows({"key": "k", "content_ids": ["alice/x"]}, "alice/x"))

	h._line("")
	h._sections_finished += 1
