@tool
class_name DotCloudDownloader
extends Node

## Fetches everything a manifest needs, in parallel, from whichever sources work.
## Owns concurrency, retry-and-failover, the bandwidth throttle and aggregate progress; sources own the how of one file.
## [codeblock]
## var dl := DotCloudDownloader.new()
## add_child(dl)
## dl.config = config
## dl.store = store
## dl.scheduler = scheduler
## dl.sources = [http_source, netchan_source]
## dl.progress_changed.connect(func(p): bar.value = p.fraction * 100.0)
## var res := await dl.sync(manifest)
## [/codeblock]
## Work is queued by unique content hash, so a file listed at four paths downloads once and the
## progress total is right from the start.

const CHANNEL := "cloud.dl"

## Aggregate progress, emitted at most every [member DotCloudConfig.progress_interval_sec] (chunk events arrive thousands a second).
## The payload is [code]{fraction, done_files, total_files, done_bytes, total_bytes, bytes_per_sec, eta_sec, active}[/code].
signal progress_changed(progress: Dictionary)

## One file finished, successfully or not.
signal file_finished(file: DotCloudFile, result: DotResult)

## Everything finished. The result carries [code]{fetched, skipped, failed}[/code].
signal sync_finished(result: DotResult)

## The bundle's objects are in the store, while larger objects may still be downloading.
signal bundle_unpacked(manifest: DotCloudManifest)

## Internal: one pool worker has drained the queue and returned.
## GDScript cannot await a coroutine you did not await at the call site. Paired with
## [member _workers_finished]; see the fan-out comment in [method sync] for why the count is authoritative.
signal _worker_done()

var config: DotCloudConfig
var store: DotCloudStore
var scheduler: DotScheduler

## Sources in preference order. Sorted by [member DotCloudSource.priority] on use.
var sources: Array[DotCloudSource] = []

## The HTTP node handed to any [DotCloudSourceHttp] in [member sources].
var _http: DotHttp = null

## Most files fetched at once by this downloader; 0 = [member DotCloudConfig.parallel_downloads].
var slots_cap := 0

var _active: int = 0

## What is in flight right now, newest first, as player-facing names.
## Which file matters to someone watching a bar (a 200 MB map and a 3 KB manifest both read "4 active").
## An ordered list so a one-line display shows the newest start.
var _active_files: PackedStringArray = PackedStringArray()
var _cancelled: bool = false
var _running: bool = false

## Workers that have drained the queue and returned, this sync.
var _workers_finished: int = 0

# Progress accounting.
var _total_bytes: int = 0
var _done_bytes: int = 0
var _total_files: int = 0
var _done_files: int = 0
var _failed_files: int = 0

## Why the first required file failed, kept for the summary [DotResult].
## What [method _fetch_with_failover] learned about why must reach the caller of
## [method DotCloudClient.acquire_manifest]: "every source is in cooldown" and "the host 404s" want opposite responses.
var _first_required_failure: DotResult = null

## One entry per required file this sync could not produce, latest sync only.
## `[{ "path": String, "code": String, "message": String, "detail": String }]`.
## A failed [DotResult] carries only a code and a string (a payload would be a dot-core change), so the
## per-file shape lives here, on [member DotCloudClient.downloader]; callers branch on codes, not message text.
## See [method failure_codes]. Empty after a success or a cancel (a cancel says nothing about any file).
var last_failure_causes: Array[Dictionary] = []

var _started_ms: int = 0
var _last_emit_ms: int = 0

## Rolling window of (ticks_ms, bytes) samples for the rate estimate.
## A whole-download average hides that the connection died two minutes ago.
var _rate_samples: Array = []

## Bytes charged against the throttle in the current second.
var _throttle_window_start_ms: int = 0
var _throttle_bytes_this_window: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_ensure_http()


func _ensure_http() -> void:
	if _http != null:
		return

	_http = DotHttp.new()
	_http.name = "CloudHttp"
	if config != null:
		_http.timeout_sec = config.file_timeout_sec
		# Sources own failover across mirrors, so the HTTP layer only retries
		# what is worth retrying against the same URL. Two layers of retry
		# multiply into a very long wait before failover happens.
		_http.max_retries = 1
	add_child(_http)


