@tool
class_name DotCloudSourceNetchan
extends DotCloudSource

## Fetches content down the multiplayer connection itself.
##
## The universal fallback: it needs no web server, no CDN, no CORS policy and no
## certificate, and it works from a browser because the game connection is already
## open. It is the same trade Source made before FastDL — the server pays for the
## bandwidth, and a full content set arriving over the game channel is slow.
##
## Use it as the last source in the list. A server with a CDN never touches it; a
## server on someone's home connection can still be played.
##
## [b]Decoupling.[/b] dot-cloud must not depend on dot-server, so this class does
## not know how to send a packet. It calls a delegate — any object with the two
## methods below — and dot-server supplies one backed by its own RPCs:
##
## [codeblock]
## # The delegate contract
## func cloud_chunk_size() -> int
## func cloud_request_chunk(sha256: String, offset: int, length: int) -> DotResult
## #   -> DotResult.success(PackedByteArray) with up to `length` bytes from `offset`,
## #      or a failure. A short read means end-of-file.
## [/codeblock]
##
## The delegate is responsible for rate limiting and for refusing hashes the
## client has no business asking for — a server that serves any hash on request
## becomes a way to read its cache.

## Object implementing the delegate contract above.
##
## Not exported: it is a live connection object, set at runtime by whatever owns
## the multiplayer session.
var delegate: Object = null

## Bytes requested per round trip when the delegate does not specify.
##
## Sized to fit comfortably inside the transport's per-peer buffer — see
## [member DotTransportWebSocket.inbound_buffer_exp]. Too large and packets are
## dropped for exceeding the buffer, which presents as a stalled download.
@export var default_chunk_bytes: int = 65536

## Round trips before giving up on a file.
##
## A ceiling on how long one file can occupy the channel: with a 64 KiB chunk this
## permits about 1 GiB, well past anything that should be shipped in-band.
@export var max_chunks_per_file: int = 16384

## Seconds to wait for one chunk.
@export_range(1.0, 300.0, 1.0) var chunk_timeout_sec: float = 30.0

## Seconds one file may spend in transit before the transfer is abandoned.
## Zero removes the limit.
##
## [member max_chunks_per_file] bounds the round trips and
## [member chunk_timeout_sec] bounds each individual wait, but nothing bounded
## their product. A peer that answers every chunk — correctly, in full, just
## slowly — inside the per-chunk deadline holds the channel for up to
## 16384 × 30 s, which is over 130 hours. Each wait is legitimate on its own, so
## the circuit breaker never sees a failure to count and the transfer never ends.
##
## This is the in-band source, so that channel is the game connection: the cost
## is not only a stalled download but a session spending its bandwidth on one.
## Ten minutes is generous for content that should be small enough to ship in
## band at all, and a deployment that genuinely moves more than that over the
## game channel can raise it or set it to zero.
##
## Like the per-chunk timeout, this keeps the partial: a slow peer is a reason to
## come back later, not a reason to throw away what arrived.
@export_range(0.0, 7200.0, 1.0) var file_timeout_sec: float = 600.0

## Bytes buffered before being appended to the partial file.
##
## Writing every 64 KiB chunk straight to disk is a syscall per chunk, and on web
## an IndexedDB transaction per chunk. Batching to 1 MiB cuts that by 16× at the
## cost of re-fetching at most 1 MiB after an interruption.
@export var write_batch_bytes: int = 1024 * 1024


func source_name() -> String:
	return "netchan"


func is_supported() -> DotResult:
	if delegate == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No netchan delegate is set.",
			"dot-server sets this when a session is established"
		)

	for method in ["cloud_request_chunk", "cloud_chunk_size"]:
		if not delegate.has_method(method):
			return DotResult.fail(
				DotError.CODE_STATE,
				"The netchan delegate is missing %s()." % method
			)

	return DotResult.success(true)


