@tool
class_name DotCloudSourceHttp
extends DotCloudSource

## Fetches content over HTTP, from a web server or CDN.
##
## The normal way to deliver content: the game server hands out a manifest and
## never touches a byte of the payload, so serving 500 players costs the same as
## serving one.
##
## [b]Content-addressed URLs by default.[/b] A file is fetched from
## [code]<base>/objects/<aa>/<hash>[/code] unless its manifest entry overrides
## [member DotCloudFile.url_path]. Immutable paths mean a CDN can cache
## everything forever with no invalidation story, and two games sharing a file
## share the cache entry too.
##
## [b]What a browser needs from your content host.[/b] In a web build every fetch
## is subject to CORS, and a misconfigured host fails with no usable error —
## [code]fetch()[/code] deliberately will not say why. The host must send:
##
## [codeblock]
## Access-Control-Allow-Origin: https://your-game-origin
## Access-Control-Allow-Headers: Range
## Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, ETag
## [/codeblock]
##
## Without [code]Access-Control-Allow-Headers: Range[/code] resume is impossible;
## without the exposed headers it is impossible to detect that. Serving content
## from the same origin as the game avoids all of it, which is why
## [DotTransportWebSocket] defaults to a path rather than the root — one hostname
## can carry both.

## Base URLs, tried in order. Overridden by the manifest's own mirrors when it
## has any.
@export var base_urls: PackedStringArray = PackedStringArray()

## Subdirectory under a base URL where content-addressed objects live.
@export var objects_prefix: String = "objects"

## Extra headers, e.g. an API key for a private content host.
@export var headers: Dictionary = {}

## The HTTP client. Injected by [DotCloudDownloader]; not exported because it is
## a [Node] and must live in the tree.
var http: DotHttp = null

## Base URL that last worked, tried first next time.
##
## Sticky rather than round-robin: mixing a fast mirror and a slow one at random
## makes the whole download as slow as the average, and there is no benefit to
## spreading load a CDN already handles.
var _preferred_base: String = ""


func source_name() -> String:
	return "http"


## Whether a URL can be built for this manifest at all.
##
## Mirrors arrive with the manifest, so this cannot be answered by
## [method is_supported], which has none. [DotCloudClient] always builds an HTTP
## source whether or not it was given any base URLs — deliberately, since a
## manifest may carry its own mirrors — so "configured but with nowhere to
## fetch from" is the normal state of a netchan-only or local-only deployment,
## not a misconfiguration to shout about. The downloader skips it instead.
func can_serve(manifest: DotCloudManifest) -> DotResult:
	if manifest != null and not _resolve_bases(manifest).is_empty():
		return DotResult.success(true)
	if manifest == null and not base_urls.is_empty():
		return DotResult.success(true)
	return DotResult.fail(
		DotError.CODE_INVALID,
		"No content URL is configured.",
		"set base_urls on the source, or mirrors in the manifest"
	)


func is_supported() -> DotResult:
	if http == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"DotCloudSourceHttp has no DotHttp node.",
			"DotCloudDownloader normally injects one"
		)
	return DotResult.success(true)


func fetch(
	file: DotCloudFile,
	manifest: DotCloudManifest,
	store: DotCloudStore,
	scheduler: DotScheduler
) -> DotResult:
	var supported := is_supported()
	if not supported.ok:
		return supported

	var serviceable := can_serve(manifest)
	if not serviceable.ok:
		return serviceable

	var bases := _resolve_bases(manifest)

	var last: DotResult = null

	for base in bases:
		var url := _build_url(base, file)

		var resume_from := 0
		if store.config.resume_downloads:
			resume_from = store.partial_size(file.sha256)

			# A partial at or beyond the expected size is not resumable — either
			# the manifest's size is wrong or the partial belongs to a different
			# byte stream. Starting over is the only safe move.
			if file.size > 0 and resume_from >= file.size:
				store.discard_partial(file.sha256)
				resume_from = 0

		var res := await http.download_to_file(
			url, store.partial_path(file.sha256), resume_from, headers
		)

		if not res.ok and resume_from > 0:
			# A rejected range is the expected failure when a host does not
			# support them. Retry the same mirror from zero before writing it off.
			DotLog.debug(
				CHANNEL,
				"resume failed; restarting from zero",
				{"file": file.path, "why": res.code()}
			)
			store.discard_partial(file.sha256)
			res = await http.download_to_file(
				url, store.partial_path(file.sha256), 0, headers
			)

		if not res.ok:
			last = res
			note_failure()
			DotLog.debug(
				CHANNEL,
				"mirror failed",
				{"base": base, "file": file.path, "why": res.code()}
			)
			continue

		var committed := await store.commit_partial(file.sha256, scheduler)

		if not committed.ok and resume_from > 0:
			# A resumed transfer that fails its hash indicts the bytes that were
			# already on disk, not the mirror. Those came from an earlier
			# interrupted attempt and nothing has ever verified them: a process
			# killed mid-write, a bad sector, a proxy that answered a range with
			# the wrong window, or an HTTP layer whose resume does not append.
			# The mirror, meanwhile, has just been observed serving a response
			# of the expected length.
			#
			# commit_partial has already discarded the partial, so one restart
			# from zero settles which half was at fault, and costs a
			# re-download only in the case that was going to fail anyway.
			# Without it a single-mirror host — the normal deployment — turns a
			# bad partial into content that can never be acquired.
			DotLog.debug(
				CHANNEL,
				"resumed content failed verification; restarting from zero",
				{"file": file.path, "resumed_from": resume_from}
			)
			store.discard_partial(file.sha256)

			var restarted := await http.download_to_file(
				url, store.partial_path(file.sha256), 0, headers
			)

			# A restart that cannot even download leaves the integrity error in
			# place: it is the more specific description of what went wrong.
			if restarted.ok:
				committed = await store.commit_partial(file.sha256, scheduler)

		if not committed.ok:
			last = committed
			# An integrity failure is the mirror's fault as much as a 500 is:
			# it served bytes that do not match what the manifest promised, and
			# another mirror may serve the right ones.
			note_failure()
			# [b]With the reason.[/b] "failed verification" alone cannot tell a mirror
			# serving the wrong bytes from a 404 body being hashed, and those are
			# opposite problems: one is a corrupt or stale host, the other is a URL
			# built wrong. The detail carries both hashes and the size.
			DotLog.warn(
				CHANNEL,
				"content from mirror failed verification",
				{
					"base": base,
					"file": file.path,
					"url": url,
					"expected_bytes": file.size,
					"why": str(committed.error),
				}
			)
			continue

		note_success()
		_preferred_base = base
		return committed

	return (last if last != null else DotResult.fail(
		DotError.CODE_NETWORK, "Every content mirror failed."
	)).wrap("Could not fetch '%s'." % file.path)


