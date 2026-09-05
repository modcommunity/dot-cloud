@tool
class_name DotCloudDownloader
extends Node

## Fetches everything a manifest needs, in parallel, from whichever sources work.
##
## Owns the concurrency, the retry-and-failover policy, the bandwidth throttle and
## the aggregate progress. Sources own the "how" of one file; this owns the "which
## files, how many at once, and what to do when it goes wrong".
##
## [codeblock]
## var dl := DotCloudDownloader.new()
## add_child(dl)
## dl.config = config
## dl.store = store
## dl.scheduler = scheduler
## dl.sources = [http_source, netchan_source]
##
## dl.progress_changed.connect(func(p): bar.value = p.fraction * 100.0)
## var res := await dl.sync(manifest)
## [/codeblock]
##
## [b]On deduplication.[/b] Work is queued by unique content hash, not by manifest
## entry. A manifest listing the same file at four paths downloads it once, and the
## progress total reflects that from the start rather than jumping when the
## duplicates are discovered.

const CHANNEL := "cloud.dl"

## Aggregate progress. Emitted at most every
## [member DotCloudConfig.progress_interval_sec], because a 6-way parallel
## download produces thousands of chunk events a second and no UI can use them.
##
## The payload is [code]{fraction, done_files, total_files, done_bytes,
## total_bytes, bytes_per_sec, eta_sec, active}[/code].
signal progress_changed(progress: Dictionary)

## One file finished, successfully or not.
signal file_finished(file: DotCloudFile, result: DotResult)

## Everything finished. The result carries [code]{fetched, skipped, failed}[/code].
signal sync_finished(result: DotResult)

## Internal: one pool worker has drained the queue and returned.
##
## Exists because GDScript offers no way to await a coroutine you did not await
## at the call site. Always paired with [member _workers_finished] — see the
## fan-out comment in [method sync] for why the count and not the signal is
## authoritative.
signal _worker_done()

var config: DotCloudConfig
var store: DotCloudStore
var scheduler: DotScheduler

## Sources in preference order. Sorted by [member DotCloudSource.priority] on use.
var sources: Array[DotCloudSource] = []

## The HTTP node handed to any [DotCloudSourceHttp] in [member sources].
var _http: DotHttp = null

var _active: int = 0
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
##
## The summary used to name a file and nothing else — "2 missing, first:
## small.txt" — so everything [method _fetch_with_failover] had worked out about
## *why* stopped at the log line and never reached the caller of
## [method DotCloudClient.acquire_manifest]. "Which file" is rarely the question;
## "every source is in cooldown" and "the host 404s" want opposite responses.
var _first_required_failure: DotResult = null

## One entry per required file this sync could not produce, most recent sync
## only. `[{ "path": String, "code": String, "message": String, "detail": String }]`.
##
## The summary [DotResult] can carry a code and a string and nothing else —
## [method DotResult.fail] has no payload on the failure side, and adding one is
## a dot-core change. So the *shape* of the failure lives here instead, on the
## node the caller already holds via [member DotCloudClient.downloader].
##
## It exists because the detail string was the only way to tell "every source is
## in cooldown, come back in a minute" from "no content URL is configured, your
## deployment is wrong", and branching on a substring of a human-readable
## sentence is exactly what [DotError] codes exist to avoid. Read
## [method failure_codes] for the set, or walk this for the per-file breakdown.
##
## Empty after a successful sync, and after a cancelled one — a cancel is not a
## statement about any file.
var last_failure_causes: Array[Dictionary] = []

var _started_ms: int = 0
var _last_emit_ms: int = 0

## Rolling window of (ticks_ms, bytes) samples for the rate estimate.
##
## An average over the whole download is useless for an ETA — it hides that the
## connection died two minutes ago. A short window tracks reality.
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


# --- Syncing ---------------------------------------------------------------