func fetch(
	file: DotCloudFile,
	_manifest: DotCloudManifest,
	store: DotCloudStore,
	scheduler: DotScheduler
) -> DotResult:
	var supported := is_supported()
	if not supported.ok:
		return supported

	var chunk_size: int = int(delegate.call("cloud_chunk_size"))
	if chunk_size <= 0:
		chunk_size = default_chunk_bytes

	var partial := store.partial_path(file.sha256)

	# Resume from whatever is already there. Safe because the partial is keyed by
	# content hash, so its bytes can only belong to this file.
	var offset := store.partial_size(file.sha256) if store.config.resume_downloads else 0
	if offset > 0:
		if file.size > 0 and offset >= file.size:
			store.discard_partial(file.sha256)
			offset = 0
		else:
			DotLog.debug(
				CHANNEL,
				"resuming in-band transfer",
				{"file": file.path, "from": offset}
			)

	if offset == 0:
		store.discard_partial(file.sha256)
		var created := DotPaths.write_bytes(partial, PackedByteArray(), false)
		if not created.ok:
			return created

	var buffer := PackedByteArray()
	var chunks := 0
	var started_ms := Time.get_ticks_msec()

	while true:
		var budget := _remaining_budget_sec(started_ms)
		if budget == 0.0:
			note_failure()
			# Same reasoning as the per-chunk timeout below: the transfer stalled,
			# it did not go wrong, so a retry resumes rather than restarting.
			_append(partial, buffer)
			return _file_timed_out(file, offset, chunks)

		chunks += 1
		if chunks > max_chunks_per_file:
			store.discard_partial(file.sha256)
			return DotResult.fail(
				DotError.CODE_INVALID,
				"In-band transfer exceeded its chunk limit.",
				"%s after %d chunks" % [file.path, chunks]
			)

		# Deliberately Variant: the timeout marker is not a DotResult, and a
		# DotResult-typed local makes testing for it a parse error rather than a
		# runtime branch.
		var answer: Variant = await _request_chunk(
			file.sha256, offset, chunk_size, scheduler, budget
		)

		if answer is DotCloudNetchanTimeout:
			note_failure()
			# Keep the partial: the transfer stalled, it did not go wrong. A
			# retry resumes from here rather than restarting.
			_append(partial, buffer)

			# The wait was the smaller of the two deadlines, so a chunk request
			# that started with less than `chunk_timeout_sec` of file budget left
			# comes back here having waited only the remainder. Reporting that as
			# a chunk timeout "after 30s" was wrong twice over — wrong number,
			# and wrong diagnosis: nothing is wrong with the peer's latency, the
			# file simply ran out of time. Ask which deadline actually expired.
			if _remaining_budget_sec(started_ms) == 0.0:
				return _file_timed_out(file, offset, chunks)

			return DotResult.fail(
				DotError.CODE_TIMEOUT,
				"The server did not send an in-band chunk in time.",
				"%s at offset %d, after %.0fs" % [file.path, offset, chunk_timeout_sec]
			)

		var res: DotResult = answer

		if res == null:
			note_failure()
			return DotResult.fail(
				DotError.CODE_NETWORK,
				"The server did not answer an in-band content request.",
				file.path
			)

		if not res.ok:
			note_failure()
			# Whatever has been written stays: the partial is keyed by hash and a
			# later attempt resumes from it. Discarding on a transient network
			# failure would restart a 200 MB transfer over one dropped packet.
			_append(partial, buffer)
			return res.wrap("In-band transfer of '%s' failed." % file.path)

		var bytes: PackedByteArray = res.value
		buffer.append_array(bytes)
		offset += bytes.size()

		if buffer.size() >= write_batch_bytes:
			var flushed := _append(partial, buffer)
			if not flushed.ok:
				return flushed
			buffer = PackedByteArray()

		# A short chunk is end-of-file. Also stop at the manifest's declared size,
		# so a server that keeps sending cannot grow the file indefinitely.
		var short := bytes.size() < chunk_size
		var complete := file.size > 0 and offset >= file.size

		if short or complete:
			break

	var final := _append(partial, buffer)
	if not final.ok:
		return final

	var committed := await store.commit_partial(file.sha256, scheduler)
	if not committed.ok:
		note_failure()
		return committed

	note_success()

	DotLog.debug(
		CHANNEL,
		"in-band transfer complete",
		{"file": file.path, "chunks": chunks, "bytes": offset}
	)

	return committed