## Downloads everything in [param manifest] that is not already cached.
## [param groups] selects optional content groups; empty fetches only ungrouped (required) files.
## Returns [code]{fetched, skipped, failed, bytes}[/code]. Succeeds when every [member DotCloudFile.required]
## file is present; optional failures are counted, not fatal.
func sync(
	manifest: DotCloudManifest,
	groups: PackedStringArray = PackedStringArray()
) -> DotResult:
	if _running:
		return DotResult.fail(
			DotError.CODE_STATE, "This downloader is already syncing."
		)

	var ready_check := _check_ready()
	if not ready_check.ok:
		return ready_check

	_running = true
	_cancelled = false
	_reset_progress()
	_ensure_http()
	_wire_sources()

	var wanted := manifest.wanted_files(groups)

	# Queue by unique hash. Several manifest entries can share content, and
	# downloading it once is the whole point of content addressing.
	var by_hash := {}
	for f in wanted:
		if not by_hash.has(f.sha256):
			by_hash[f.sha256] = f

	var todo: Array[DotCloudFile] = []
	var skipped := 0

	for h in by_hash:
		var f: DotCloudFile = by_hash[h]
		if store.has(h):
			skipped += 1
			continue
		todo.append(f)
		_total_bytes += f.size

	_total_files = todo.size()
	_started_ms = Time.get_ticks_msec()

	DotLog.info(
		CHANNEL,
		"sync starting",
		{
			"content": manifest.key(),
			"fetch": todo.size(),
			"cached": skipped,
			"bytes": DotPaths.format_bytes(_total_bytes),
		}
	)

	if todo.is_empty():
		_running = false
		var done := DotResult.success({
			"fetched": 0, "skipped": skipped, "failed": 0, "bytes": 0,
		})
		sync_finished.emit(done)
		return done

	# The bundle (one request, CPU-bound unpack) and the objects too big for it share the join's time:
	# the big ones download while the bundle unpacks.
	var plan := _bundle_plan(manifest, todo)
	var big: Array[DotCloudFile] = []
	var small: Array[DotCloudFile] = []
	for f in todo:
		(small if plan.has(f.sha256) else big).append(f)

	# Make room before starting rather than discovering the cache is full at
	# byte 900,000,000. A shortfall we cannot meet is reported now, while the
	# player can still be told something useful.
	var pruned := store.prune(_total_bytes)
	if not pruned.ok and pruned.error.code == DotError.CODE_QUOTA and store.has_measured_free():
		# The ceiling is a share of the quota counted against everything already stored, so it
		# refuses downloads the browser would accept. Only the measured free space may refuse.
		var free := await store.free_bytes()
		if free < 0 or free >= _total_bytes:
			DotLog.info(CHANNEL, "over the cache ceiling but the browser has room; going on",
				{"needed": _total_bytes, "free": free})
			pruned = DotResult.success(0)
		else:
			var report := await store.quota_report()
			var hint := {
				"partitioned": " This page's storage is kept apart from the game site's own, so downloads made there do not count here; open the game directly or clear some content.",
				"near-full": " The browser's storage is nearly full. Delete downloaded content you no longer need.",
				"unreadable": " The browser would not say how much room is left.",
			}.get(report["quota_cause"], " Use \"Clear downloaded content\" in the menu to make room.")
			pruned = DotResult.fail(
				DotError.CODE_QUOTA,
				"Not enough room for this content: it needs %s and the browser has %s free.%s"
					% [DotPaths.format_bytes(_total_bytes), DotPaths.format_bytes(free), hint],
				str(report["quota_cause"])
			)
	if not pruned.ok:
		_running = false
		var failed := pruned if pruned.error.message.begins_with("Not enough room") \
			else pruned.wrap("Not enough room for this content.")
		sync_finished.emit(failed)
		return failed

	var results := {}
	var slots := maxi(1, config.parallel_downloads)
	if slots_cap > 0:
		slots = mini(slots, slots_cap)
	_workers_finished = 0
	# Big objects download while the bundle unpacks, and addon classes prewarm once it has.
	var started_workers := _start_pool(big, results, manifest, slots)
	if not plan.is_empty():
		skipped += await _run_bundle(manifest, plan)
		var left: Array[DotCloudFile] = []
		for f in small:
			if store.has(f.sha256):
				_done_files += 1
				_note_bytes(f.size)
			else:
				left.append(f)
		started_workers += _start_pool(left, results, manifest, slots)

	while _workers_finished < started_workers:
		await _worker_done

	store.flush_index()

	var fetched := 0
	for h in results:
		if (results[h] as DotResult).ok:
			fetched += 1

	_running = false

	var missing_required := PackedStringArray()
	for f in wanted:
		if f.required and not store.has(f.sha256):
			missing_required.append(f.path)

	var payload := {
		"fetched": fetched,
		"skipped": skipped,
		"failed": _failed_files,
		"bytes": _done_bytes,
	}

	var outcome: DotResult

	if _cancelled:
		outcome = DotResult.fail(
			DotError.CODE_CANCELLED, "The download was cancelled."
		)
	elif not missing_required.is_empty():
		# The cause goes in the detail and the code stays CODE_NETWORK, so the result does not change with
		# which file lost the race.
		# The per-file breakdown, for callers that act on the kind of failure. A file with no entry in
		# `results` never reached a worker; record that, or the causes and the count disagree.
		for f in wanted:
			if not f.required or store.has(f.sha256):
				continue

			var res: DotResult = results.get(f.sha256, null)
			var err: DotError = res.error if res != null and not res.ok else null

			last_failure_causes.append({
				"path": f.path,
				"code": err.code if err != null else DotError.CODE_STATE,
				"message": (
					err.message if err != null
					else "The file was never attempted."
				),
				"detail": err.detail if err != null else "",
			})

		var detail := "%d missing, first: %s" % [
			missing_required.size(), missing_required[0]
		]
		if _first_required_failure != null:
			detail += " — %s" % str(_first_required_failure.error)

		# The distinct codes, so the one line a bug report pastes still says
		# whether these files failed for one reason or several.
		var codes := failure_codes()
		if codes.size() > 1:
			detail += " [codes: %s]" % ", ".join(codes)

		outcome = DotResult.fail(
			DotError.CODE_NETWORK,
			"Some required content could not be downloaded.",
			detail
		)
	else:
		# Claim the objects so eviction leaves them alone while they are mounted.
		store.add_refs(manifest.key(), manifest.unique_hashes())
		store.flush_index()
		outcome = DotResult.success(payload)

	if outcome.ok:
		# The last object's save must have landed before the pack counts as cached.
		var flushed := await DotWeb.flush_filesystem(get_tree())
		if not flushed.ok:
			DotLog.warn(CHANNEL, "browser storage did not keep the download; it will be fetched again next visit", {"content": manifest.key()})

	DotLog.info(
		CHANNEL,
		"sync finished" if outcome.ok else "sync failed",
		{
			"content": manifest.key(),
			"fetched": fetched,
			"failed": _failed_files,
			"bytes": DotPaths.format_bytes(_done_bytes),
			"seconds": "%.1f" % (float(Time.get_ticks_msec() - _started_ms) / 1000.0),
		}
	)

	_emit_progress(true)
	sync_finished.emit(outcome)
	return outcome