## Ordered list of base URLs to try.
##
## The manifest's own mirrors win over the source's configured ones: the server
## knows where its content actually is, and a client's baked-in default will be
## wrong the first time content moves.
## Downloads the manifest's bundle (one ZIP of small objects) and commits every entry that
## [param wanted] names, verifying the archive's hash and then each entry's own. One request
## instead of one per object. Returns `{objects, bytes}`; a failure leaves the per-file path
## to fetch whatever is still missing, so it is never fatal to the sync.
func fetch_bundle(
	manifest: DotCloudManifest,
	store: DotCloudStore,
	scheduler: DotScheduler,
	wanted: Dictionary
) -> DotResult:
	var decl := manifest.usable_bundle()
	if decl.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "The manifest declares no usable bundle.")
	var supported := is_supported()
	if not supported.ok:
		return supported
	var sha := str(decl["sha256"]).to_lower()
	var part := store.partial_path(sha)
	var last: DotResult = DotResult.fail(DotError.CODE_NETWORK, "Every content mirror failed.")

	for base in _resolve_bases(manifest):
		var url := "%s/%s" % [base.trim_suffix("/"), str(decl["url_path"]).trim_prefix("/")]
		store.discard_partial(sha)
		var res := await http.download_to_file(url, part, 0, headers)
		if not res.ok:
			last = res
			note_failure()
			continue
		var checked: DotResult = await scheduler.run(DotHashJob.new(part, sha)) \
			if scheduler != null else DotResult.success(true)
		if not checked.ok:
			last = checked
			note_failure()
			store.discard_partial(sha)
			continue
		_preferred_base = base
		var out := await _unpack_bundle(part, store, wanted)
		store.discard_partial(sha)
		if out.ok:
			note_success()
		return out
	return last.wrap("Could not fetch the content bundle.")


func _unpack_bundle(path: String, store: DotCloudStore, wanted: Dictionary) -> DotResult:
	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "opening the content bundle"))
	var objects := 0
	var bytes := 0
	var tree := Engine.get_main_loop() as SceneTree
	var slice_start := Time.get_ticks_msec()
	for entry in zip.get_files():
		if not wanted.has(entry) or store.has(entry):
			continue
		var body := zip.read_file(entry)
		var put := store.put_bytes(body, entry)
		if not put.ok:
			DotLog.warn(CHANNEL, "bundle entry failed verification", {"entry": entry.substr(0, 12)})
			continue
		objects += 1
		bytes += body.size()
		# Hashing thousands of entries in one frame freezes a browser tab.
		if tree != null and Time.get_ticks_msec() - slice_start > 8:
			await tree.process_frame
			slice_start = Time.get_ticks_msec()
	zip.close()
	DotWeb.sync_filesystem()
	return DotResult.success({"objects": objects, "bytes": bytes})


func _resolve_bases(manifest: DotCloudManifest) -> PackedStringArray:
	var out := PackedStringArray()

	if _preferred_base != "":
		out.append(_preferred_base)

	for u in manifest.mirrors:
		if not out.has(u):
			out.append(u)

	for u in base_urls:
		if not out.has(u):
			out.append(u)

	return out


func _build_url(base: String, file: DotCloudFile) -> String:
	var root := base.trim_suffix("/")

	if file.url_path != "":
		return "%s/%s" % [root, file.url_path.trim_prefix("/")]

	return "%s/%s/%s" % [
		root, objects_prefix.trim_suffix("/"), file.object_path()
	]


## Checks a base URL is reachable and whether it supports resuming.
##
## Worth calling once before a large sync: discovering that ranges are
## unsupported after 400 MB of a 500 MB file means starting over.
func probe_base(base: String) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "No DotHttp node.")
	return await http.probe(base.trim_suffix("/") + "/", headers)


func health() -> Dictionary:
	var d := super.health()
	d["preferred"] = _preferred_base
	d["mirrors"] = Array(base_urls)
	return d
