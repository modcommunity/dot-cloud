extends Control

## Exercises [DotCloudMounter] directly — the last class in this addon that no
## example named.
##
## The three pipeline demos all mount, but only along the one path a successful
## download takes: one content set, one version, everything present, nothing
## re-entered. Everything the mounter exists *for* was reached by nothing.
## In particular [b]version namespacing has never been executed[/b], and it is
## the single design decision the whole addon is built around: a mounted pack
## can never be unmounted, so two versions of the same content must be able to
## coexist without either one shadowing the other. That claim was load-bearing
## and untested.
##
## No network, no signing, no downloader: objects go into the store directly and
## the mounter is driven on its own, so a failure here points at one class.
##
## [codeblock]
## godot --headless --path . res://examples/mount_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_mount_demo"

@onready var _output: RichTextLabel = $Output

var _failures: int = 0
var _checks: int = 0
var _scheduler: DotScheduler
var _config: DotCloudConfig
var _store: DotCloudStore

## Sections are coroutines, and a coroutine that returns early takes its
## remaining assertions with it silently. Counting entries against exits is the
## only way a truncated run is distinguishable from a passing one.
var _sections_started: int = 0
var _sections_finished: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	_line("[b]dot-cloud mounter[/b]")
	_line("")

	DotPaths.remove_tree(WORK)

	_scheduler = DotScheduler.new()
	_scheduler.name = "MountScheduler"
	add_child(_scheduler)

	_config = DotCloudConfig.new()
	_config.cache_dir = WORK.path_join("cache")
	_config.verify_before_mount = true
	_config.enforce_mount_prefix = true

	_store = DotCloudStore.new(_config)
	var opened := await _store.open()
	if not opened.ok:
		return _fail("opening the store", opened)

	await _section_traversal()
	await _section_incomplete()
	await _section_mount_and_read()
	await _section_two_versions()
	await _section_unmount_and_remount()
	await _section_corrupt_object()
	await _section_queries()

	_line("")
	_check(
		"every suspending section ran",
		_sections_finished == _sections_started,
		"%d/%d" % [_sections_finished, _sections_started]
	)

	_line("")
	_line("[b]%d checks, %d failed[/b]" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


# --- 1. The version is a path component ------------------------------------

func _section_traversal() -> void:
	_sections_started += 1
	_line("[b]1. the version lands in the mount path[/b]")

	# content_id has always been slug-checked. version had only a "slugifies to
	# something non-empty" check, and slugify("../..") is "" but
	# slugify("../evil") is "evil" — non-empty, so it passed, while
	# mount_prefix() interpolates the *raw* string. A manifest could therefore
	# name a version that walked straight out of mount_root, which is the one
	# thing mount_root exists to make impossible: mount at res:// and the next
	# manifest ships scripts/anything.gd.
	for bad in ["../evil", "1.0.0/../../x", "a/b", "..\\..\\x"]:
		var m := _manifest("arena", bad, [])
		var res := m.validate()
		_check(
			"version '%s' refused" % bad,
			not res.ok and res.error.code == DotError.CODE_INVALID,
			"prefix would have been %s" % m.mount_prefix() if res.ok else ""
		)

	# ...and the real ones still pass, which is why this is not a slug check.
	for good in ["1.0.0", "0.0.1", "2.1.0-rc.4+build17", "v3"]:
		var m := _manifest("arena", good, [])
		var res := m.validate()
		_check("version '%s' allowed" % good, res.ok,
			str(res.error) if not res.ok else "")

	_line("")
	_sections_finished += 1


# --- 2. Nothing mounts half-downloaded --------------------------------------

func _section_incomplete() -> void:
	_sections_started += 1
	_line("[b]2. a half-downloaded mount is refused whole[/b]")

	var mounter := DotCloudMounter.new(_config)

	var present := _blob("present", 512)
	var absent := _blob("absent", 512)
	var put := _store.put_bytes(present, DotHash.sha256_bytes(present))
	_check("object stored", put.ok, str(put.error) if not put.ok else "")

	var m := _manifest("incomplete", "1.0.0", [
		["ok.txt", present, true],
		["missing.txt", absent, true],
	])

	var res: DotResult = await mounter.mount(m, _store, _scheduler)
	_check(
		"required file missing -> refused",
		not res.ok and res.error.code == DotError.CODE_STATE,
		str(res.error.code) if not res.ok else "MOUNTED"
	)
	_check("nothing recorded as mounted", mounter.mounted_keys().is_empty())

	# The same content set with that file marked optional mounts, minus the file.
	# "Optional" has to mean the pack is built without it, not that the pack is
	# built with a hole that fails at load time.
	var m2 := _manifest("incomplete", "1.0.1", [
		["ok.txt", present, true],
		["missing.txt", absent, false],
	])
	var res2: DotResult = await mounter.mount(m2, _store, _scheduler)
	_check("optional file missing -> mounts", res2.ok,
		str(res2.error) if not res2.ok else "")
	if res2.ok:
		_check(
			"the optional file is absent from the pack",
			not FileAccess.file_exists(m2.mount_prefix().path_join("missing.txt"))
		)
		_check(
			"the required file is present",
			FileAccess.file_exists(m2.mount_prefix().path_join("ok.txt"))
		)

	_line("")
	_sections_finished += 1


# --- 3. Mount, and read the bytes back --------------------------------------

func _section_mount_and_read() -> void:
	_sections_started += 1
	_line("[b]3. mount, read back, and the namespace[/b]")

	var mounter := DotCloudMounter.new(_config)
	var body := _blob("arena-v1", 2048)
	_store.put_bytes(body, DotHash.sha256_bytes(body))

	# A real .tscn, not a .txt standing in for one. entry_scene_of() gates on
	# ResourceLoader.exists(), which answers "is there a loader registered for
	# this extension", so a .txt entry scene fails it while being perfectly
	# readable — and whether the engine resolves a *scene* out of a runtime-built
	# PCK is the thing actually worth knowing, and was asserted nowhere.
	var scene_src := (
		"[gd_scene format=3]\n\n"
		+ "[node name=\"Level\" type=\"Node\"]\n"
	).to_utf8_buffer()
	_store.put_bytes(scene_src, DotHash.sha256_bytes(scene_src))

	var m := _manifest("arena", "1.0.0", [
		["level.txt", body, true],
		["level.tscn", scene_src, true],
	])
	m.entry_scene = "level.tscn"

	var res: DotResult = await mounter.mount(m, _store, _scheduler)
	_check("mounted", res.ok, str(res.error) if not res.ok else "")
	if not res.ok:
		_line("")
		_sections_finished += 1
		return

	_check("returns the prefix", str(res.value) == m.mount_prefix(), str(res.value))
	_check(
		"prefix carries id and version",
		str(res.value) == "res://dot_cloud/arena/1.0.0", str(res.value)
	)

	var read := DotPaths.read_bytes(m.mount_prefix().path_join("level.txt"))
	_check("readable through res://", read.ok)
	if read.ok:
		_check("bytes are the cached object", (read.value as PackedByteArray) == body)

	# Mounting the same key twice must be a cheap no-op, not a second
	# load_resource_pack of a pack that is already merged in.
	var again: DotResult = await mounter.mount(m, _store, _scheduler)
	_check("second mount is a no-op", again.ok and str(again.value) == m.mount_prefix())
	_check("still one mount", mounter.mounted_keys().size() == 1)

	var entry := mounter.entry_scene_of(m.key())
	_check("entry scene resolves", entry.ok and str(entry.value).ends_with("level.tscn"),
		str(entry.value) if entry.ok else str(entry.error))

	# The point of entry_scene_of is that the path it hands back is loadable.
	# Returning a path and leaving the caller to discover the engine cannot open
	# it would make the IO branch below decorative.
	if entry.ok:
		var packed: Resource = ResourceLoader.load(str(entry.value))
		_check("and the scene actually loads from the pack", packed is PackedScene,
			str(packed))
		if packed is PackedScene:
			var inst := (packed as PackedScene).instantiate()
			_check("and instantiates", inst != null and inst.name == "Level",
				str(inst.name) if inst != null else "null")
			if inst != null:
				inst.free()

	# An entry_scene the engine has no loader for is an IO failure, not a
	# success handing back a dead path.
	var m_txt := _manifest("arena", "1.0.1", [["level.txt", body, true]])
	m_txt.entry_scene = "level.txt"
	var txt_mounted: DotResult = await mounter.mount(m_txt, _store, _scheduler)
	if txt_mounted.ok:
		var bad_entry := mounter.entry_scene_of(m_txt.key())
		_check("an unloadable entry scene is refused as IO",
			not bad_entry.ok and bad_entry.error.code == DotError.CODE_IO,
			str(bad_entry.error.code) if not bad_entry.ok else "ACCEPTED")

	# The store must be holding the content back from eviction while mounted.
	_check(
		"mount took a store ref",
		_store.ref_count(DotHash.sha256_bytes(body)) > 0,
		"%d" % _store.ref_count(DotHash.sha256_bytes(body))
	)

	_line("")
	_sections_finished += 1


# --- 4. The reason the whole addon is shaped this way -----------------------

func _section_two_versions() -> void:
	_sections_started += 1
	_line("[b]4. two versions of one content set, mounted at once[/b]")

	var mounter := DotCloudMounter.new(_config)

	# Same *paths*, different bytes, different versions. On the naive design
	# (mount both at res://game/) v1's bytes would answer for a file v2 also
	# defines, or v2's would shadow v1's — silently, which is the failure mode
	# the class doc spends forty lines on. Here they must simply not collide.
	var v1_shared := _blob("shared-v1", 300)
	var v1_only := _blob("only-in-v1", 300)
	var v2_shared := _blob("shared-v2", 300)

	for b in [v1_shared, v1_only, v2_shared]:
		_store.put_bytes(b, DotHash.sha256_bytes(b))

	var m1 := _manifest("dm_arena", "1.0.0", [
		["shared.txt", v1_shared, true],
		["gone_in_v2.txt", v1_only, true],
	])
	var m2 := _manifest("dm_arena", "2.0.0", [
		["shared.txt", v2_shared, true],
	])

	var r1: DotResult = await mounter.mount(m1, _store, _scheduler)
	_check("v1 mounted", r1.ok, str(r1.error) if not r1.ok else "")
	var r2: DotResult = await mounter.mount(m2, _store, _scheduler)
	_check("v2 mounted alongside", r2.ok, str(r2.error) if not r2.ok else "")
	if not (r1.ok and r2.ok):
		_line("")
		_sections_finished += 1
		return

	_check("both are mounted", mounter.mounted_keys().size() == 2,
		str(mounter.mounted_keys()))
	_check("prefixes differ", m1.mount_prefix() != m2.mount_prefix())

	var s1 := DotPaths.read_bytes(m1.mount_prefix().path_join("shared.txt"))
	var s2 := DotPaths.read_bytes(m2.mount_prefix().path_join("shared.txt"))
	_check("v1 shared.txt is v1's bytes", s1.ok and (s1.value as PackedByteArray) == v1_shared)
	_check("v2 shared.txt is v2's bytes", s2.ok and (s2.value as PackedByteArray) == v2_shared)

	# The other half of the same failure: a file v2 dropped must not still
	# resolve *under v2*. It stays readable under v1 — that is the point, the
	# namespaces are independent, not layered.
	_check(
		"a file dropped in v2 does not resolve under v2",
		not FileAccess.file_exists(m2.mount_prefix().path_join("gone_in_v2.txt"))
	)
	_check(
		"and still resolves under v1",
		FileAccess.file_exists(m1.mount_prefix().path_join("gone_in_v2.txt"))
	)

	_line("")
	_sections_finished += 1


# --- 5. Unmount, and what it can and cannot do ------------------------------

func _section_unmount_and_remount() -> void:
	_sections_started += 1
	_line("[b]5. unmount, and re-entering the same version[/b]")

	var mounter := DotCloudMounter.new(_config)
	var body := _blob("rotation", 800)
	var hash := DotHash.sha256_bytes(body)
	_store.put_bytes(body, hash)

	var m := _manifest("rotate", "1.0.0", [["map.txt", body, true]])
	var mounted: DotResult = await mounter.mount(m, _store, _scheduler)
	_check("mounted", mounted.ok, str(mounted.error) if not mounted.ok else "")

	_check("ref held while mounted", _store.ref_count(hash) > 0)

	var un := mounter.unmount(m.key(), _store)
	_check("unmounted", un.ok, str(un.error) if not un.ok else "")
	_check("ref released", _store.ref_count(hash) == 0, "%d" % _store.ref_count(hash))
	_check("no longer mounted", not mounter.is_mounted(m.key()))
	_check("prefix_of is empty now", mounter.mount_prefix_of(m.key()) == "")

	# unmount() returns what is *still referenced*, not what it freed — nothing
	# in Godot can free a cached resource out from under a live reference, and
	# for a long time this returned the count of resources it had needlessly
	# re-read from disk while claiming to have purged them. With nothing holding
	# this content, the honest answer is zero.
	_check("nothing left referenced", int(un.value) == 0, "%d" % int(un.value))

	# The pack is still in the virtual filesystem — there is no unmount, on any
	# platform. Asserting it means a future "optimisation" that starts reusing
	# paths has to change this line and notice why it exists.
	_check(
		"the file table survives unmount (this is the constraint)",
		FileAccess.file_exists(m.mount_prefix().path_join("map.txt"))
	)

	var un_twice := mounter.unmount(m.key(), _store)
	_check("unmounting twice is an error, not a crash",
		not un_twice.ok and un_twice.error.code == DotError.CODE_INVALID)

	# Map rotation: back to the same version later in the session. The pack file
	# was cached by _pack_path, so this is a re-mount of a pack already built.
	var re: DotResult = await mounter.mount(m, _store, _scheduler)
	_check("re-mounted the same version", re.ok, str(re.error) if not re.ok else "")
	_check("ref taken again", _store.ref_count(hash) > 0)
	var reread := DotPaths.read_bytes(m.mount_prefix().path_join("map.txt"))
	_check("still the right bytes", reread.ok and (reread.value as PackedByteArray) == body)

	_line("")
	_sections_finished += 1


# --- 6. verify_before_mount actually verifies -------------------------------

func _section_corrupt_object() -> void:
	_sections_started += 1
	_line("[b]6. an object that rotted after it was committed[/b]")

	# commit_partial is the only place a hash is checked, so nothing re-reads an
	# object once it is in the cache. verify_before_mount is the only thing
	# standing between a bad sector and a mounted pack of wrong bytes, and it
	# was reached by no test.
	var body := _blob("will-rot", 640)
	var hash := DotHash.sha256_bytes(body)
	_store.put_bytes(body, hash)

	var m := _manifest("rotten", "1.0.0", [["data.txt", body, true]])

	var corrupted := DotPaths.write_bytes(_store.path_for(hash), _blob("not-it", 640))
	_check("object corrupted underneath the cache", corrupted.ok)

	var mounter := DotCloudMounter.new(_config)
	var res: DotResult = await mounter.mount(m, _store, _scheduler)
	_check(
		"mount refused",
		not res.ok and res.error.code == DotError.CODE_INTEGRITY,
		str(res.error.code) if not res.ok else "MOUNTED"
	)
	_check("nothing was mounted", not mounter.is_mounted(m.key()))

	# With the check off, the same mount goes through. Asserting this is what
	# stops verify_before_mount from being quietly ineffective: if it were, the
	# check above would pass for the wrong reason and this one would too.
	_config.verify_before_mount = false
	var mounter2 := DotCloudMounter.new(_config)
	var res2: DotResult = await mounter2.mount(m, _store, _scheduler)
	_check("without the check it mounts (so the check is what caught it)", res2.ok,
		str(res2.error) if not res2.ok else "")
	_config.verify_before_mount = true

	_line("")
	_sections_finished += 1


# --- 7. Queries and describe ------------------------------------------------

func _section_queries() -> void:
	_sections_started += 1
	_line("[b]7. queries[/b]")

	var mounter := DotCloudMounter.new(_config)

	_check("nothing mounted yet", mounter.mounted_keys().is_empty())
	_check("describe_lines says so",
		str(mounter.describe_lines()[0]).contains("nothing mounted"))
	_check("entry_scene_of on nothing mounted is an error",
		not mounter.entry_scene_of("absent@1.0.0").ok)
	_check("needs_restart_to_reclaim is false when empty",
		not mounter.needs_restart_to_reclaim())

	var body := _blob("queries", 128)
	_store.put_bytes(body, DotHash.sha256_bytes(body))

	# Deliberately mounted out of alphabetical order: mounted_keys() sorts, and
	# describe() is a bug-report surface that should be stable between runs.
	for id in ["zulu", "alpha", "mike"]:
		var m := _manifest(id, "1.0.0", [["f.txt", body, true]])
		var r: DotResult = await mounter.mount(m, _store, _scheduler)
		if not r.ok:
			_check("mounting %s" % id, false, str(r.error))

	var keys := mounter.mounted_keys()
	_check("mounted_keys is sorted",
		Array(keys) == ["alpha@1.0.0", "mike@1.0.0", "zulu@1.0.0"], str(keys))

	# The restart decision, now that something is actually mounted. Empty was the
	# only case covered before, and it is the case that returns false for the
	# uninteresting reason.
	#
	# restart_process() itself is deliberately never called: on a desktop build
	# can_self_restart() is true, so calling it would re-exec this demo instead of
	# testing it. The decision is what a caller reads; the exec is one OS call
	# behind it. See the note on the method.
	_check("needs_restart_to_reclaim follows the platform while mounted",
		mounter.needs_restart_to_reclaim() == (not DotPlatform.can_unmount_packs()),
		"mounted=%d can_unmount=%s needs_restart=%s" % [
			keys.size(),
			DotPlatform.can_unmount_packs(),
			mounter.needs_restart_to_reclaim(),
		])
	if DotPlatform.can_unmount_packs():
		_check("nothing to reclaim where packs really unmount",
			not mounter.needs_restart_to_reclaim())

	var described := mounter.describe()
	_check("describe reports the unmount capability",
		described.get("can_unmount") == DotPlatform.can_unmount_packs())
	_check("describe reports the restart capability",
		described.get("can_restart") == DotPlatform.can_self_restart())

	var d := mounter.describe()
	_check("describe lists all three", (d["mounted"] as Array).size() == 3)
	_check("describe reports platform capabilities",
		d.has("can_unmount") and d.has("can_restart"))
	_check("can_unmount is false, everywhere",
		not bool(d["can_unmount"]))
	_check("describe_lines has a line per mount", mounter.describe_lines().size() == 3)

	# A content set with no entry_scene is a legitimate manifest (pure assets),
	# and must be told apart from one whose entry scene failed to mount.
	var no_entry := mounter.entry_scene_of("alpha@1.0.0")
	_check("no entry scene is INVALID, not IO",
		not no_entry.ok and no_entry.error.code == DotError.CODE_INVALID,
		str(no_entry.error.code) if not no_entry.ok else "")

	_line("")
	_sections_finished += 1


# --- Helpers ----------------------------------------------------------------

## A manifest built in memory. [param entries] are [path, bytes, required].
func _manifest(id: String, version: String, entries: Array) -> DotCloudManifest:
	var m := DotCloudManifest.new()
	m.content_id = id
	m.version = version
	m.display_name = id
	m.mount_root = "dot_cloud"

	for e in entries:
		var f := DotCloudFile.new()
		f.path = str(e[0])
		var bytes: PackedByteArray = e[1]
		f.sha256 = DotHash.sha256_bytes(bytes)
		f.size = bytes.size()
		f.required = bool(e[2])
		m.files.append(f)

	return m


## Deterministic bytes, distinct per seed, so a hash mismatch is a real mismatch
## and not two blobs that happened to be identical.
func _blob(seed_text: String, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(size)
	var h := seed_text.hash()
	for i in range(size):
		h = (h * 1103515245 + 12345) & 0x7FFFFFFF
		out[i] = h & 0xFF
	return out


func _fail(what: String, res: DotResult) -> void:
	_line("")
	_line("[b]FAILED at %s[/b]" % what)
	_line("  %s" % str(res.error))
	_finish(1)


func _finish(code: int = 0) -> void:
	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(code)


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1

	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail

	_line("  %s %s%s" % [label.rpad(48), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