## Downloads everything in [param manifest] that is not already cached.
##
## [param groups] selects optional content groups; empty fetches only what is
## ungrouped (i.e. required).
##
## Returns [code]{fetched, skipped, failed, bytes}[/code]. Succeeds when every
## [member DotCloudFile.required] file is present — optional failures are counted
## and reported, not fatal.
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

	# Make room before starting rather than discovering the cache is full at
	# byte 900,000,000. A shortfall we cannot meet is reported now, while the
	# player can still be told something useful.
	var pruned := store.prune(_total_bytes)
	if not pruned.ok:
		_running = false
		var failed := pruned.wrap("Not enough room for this content.")
		sync_finished.emit(failed)
		return failed

	# Largest first. Long tasks started last are what makes a parallel download
	# finish long after it looks nearly done.
	todo.sort_custom(func(a: DotCloudFile, b: DotCloudFile) -> bool:
		return a.size > b.size
	)

	var results := {}
	var next := 0
	var slots := maxi(1, config.parallel_downloads)

	# A worker pool over the queue rather than a batch barrier: with batches, a
	# single 400 MB file holds up five idle slots until it finishes.
	#
	# The fan-out idiom is worth explaining, because both obvious spellings are
	# wrong.
	#
	# GDScript has no task handle: a coroutine cannot be stored and awaited
	# later, so `workers.append(_worker(...))` is a parse error ("cannot get
	# return value of a call that returns void"). What works is calling each
	# worker as a bare statement — that runs it up to its first `await` and
	# leaves it running — then waiting for completions.
	#
	# The second trap is subtler and cost a hung test to find. A worker only
	# suspends if it actually awaits something, and a source that resolves
	# synchronously (DotCloudSourceLocal, or an HTTP source hitting a warm cache)
	# never does. Those workers run to completion *inside the call above*, so
	# `while remaining > 0: await _worker_done` waits for signals that were all
	# emitted before the await existed, and hangs forever.
	#
	# So completions are counted in a member variable rather than by counting
	# signal deliveries. When every worker finished synchronously the loop
	# condition is already false and nothing is awaited at all.
	var worker_count := mini(slots, todo.size())
	_workers_finished = 0

	for _i in range(worker_count):
		_worker(todo, results, manifest)

	while _workers_finished < worker_count:
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
		# The cause goes in the detail rather than replacing the message, and the
		# code stays CODE_NETWORK: callers branch on codes, and a first failure
		# that happened to be CODE_STATE or CODE_TIMEOUT would otherwise change
		# what this call returns depending on which file lost the race.
		# The per-file breakdown, for a caller that wants to act on the kind of
		# failure rather than print it. `results` is keyed by hash, and a file
		# with no entry at all never reached a worker — record that as such
		# rather than dropping it, or the causes and the count disagree.
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


## One pool worker: takes the next queued file until the queue is empty.
##
## Every return path must emit [signal _worker_done] — [method sync] counts them
## to know when the pool has drained, and a worker that returns silently leaves
## it awaiting forever.
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
		var res := await _fetch_with_failover(file, manifest)
		_active -= 1

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
		# Naming each source and its reason, rather than the old blanket
		# "unsupported or in cooldown". Those are opposite problems — one is a
		# deployment mistake, the other resolves itself in `cooldown_sec` — and a
		# player-facing message that cannot tell them apart is a support ticket.
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

	# A source that was skipped is invisible in `last`, which only carries the
	# complaint of whichever source was tried last. With one source in cooldown
	# and one that simply has nowhere to fetch from, that produced a diagnosis
	# describing neither.
	if not skipped.is_empty():
		return last.wrap(
			"Downloading '%s' failed; skipped %s." % [file.path, "; ".join(skipped)]
		)

	return last


## Sources worth trying for this manifest, best first.
##
## Excludes three different things, and appends a sentence to [param skipped]
## for each so the caller can say which:
##
## - unsupported on this platform, or missing a collaborator;
## - in circuit-breaker cooldown after repeated failures;
## - healthy, but with no way to reach [param manifest]'s content.
##
## The third is why this takes a manifest at all. [DotCloudClient] always builds
## an HTTP source, so a netchan-only deployment carried one with no base URLs
## permanently ahead of the source that could actually serve it — spending an
## attempt per file on a guaranteed failure, and speaking for the whole download
## once netchan backed off. See [method DotCloudSource.can_serve].
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


# --- Throttling ------------------------------------------------------------

## Waits long enough to keep under [member DotCloudConfig.throttle_bytes_per_sec].
##
## Per-file rather than per-chunk, because [method DotHttp.download_to_file] does
## not expose chunk callbacks. Coarse: a single large file overshoots its second
## and the next file waits it off. Good enough for its purpose, which is leaving
## a playable connection while content downloads in the background — not precise
## shaping.
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


# --- Progress -------------------------------------------------------------

func _reset_progress() -> void:
	_total_bytes = 0
	_done_bytes = 0
	_total_files = 0
	_done_files = 0
	_failed_files = 0
	_first_required_failure = null
	last_failure_causes.clear()
	_active = 0
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


## The distinct [DotError] codes across [member last_failure_causes], sorted.
##
## Sorted so the result is stable: it goes into log lines and demo assertions,
## and dictionary iteration order is not something to hang a comparison on.
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
