extends Control

## Exercises [DotCloudStore] directly: eviction under pressure, references, the
## index, and partial housekeeping.
##
## The three pipeline demos all drive the store, but only along the one path a
## successful download takes — commit, look up, mount. Everything the store does
## when the cache is [i]full[/i] was reached by nothing: eviction order,
## references holding content back, a cache that cannot shrink, and the index
## disagreeing with the directory it describes. That last one is not a corner
## case. Objects are flushed to storage as they commit and the index is only
## written at the end of a sync, so [b]every run that ends without close() leaves
## one behind[/b], and the design says that is fine — "the index is disposable,
## it can always be rebuilt from the directory". It could be. Nothing did.
##
## No network, no manifest, no signing: this is the cache on its own, so a
## failure here points at one class.
##
## [codeblock]
## godot --headless --path . res://examples/store_demo.tscn
## [/codeblock]

const WORK := "user://dot_cloud_store_demo"

## Every object in this demo is this big, so byte arithmetic in the assertions
## below is readable and a limit can be expressed as a number of objects.
const OBJ := 1024

@onready var _output: RichTextLabel = $Output

var _failures: int = 0
var _checks: int = 0
var _scheduler: DotScheduler


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	_line("[b]dot-cloud store[/b]")
	_line("")

	DotPaths.remove_tree(WORK)

	_scheduler = DotScheduler.new()
	_scheduler.name = "StoreScheduler"
	add_child(_scheduler)

	await _section_commit()
	await _section_pressure()
	await _section_lru()
	await _section_index()
	await _section_partials()
	await _section_verify_and_clear()

	_line("")
	_line("[b]%d checks, %d failed[/b]" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


# --- 1. The verification chokepoint ----------------------------------------

func _section_commit() -> void:
	_line("[b]1. commit, and the one place a hash is checked[/b]")

	var store: DotCloudStore = await _open_store(WORK.path_join("basic"), 0)
	if store == null:
		return

	var good := _blob(1, OBJ)
	var good_hash := DotHash.sha256_bytes(good)
	var committed: DotResult = await _commit(store, good)

	_check("commit", committed.ok, str(committed.error) if not committed.ok else "")
	_check("object present", store.has(good_hash))
	_check("counted", store.object_count() == 1 and store.total_bytes() == OBJ,
		"%d objects, %d B" % [store.object_count(), store.total_bytes()])
	_check("partial gone", store.partial_size(good_hash) == 0)

	# A partial whose bytes are not what its name says. The store must refuse it
	# *and* delete it: keeping it means every resume appends to bad bytes and
	# fails identically forever, which is the failure this addon has already had
	# once over HTTP.
	var claimed := DotHash.sha256_bytes(_blob(2, OBJ))
	var wrote := DotPaths.write_bytes(store.partial_path(claimed), _blob(3, OBJ))
	_check("planted partial", wrote.ok)
	var bad: DotResult = await store.commit_partial(claimed)
	_check("corrupt refused", not bad.ok and bad.error.code == DotError.CODE_INTEGRITY,
		bad.error.code if not bad.ok else "accepted it")
	_check("corrupt discarded", store.partial_size(claimed) == 0 and not store.has(claimed))

	var nothing: DotResult = await store.commit_partial(DotHash.sha256_text("absent"))
	_check("no partial", not nothing.ok and nothing.error.code == DotError.CODE_IO)

	var lied := store.put_bytes(_blob(4, OBJ), claimed)
	_check("put_bytes checks", not lied.ok and lied.error.code == DotError.CODE_INTEGRITY)

	# A half-finished HTTP download, then the same object arriving whole from
	# somewhere else — the in-band fallback, or another manifest that shares it.
	# The partial is unreachable from that moment: nothing resumes content the
	# store already has.
	var direct := _blob(5, OBJ)
	var direct_hash := DotHash.sha256_bytes(direct)
	DotPaths.write_bytes(store.partial_path(direct_hash), _blob(5, 512))
	var put := store.put_bytes(direct, direct_hash)
	_check("put_bytes commits", put.ok and store.has(direct_hash))
	_check("stale partial dropped", store.partial_size(direct_hash) == 0,
		"%d B left behind" % store.partial_size(direct_hash))

	store.close()
	_line("")


# --- 2. Eviction under pressure --------------------------------------------

func _section_pressure() -> void:
	_line("[b]2. a full cache, with content mounted[/b]")

	# Four objects' worth of ceiling, so "full" is reachable in four commits.
	var store: DotCloudStore = await _open_store(WORK.path_join("evict"), 4 * OBJ)
	if store == null:
		return

	var hashes: Array[String] = []
	for i in range(4):
		var res: DotResult = await _commit(store, _blob(10 + i, OBJ))
		if not res.ok:
			return _fail("filling the cache", res)
		hashes.append(DotHash.sha256_bytes(_blob(10 + i, OBJ)))

	_check("at the ceiling", store.total_bytes() == 4 * OBJ and not store.is_over_limit())
	_check("shortfall known", store.shortfall(2 * OBJ) == 2 * OBJ,
		"%d B" % store.shortfall(2 * OBJ))

	# Two of them are mounted content. Evicting those under a running game is
	# the failure this whole mechanism exists to prevent.
	store.add_refs("dm_arena/1.0.0", PackedStringArray([hashes[0], hashes[1]]))
	_check("refs recorded", store.ref_count(hashes[0]) == 1 and store.ref_count(hashes[3]) == 0)

	var pruned := store.prune(2 * OBJ)
	_check("pruned", pruned.ok and int(pruned.value) >= 2 * OBJ,
		str(pruned.error) if not pruned.ok else "%d B" % int(pruned.value))
	_check("mounted content kept", store.has(hashes[0]) and store.has(hashes[1]))
	_check("unreferenced gone", not store.has(hashes[2]) and not store.has(hashes[3]))
	_check("accounting after prune", store.total_bytes() == 2 * OBJ,
		"%d B" % store.total_bytes())

	# Now fill it back up with a second mounted content set, so nothing in the
	# cache is a candidate. The store must refuse and say so, not delete
	# something a connected player is reading.
	var more: Array[String] = []
	for i in range(2):
		var res: DotResult = await _commit(store, _blob(20 + i, OBJ))
		if not res.ok:
			return _fail("filling the cache again", res)
		more.append(DotHash.sha256_bytes(_blob(20 + i, OBJ)))
	store.add_refs("dm_pit/2.0.0", PackedStringArray(more))

	var stuck := store.prune(OBJ)
	_check("full cache refuses", not stuck.ok and stuck.error.code == DotError.CODE_QUOTA,
		stuck.error.code if not stuck.ok else "evicted something")
	_check("nothing deleted", store.object_count() == 4 and store.total_bytes() == 4 * OBJ,
		"%d objects" % store.object_count())
	_check("says what is in use", str(stuck.error).contains("referenced"),
		str(stuck.error))

	# Unmounting makes them candidates again without deleting anything, so a
	# player who reconnects before the cache fills still has the content.
	store.release_refs("dm_pit/2.0.0")
	_check("released", store.ref_count(more[0]) == 0 and store.has(more[0]))

	var again := store.prune(OBJ)
	_check("room after release", again.ok and int(again.value) >= OBJ,
		str(again.error) if not again.ok else "%d B" % int(again.value))
	_check("still holds dm_arena", store.has(hashes[0]) and store.has(hashes[1]))

	store.close()
	_line("")


# --- 3. Eviction order -----------------------------------------------------

func _section_lru() -> void:
	_line("[b]3. least recently used, and what counts as used[/b]")

	var store: DotCloudStore = await _open_store(WORK.path_join("lru"), 4 * OBJ)
	if store == null:
		return

	var old_a := await _commit_for(store, 30)
	var old_b := await _commit_for(store, 31)

	# Last use is a Unix timestamp in whole seconds, so two objects committed in
	# the same second tie and the order between them is arbitrary — correctly,
	# they are equally old. Anything asserting on order has to cross a second
	# boundary or it is asserting on nothing.
	await get_tree().create_timer(1.2).timeout

	var new_a := await _commit_for(store, 32)
	var new_b := await _commit_for(store, 33)

	var pruned := store.prune(2 * OBJ)
	_check("evicted the oldest", pruned.ok
		and not store.has(old_a) and not store.has(old_b)
		and store.has(new_a) and store.has(new_b),
		str(pruned.error) if not pruned.ok else "")

	await get_tree().create_timer(1.2).timeout

	# Reading an object is a use. Without this the cache evicts the content a
	# player is actively loading, because it was downloaded first.
	_check("read is a use", store.has(new_a))

	var filler_a := await _commit_for(store, 34)
	var filler_b := await _commit_for(store, 35)
	_check("full again", store.total_bytes() == 4 * OBJ, "%d B" % store.total_bytes())

	var second := store.prune(OBJ)
	_check("touched survives", second.ok and store.has(new_a) and not store.has(new_b),
		str(second.error) if not second.ok else "")
	_check("newest untouched", store.has(filler_a) and store.has(filler_b))

	store.close()
	_line("")


# --- 4. The index, and the directory it describes --------------------------

func _section_index() -> void:
	_line("[b]4. the index is behind the directory, always[/b]")

	var dir := WORK.path_join("index")
	var cfg := _config(dir, 0)

	var store: DotCloudStore = await _open_store(dir, 0)
	if store == null:
		return
	var kept := await _commit_for(store, 40)
	store.add_refs("dm_arena/1.0.0", PackedStringArray([kept]))
	store.close()

	var reopened: DotCloudStore = await _open_store(dir, 0)
	_check("survives a clean close",
		reopened.object_count() == 1 and reopened.total_bytes() == OBJ
		and reopened.ref_count(kept) == 1,
		"%d objects, %d refs" % [reopened.object_count(), reopened.ref_count(kept)])

	# The unclean shutdown, which is the normal one on web and mobile: two more
	# objects commit and flush to storage, and the process ends before the index
	# is written. The index left on disk is valid and parses, so nothing
	# downstream has any reason to suspect it.
	var lost_a := await _commit_for(reopened, 41)
	var lost_b := await _commit_for(reopened, 42)
	reopened = null

	var after_crash: DotCloudStore = await _open_store(dir, OBJ)
	var disk := _objects_on_disk(cfg)
	_check("adopts what it finds",
		after_crash.object_count() == disk.size(), "index %d, disk %d"
			% [after_crash.object_count(), disk.size()])
	_check("bytes are true",
		after_crash.total_bytes() == _sum(disk),
		"index %d B, disk %d B" % [after_crash.total_bytes(), _sum(disk)])
	_check("refs kept across it", after_crash.ref_count(kept) == 1)

	# The reason it matters: an object the index does not know about is one
	# prune() can never free, so the ceiling stops being a ceiling — and on a
	# phone that ceiling is what keeps the app from being killed for disk use.
	# The limit here is one object, so the two adopted ones have to go.
	_check("over the ceiling", after_crash.is_over_limit(),
		"%d B of %d B" % [after_crash.total_bytes(), after_crash.limit_bytes()])
	var pruned := after_crash.prune(0)
	_check("adopted objects are evictable",
		pruned.ok and not after_crash.is_over_limit()
		and not after_crash.has(lost_a) and not after_crash.has(lost_b),
		str(pruned.error) if not pruned.ok else "%d B freed" % int(pruned.value))
	_check("mounted content still safe", after_crash.has(kept))
	after_crash.close()

	# Two more, cleanly, so the checks below are counting something.
	var refilled: DotCloudStore = await _open_store(dir, 0)
	var extra_a := await _commit_for(refilled, 43)
	var extra_b := await _commit_for(refilled, 44)
	refilled.close()

	# An object deleted underneath us — a trimmed mobile sandbox, a browser
	# reclaiming storage. The entry has to go, or the file is reported present
	# forever and never re-downloaded.
	DirAccess.remove_absolute(_path_of(cfg, extra_a))
	var after_trim: DotCloudStore = await _open_store(dir, 0)
	_check("drops what vanished",
		not after_trim.has(extra_a)
		and after_trim.object_count() == _objects_on_disk(cfg).size()
		and after_trim.total_bytes() == _sum(_objects_on_disk(cfg)),
		"%d objects, %d B" % [after_trim.object_count(), after_trim.total_bytes()])
	_check("leaves the rest", after_trim.has(kept) and after_trim.has(extra_b))
	after_trim.close()

	# No index at all, and an index from a future version: both rebuild from the
	# directory, because the filenames are the hashes.
	DirAccess.remove_absolute(cfg.index_path())
	var rebuilt: DotCloudStore = await _open_store(dir, 0)
	_check("rebuilds without an index",
		rebuilt.object_count() == _objects_on_disk(cfg).size()
		and rebuilt.total_bytes() == _sum(_objects_on_disk(cfg)),
		"%d objects" % rebuilt.object_count())
	_check("refs are lost, as documented", rebuilt.ref_count(kept) == 0)
	rebuilt.close()

	DotPaths.write_json(cfg.index_path(), {"version": 99, "objects": {}}, false)
	var future: DotCloudStore = await _open_store(dir, 0)
	_check("rebuilds on a version bump",
		future.object_count() == _objects_on_disk(cfg).size(),
		"%d objects" % future.object_count())
	future.close()

	DotPaths.write_text(cfg.index_path(), "{ not json at all")
	var broken: DotCloudStore = await _open_store(dir, 0)
	_check("rebuilds on garbage",
		broken.object_count() == _objects_on_disk(cfg).size(),
		"%d objects" % broken.object_count())
	broken.close()

	_line("")


# --- 5. Partials -----------------------------------------------------------

func _section_partials() -> void:
	_line("[b]5. partials that will never be resumed[/b]")

	var dir := WORK.path_join("partials")
	var store: DotCloudStore = await _open_store(dir, 0)
	if store == null:
		return

	var have := await _commit_for(store, 50)

	# A partial for content the store already has. Resume only ever looks at
	# objects that are *missing*, so this is dead weight the size of the file —
	# and the file it duplicates is in the cache already.
	DotPaths.write_bytes(store.partial_path(have), _blob(50, 512))
	_check("partial planted", store.partial_size(have) == 512)

	# Something genuinely resumable: no object, and recent.
	var pending := DotHash.sha256_bytes(_blob(51, OBJ))
	DotPaths.write_bytes(store.partial_path(pending), _blob(51, 256))

	var swept := store.sweep_partials(86400.0)
	_check("dead partial swept", swept == 1 and store.partial_size(have) == 0,
		"%d swept, %d B left" % [swept, store.partial_size(have)])
	_check("resumable partial kept", store.partial_size(pending) == 256,
		"%d B" % store.partial_size(pending))

	var aged := store.sweep_partials(0.0)
	_check("stale partial swept", aged == 1 and store.partial_size(pending) == 0)

	store.close()
	_line("")


# --- 6. Verification and clearing ------------------------------------------

func _section_verify_and_clear() -> void:
	_line("[b]6. storage that changed underneath us[/b]")

	var dir := WORK.path_join("verify")
	var cfg := _config(dir, 0)
	var store: DotCloudStore = await _open_store(dir, 0)
	if store == null:
		return

	var sound := await _commit_for(store, 60)
	var rotted := await _commit_for(store, 61)

	# Same length, different bytes: a failing disk, or a half-written flush. The
	# cheap existence check cannot see this, which is exactly why verify_all
	# exists and why it is opt-in.
	DotPaths.write_bytes(_path_of(cfg, rotted), _blob(62, OBJ))
	_check("corruption is invisible to has()", store.has(rotted))

	var verified: DotResult = await store.verify_all(_scheduler)
	var v: Dictionary = verified.value
	_check("verify_all runs", verified.ok and int(v.get("checked", 0)) == 2,
		"checked %s" % str(v.get("checked")))
	_check("drops the bad object", int(v.get("dropped", 0)) == 1 and not store.has(rotted))
	_check("keeps the good one", store.has(sound))
	_check("accounting after verify", store.total_bytes() == OBJ,
		"%d B" % store.total_bytes())

	var cleared := store.clear_all()
	_check("clear_all", cleared.ok and store.object_count() == 0
		and store.total_bytes() == 0 and not store.has(sound))
	_check("directories survive",
		DirAccess.dir_exists_absolute(cfg.objects_dir())
		and _objects_on_disk(cfg).is_empty())

	store.close()
	_line("")


# --- Helpers ---------------------------------------------------------------

func _config(dir: String, limit: int) -> DotCloudConfig:
	var cfg := DotCloudConfig.new()
	cfg.cache_dir = dir
	cfg.cache_bytes = limit
	return cfg


func _open_store(dir: String, limit: int) -> DotCloudStore:
	var store := DotCloudStore.new(_config(dir, limit))
	var opened: DotResult = await store.open()
	if not opened.ok:
		_fail("opening the store at %s" % dir, opened)
		return null
	return store


## Deterministic filler. Content-addressing means the bytes decide the hash, so
## the same seed always names the same object and a test can re-derive it.
func _blob(seed_byte: int, size: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(size)
	for i in range(size):
		b[i] = (seed_byte * 7 + i) % 251
	return b


func _commit(store: DotCloudStore, bytes: PackedByteArray) -> DotResult:
	var h := DotHash.sha256_bytes(bytes)
	var wrote := DotPaths.write_bytes(store.partial_path(h), bytes)
	if not wrote.ok:
		return wrote
	var res: DotResult = await store.commit_partial(h)
	return res


func _commit_for(store: DotCloudStore, seed_byte: int) -> String:
	var bytes := _blob(seed_byte, OBJ)
	var res: DotResult = await _commit(store, bytes)
	if not res.ok:
		_fail("committing object %d" % seed_byte, res)
		return ""
	return DotHash.sha256_bytes(bytes)


## What is actually in objects/, worked out without asking the store — the whole
## point of the index assertions is that the two can disagree.
func _objects_on_disk(cfg: DotCloudConfig) -> Dictionary:
	var out := {}
	for rel in DotPaths.list_files_recursive(cfg.objects_dir()):
		var name := String(rel).get_file()
		if name.length() != 64:
			continue
		out[name] = DotPaths.file_size(cfg.objects_dir().path_join(rel))
	return out


func _path_of(cfg: DotCloudConfig, sha256: String) -> String:
	return cfg.objects_dir().path_join("%s/%s" % [sha256.substr(0, 2), sha256])


func _sum(d: Dictionary) -> int:
	var n := 0
	for k in d:
		n += int(d[k])
	return n


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

	_line("  %s %s%s" % [label.rpad(28), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
	if _output != null:
		_output.append_text(text + "\n")