## Starts a worker pool over [param files] (largest first) and returns how many workers it started.
## A pool, not a batch barrier: one 400 MB file would hold up five idle slots. GDScript has no task
## handle, so each worker is a bare call running to its first `await`; completions are counted in a
## member because a synchronous source never suspends and its signals fire before anything awaits.
func _start_pool(files: Array[DotCloudFile], results: Dictionary, manifest: DotCloudManifest, slots: int) -> int:
	# Largest first. Long tasks started last are what makes a parallel download
	# finish long after it looks nearly done.
	files.sort_custom(func(a: DotCloudFile, b: DotCloudFile) -> bool:
		return a.size > b.size
	)
	var count := mini(slots, files.size())
	for _i in range(count):
		_worker(files, results, manifest)
	return count


## The hashes the bundle would carry, or empty when it is not used: no usable bundle, or it
## would not carry enough of what is missing.
func _bundle_plan(manifest: DotCloudManifest, todo: Array[DotCloudFile]) -> Dictionary:
	var decl := manifest.usable_bundle()
	if decl.is_empty() or not config.use_bundles:
		return {}
	var cap := int(decl["max_object_bytes"])
	var wanted := {}
	var bytes := 0
	for f in todo:
		if f.size <= cap:
			wanted[f.sha256] = true
			bytes += f.size
	# A refresh that lacks three files should ask for three files, not a whole archive.
	if wanted.size() < config.bundle_min_missing or bytes * 2 < int(decl["size"]):
		return {}
	return wanted