## Asks the delegate for one chunk, giving up after [member chunk_timeout_sec].
##
## [b]Why this is not just [code]await delegate.call(...)[/code].[/b] It was, and
## that made the exported timeout above a lie: nothing read it, and
## [member DotCloudConfig.file_timeout_sec] only ever reaches the HTTP source. A
## delegate whose reply never arrives — a peer that vanished without closing its
## socket, the normal shape of a dropped mobile connection — suspended this
## coroutine forever, and with it the downloader awaiting it and the acquire
## awaiting that. No error, no log line, no timeout: the download simply stopped
## existing. This is the one source that cannot fall back to another, so it is
## also the one where hanging is unrecoverable.
##
## The bare statement call plus a completion flag is the family's fan-out
## pattern, and it is required here for the same reason: a delegate that answers
## from a cache without suspending finishes [i]before[/i] this function reaches
## the wait, so a wait entered unconditionally would block on a chunk that has
## already arrived. dot-server's own delegate does exactly that for a file it is
## already holding.
##
## [param budget_sec] is the whole file's remaining time, or [code]INF[/code]
## when [member file_timeout_sec] is zero. The wait is the smaller of it and
## [member chunk_timeout_sec], so a peer that goes silent one second before the
## file deadline is not given another 30 to do it in.
##
## Returns the delegate's [DotResult], or a [DotCloudNetchanTimeout] marker.
func _request_chunk(
	sha256: String,
	offset: int,
	length: int,
	scheduler: DotScheduler,
	budget_sec: float = INF
) -> Variant:
	var box := {"done": false, "res": null}

	# Bare call: runs to its first await, or all the way to completion.
	_request_chunk_into(box, sha256, offset, length)

	if bool(box["done"]):
		return box["res"]

	var tree := scheduler.get_tree() if scheduler != null else null
	if tree == null:
		# Nothing to wait on. Fall back to the unbounded await rather than
		# failing a transfer that would otherwise have worked.
		return await delegate.call("cloud_request_chunk", sha256, offset, length)

	var wait_sec := minf(maxf(chunk_timeout_sec, 1.0), budget_sec)
	var deadline := Time.get_ticks_msec() + int(wait_sec * 1000.0)

	while not bool(box["done"]):
		if Time.get_ticks_msec() >= deadline:
			# The abandoned coroutine still holds this box and will write to it
			# if the reply ever lands. Every call gets a fresh one, so a late
			# arrival cannot be mistaken for the next chunk.
			return DotCloudNetchanTimeout.new()

		await tree.process_frame

	return box["res"]


## Awaits one delegate call and records that it finished.
##
## Every return path must set [code]done[/code], including the failing ones —
## the caller's loop has no other way to tell "still waiting" from "answered".
func _request_chunk_into(
	box: Dictionary, sha256: String, offset: int, length: int
) -> void:
	var r: Variant = await delegate.call("cloud_request_chunk", sha256, offset, length)
	box["res"] = r
	box["done"] = true


## The [member file_timeout_sec] failure, built in one place because two paths
## reach it: the check at the top of the loop, and a chunk wait that was cut
## short by the remaining budget rather than by [member chunk_timeout_sec].
func _file_timed_out(file: DotCloudFile, offset: int, chunks: int) -> DotResult:
	return DotResult.fail(
		DotError.CODE_TIMEOUT,
		"The in-band transfer took too long.",
		"%s stopped at offset %d after %.0fs and %d chunks" % [
			file.path, offset, file_timeout_sec, chunks
		]
	)


## Seconds left in this file's budget, or [code]INF[/code] when it has none.
##
## Returns exactly [code]0.0[/code] when the budget is spent, so callers can test
## for it without a second comparison against a limit that may be infinite.
func _remaining_budget_sec(started_ms: int) -> float:
	if file_timeout_sec <= 0.0:
		return INF

	var elapsed := float(Time.get_ticks_msec() - started_ms) / 1000.0
	return maxf(0.0, file_timeout_sec - elapsed)


## Appends to the partial file. A no-op for an empty buffer.
func _append(path: String, bytes: PackedByteArray) -> DotResult:
	if bytes.is_empty():
		return DotResult.success(0)

	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(),
				"opening '%s' to append" % path
			)
		)

	f.seek_end()
	f.store_buffer(bytes)
	f.close()

	DotWeb.sync_filesystem()
	return DotResult.success(bytes.size())


func health() -> Dictionary:
	var d := super.health()
	d["delegate"] = delegate.get_class() if delegate != null else "<none>"
	return d
