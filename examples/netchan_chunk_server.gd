extends RefCounted

## A stand-in for dot-server's in-band content delegate, for [code]netchan_demo[/code].
##
## dot-cloud must not depend on dot-server, so [DotCloudSourceNetchan] talks to
## whatever object implements two methods. That decoupling is also why the source
## had no executable coverage: the only real implementation lives in another
## repository, so nothing here could drive it. This is that implementation's
## shape, reduced to reading bytes out of the published objects directory, with
## the failure modes a real peer has bolted on as switches.

signal chunk_requested(sha256: String, offset: int, length: int)

## Where the publisher wrote its content-addressed objects.
var objects_dir: String = ""

## Node whose tree is used to suspend. A [RefCounted] has none of its own, and
## the point of most of these modes is *when* the reply arrives, not what is in
## it.
var host: Node = null

## Bytes per round trip, as reported to the source.
var chunk_size: int = 4096

## Suspend for a frame before answering. With this false the delegate answers
## without ever suspending, which is the case that breaks naive fan-out code and
## the case a server holding the file in memory actually takes.
var suspends: bool = true

## Never answer at all. A peer that vanished without closing its socket.
var hangs: bool = false

## Seconds to wait before answering. A peer that is working, correctly, and is
## simply slow — the case no per-chunk deadline can catch, because every
## individual wait is legitimate.
var delay_sec: float = 0.0

## Fail every request from this chunk onwards. Negative never fails.
var fail_after_chunks: int = -1

## Ignore the requested length and keep serving past the end of the file, to
## check the source stops at the manifest's declared size rather than trusting
## the peer.
var overserves: bool = false

## Every (offset, length) asked for, in order. The resume check reads this.
var requests: Array[Vector2i] = []

## Bytes actually handed over.
var served: int = 0

var _calls: int = 0


func cloud_chunk_size() -> int:
	return chunk_size


func cloud_request_chunk(sha256: String, offset: int, length: int) -> DotResult:
	_calls += 1
	requests.append(Vector2i(offset, length))
	chunk_requested.emit(sha256, offset, length)

	if hangs:
		# Suspends and never resumes. Before the source grew a chunk timeout this
		# took the whole acquire down with it, silently.
		await host.never_fires
		return DotResult.fail(DotError.CODE_STATE, "unreachable")

	if delay_sec > 0.0:
		await host.get_tree().create_timer(delay_sec).timeout
	elif suspends:
		await host.get_tree().process_frame

	if fail_after_chunks >= 0 and _calls > fail_after_chunks:
		return DotResult.fail(
			DotError.CODE_NETWORK, "Simulated peer failure.", "chunk %d" % _calls
		)

	var path := objects_dir.path_join(_object_rel(sha256))
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return DotResult.fail(
			DotError.CODE_IO, "No such object.", sha256
		)

	var size := int(f.get_length())
	if offset >= size:
		f.close()
		# A zero-length answer is end-of-file, and the source must treat it as
		# one rather than looping until its chunk limit.
		return DotResult.success(PackedByteArray())

	var want := length
	if overserves:
		want = size - offset

	f.seek(offset)
	var bytes := f.get_buffer(min(want, size - offset))
	f.close()

	served += bytes.size()
	return DotResult.success(bytes)


## Mirrors the publisher's object layout. Kept here rather than reusing
## [method DotCloudFile.object_path] because a delegate in another repository
## only ever has the hash.
func _object_rel(sha256: String) -> String:
	return "objects".path_join(sha256.substr(0, 2)).path_join(sha256)