## Fetches the bundle for [param wanted] and returns how many objects it put in the store (0:
## it failed and per-file takes over).
func _run_bundle(manifest: DotCloudManifest, wanted: Dictionary) -> int:
	_active_files.append("content bundle")
	_emit_progress(true)
	var got := 0
	for s in _ordered_sources(manifest, [] as Array[String]):
		if not s.has_method("fetch_bundle"):
			continue
		var res: DotResult = await s.fetch_bundle(manifest, store, scheduler, wanted)
		if res.ok:
			got = int(res.value["objects"])
			break
		DotLog.warn(CHANNEL, "bundle failed; fetching files one by one", {"why": str(res.error)})
	_active_files.erase("content bundle")
	DotLog.info(CHANNEL, "bundle", {"content": manifest.key(), "objects": got, "of": wanted.size()})
	if got > 0:
		bundle_unpacked.emit(manifest)
	return got


## One pool worker: takes the next queued file until the queue is empty.
## Every return path must emit [signal _worker_done]; [method sync] counts them, and a silent return hangs it.
func _worker(
	queue: Array[DotCloudFile],
	results: Dictionary,
	manifest: DotCloudManifest
) -> void:
	while true:
		if _cancelled:
			_workers_finished += 1
			_worker_done.emit()
			return

		var file: DotCloudFile = null
		# Single-threaded coroutines, so popping is atomic with respect to the
		# other workers: no lock is needed and none would help.
		if not queue.is_empty():
			file = queue.pop_front()

		if file == null:
			_workers_finished += 1
			_worker_done.emit()
			return

		_active += 1
		_active_files.append(file.display_name())
		# Emitted on a file's start as well as its bytes, or a byte-driven display shows the previous
		# file's name until the new one produces its first chunk.
		_emit_progress(true)

		var res := await _fetch_with_failover(file, manifest)

		_active -= 1
		var at := _active_files.find(file.display_name())
		if at >= 0:
			_active_files.remove_at(at)

		results[file.sha256] = res

		if res.ok:
			_done_files += 1
			_note_bytes(file.size)
		else:
			_failed_files += 1
			if file.required:
				if _first_required_failure == null:
					_first_required_failure = res
				DotLog.warn(
					CHANNEL,
					"required content failed",
					{"file": file.path, "why": res.error.message}
				)
			else:
				DotLog.debug(
					CHANNEL,
					"optional content failed",
					{"file": file.path, "why": res.code()}
				)

		file_finished.emit(file, res)
		_emit_progress(false)

		await _apply_throttle(file.size)


## Tries every available source, in priority order, with retries.
func _fetch_with_failover(
	file: DotCloudFile,
	manifest: DotCloudManifest
) -> DotResult:
	var skipped: Array[String] = []
	var ordered := _ordered_sources(manifest, skipped)
	if ordered.is_empty():
		# Name each source and its reason: unsupported-or-cooldown hides opposite problems (a deployment
		# mistake vs. one that resolves in `cooldown_sec`).
		return DotResult.fail(
			DotError.CODE_STATE,
			"No content source is available.",
			"; ".join(skipped) if not skipped.is_empty() else "no sources are configured"
		)

	var attempts := 0
	var last: DotResult = null

	for source in ordered:
		while attempts < config.max_attempts_per_file:
			if _cancelled:
				return DotResult.fail(
					DotError.CODE_CANCELLED, "Cancelled."
				)

			attempts += 1
			last = await source.fetch(file, manifest, store, scheduler)

			if last.ok:
				return last

			# An integrity failure means this source served wrong bytes. Retrying
			# it gets the same wrong bytes; move on immediately.
			if last.code() == DotError.CODE_INTEGRITY:
				break

			# Nothing retryable left — a 404 is a 404 on every attempt.
			if not last.is_retryable():
				break

		if attempts >= config.max_attempts_per_file:
			break

	if last == null:
		return DotResult.fail(
			DotError.CODE_NETWORK, "No source could provide this content."
		)

	# A skipped source is invisible in `last`, which carries only the last-tried source's complaint,
	# so with one in cooldown and one with nowhere to fetch the diagnosis described neither.
	if not skipped.is_empty():
		return last.wrap(
			"Downloading '%s' failed; skipped %s." % [file.path, "; ".join(skipped)]
		)

	return last


## Sources worth trying for this manifest, best first.
## Excludes unsupported or collaborator-less sources, those in circuit-breaker cooldown, and healthy ones
## with no way to reach [param manifest]'s content, appending a sentence to [param skipped] for each.
## The third is why this takes a manifest: an always-built HTTP source with no base URLs would sit ahead of
## the netchan source that can serve, wasting an attempt per file. See [method DotCloudSource.can_serve].
func _ordered_sources(
	manifest: DotCloudManifest, skipped: Array[String]
) -> Array[DotCloudSource]:
	var out: Array[DotCloudSource] = []

	for s in sources:
		if s == null:
			continue

		if not s.is_available():
			skipped.append("%s (%s)" % [s.source_name(), s.unavailable_reason()])
			continue

		var serviceable := s.can_serve(manifest)
		if not serviceable.ok:
			skipped.append("%s (%s)" % [
				s.source_name(), serviceable.error.message.trim_suffix(".")
			])
			continue

		out.append(s)

	out.sort_custom(func(a: DotCloudSource, b: DotCloudSource) -> bool:
		return a.priority < b.priority
	)
	return out


func _wire_sources() -> void:
	for s in sources:
		var http_source := s as DotCloudSourceHttp
		if http_source != null and http_source.http == null:
			http_source.http = _http


func _check_ready() -> DotResult:
	if config == null:
		return DotResult.fail(DotError.CODE_STATE, "Downloader has no config.")
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "Downloader has no store.")
	if sources.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE, "Downloader has no sources."
		)
	return DotResult.success(true)


## Stops the sync. In-flight files finish or fail on their own.
func cancel() -> void:
	if not _running:
		return
	_cancelled = true
	DotLog.info(CHANNEL, "sync cancelled")


func is_running() -> bool:
	return _running


## Waits long enough to keep under [member DotCloudConfig.throttle_bytes_per_sec].
## Per file, since [method DotHttp.download_to_file] has no chunk callbacks, so coarse: a large file
## overshoots its second and the next waits it off. Enough to leave a playable connection, not precise shaping.
func _apply_throttle(bytes: int) -> void:
	if config.throttle_bytes_per_sec <= 0 or bytes <= 0:
		return

	var now := Time.get_ticks_msec()
	if now - _throttle_window_start_ms >= 1000:
		_throttle_window_start_ms = now
		_throttle_bytes_this_window = 0

	_throttle_bytes_this_window += bytes

	if _throttle_bytes_this_window <= config.throttle_bytes_per_sec:
		return

	var over := _throttle_bytes_this_window - config.throttle_bytes_per_sec
	var wait := float(over) / float(config.throttle_bytes_per_sec)
	wait = minf(wait, 10.0)

	_throttle_bytes_this_window = 0
	_throttle_window_start_ms = Time.get_ticks_msec() + int(wait * 1000.0)

	await get_tree().create_timer(wait).timeout


func _reset_progress() -> void:
	_total_bytes = 0
	_done_bytes = 0
	_total_files = 0
	_done_files = 0
	_failed_files = 0
	_first_required_failure = null
	last_failure_causes.clear()
	_active = 0
	_active_files = PackedStringArray()
	_rate_samples.clear()
	_last_emit_ms = 0
	_throttle_bytes_this_window = 0
	_throttle_window_start_ms = Time.get_ticks_msec()


func _note_bytes(n: int) -> void:
	_done_bytes += n
	_rate_samples.append([Time.get_ticks_msec(), n])

	# Keep a 5-second window.
	var cutoff := Time.get_ticks_msec() - 5000
	while not _rate_samples.is_empty() and int(_rate_samples[0][0]) < cutoff:
		_rate_samples.pop_front()


func _emit_progress(force: bool) -> void:
	var now := Time.get_ticks_msec()
	if not force:
		var interval := int(config.progress_interval_sec * 1000.0)
		if now - _last_emit_ms < interval:
			return
	_last_emit_ms = now

	progress_changed.emit(progress())


## Current aggregate progress.
func progress() -> Dictionary:
	var rate := bytes_per_sec()

	var fraction := 0.0
	if _total_bytes > 0:
		fraction = clampf(float(_done_bytes) / float(_total_bytes), 0.0, 1.0)
	elif _total_files > 0:
		# Fall back to counting files when the manifest declared no sizes;
		# a bar stuck at zero for a working download is worse than a coarse one.
		fraction = clampf(float(_done_files) / float(_total_files), 0.0, 1.0)

	var eta := -1.0
	if rate > 1.0 and _total_bytes > _done_bytes:
		eta = float(_total_bytes - _done_bytes) / rate

	return {
		"fraction": fraction,
		"done_files": _done_files,
		"total_files": _total_files,
		"failed_files": _failed_files,
		"done_bytes": _done_bytes,
		"total_bytes": _total_bytes,
		"bytes_per_sec": rate,
		"eta_sec": eta,
		"active": _active,
		"active_files": _active_files.duplicate(),
		# The one a single-line display should name. Empty between files, which a
		# caller should render as "the last thing it said" rather than as blank.
		"current_file": _active_files[_active_files.size() - 1] if not _active_files.is_empty() else "",
	}


## Throughput over the last few seconds, in bytes/sec.
func bytes_per_sec() -> float:
	if _rate_samples.size() < 2:
		return 0.0

	var first_ms := int(_rate_samples[0][0])
	var last_ms := int(_rate_samples[_rate_samples.size() - 1][0])
	var span := float(last_ms - first_ms) / 1000.0

	if span <= 0.001:
		return 0.0

	var total := 0
	for s in _rate_samples:
		total += int(s[1])

	return float(total) / span


## A one-line summary for a loading screen.
func progress_text() -> String:
	var p := progress()

	if int(p["total_files"]) == 0:
		return "Content is up to date."

	var s := "%s / %s" % [
		DotPaths.format_bytes(int(p["done_bytes"])),
		DotPaths.format_bytes(int(p["total_bytes"])),
	]

	var rate := float(p["bytes_per_sec"])
	if rate > 1.0:
		s += "  (%s/s" % DotPaths.format_bytes(int(rate))
		var eta := float(p["eta_sec"])
		if eta >= 0.0:
			s += ", %s left" % _format_duration(eta)
		s += ")"

	return s


static func _format_duration(seconds: float) -> String:
	if seconds < 60.0:
		return "%ds" % int(seconds)
	if seconds < 3600.0:
		return "%dm %ds" % [int(seconds / 60.0), int(fmod(seconds, 60.0))]
	return "%dh %dm" % [int(seconds / 3600.0), int(fmod(seconds, 3600.0) / 60.0)]


## The distinct [DotError] codes across [member last_failure_causes], sorted so log lines and demo
## assertions are stable.
func failure_codes() -> PackedStringArray:
	var seen := {}
	for c in last_failure_causes:
		seen[c.get("code", DotError.CODE_STATE)] = true

	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


func describe() -> Dictionary:
	var d := progress()
	d["running"] = _running
	d["failure_causes"] = last_failure_causes.duplicate(true)
	d["failure_codes"] = failure_codes()
	d["sources"] = []
	for s in sources:
		if s != null:
			d["sources"].append(s.health())
	return d
