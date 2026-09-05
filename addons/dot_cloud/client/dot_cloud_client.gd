@tool
class_name DotCloudClient
extends Node

## The one node a game needs: fetch a manifest, download, verify, mount.
##
## [codeblock]
## var cloud := DotCloudClient.new()
## add_child(cloud)
## cloud.config = my_config          # or leave null for defaults
##
## await cloud.start()
##
## cloud.phase_changed.connect(func(p, text): loading_label.text = text)
## cloud.progress_changed.connect(func(p): bar.value = p.fraction * 100.0)
##
## var res := await cloud.acquire("https://cdn.example.com/dm_arena/manifest.json")
## if res.ok:
##     get_tree().change_scene_to_file(res.value)   # the entry scene path
## [/codeblock]
##
## Place as many as you like — one per content channel, one per server. There is
## no singleton, so a client that is downloading the next map in the background
## while playing the current one is just two of these.

const CHANNEL := "cloud"

## Registry name the rest of the family looks this up under.
const SERVICE := &"dot_cloud_client"

## Where a content set is in its lifecycle. Drives loading-screen text.
enum Phase {
	IDLE,
	FETCHING_MANIFEST,
	VERIFYING_SIGNATURE,
	PLANNING,        ## Working out what is missing.
	DOWNLOADING,
	VERIFYING,
	MOUNTING,
	READY,
	FAILED,
}

## Phase changed. [param text] is a player-facing description.
signal phase_changed(phase: Phase, text: String)

## Forwarded from the downloader. See [method DotCloudDownloader.progress].
signal progress_changed(progress: Dictionary)

## Content is downloaded, verified and mounted.
signal content_ready(manifest: DotCloudManifest, mount_prefix: String)

## Content was released. The scene tree referencing it must already be gone.
signal content_released(content_key: String)

signal failed(error: DotError)

@export_group("Configuration")

## Content-delivery settings. A default [DotCloudConfig] is created if unset.
##
## [b]Note the default refuses unsigned manifests[/b] and therefore fails
## validation until [member DotCloudConfig.trusted_keys] has a key or
## [member DotCloudConfig.require_signed_manifests] is turned off. That is
## deliberate: a content system that mounts scripts should not be secure-by-
## accident.
@export var config: DotCloudConfig = null

## Path to a JSON config file layered over [member config]'s defaults.
@export var config_file: String = "user://dot_cloud.json"

@export_group("Sources")

## HTTP base URLs to try when a manifest lists no mirrors of its own.
@export var http_base_urls: PackedStringArray = PackedStringArray()

## Directories searched before the network. For development and bundled content.
@export var local_search_dirs: PackedStringArray = PackedStringArray()

## How a content id and version become a manifest URL, for [method ensure].
##
## [b]This exists because half the family addresses content by id and version rather
## than by URL.[/b] [method acquire] takes a manifest URL because dot-server has one to
## hand — an operator wrote it in a game's configuration. dot-map does not: a map is an
## id and a version in a catalogue, and a catalogue of a hundred maps should not repeat
## the same CDN hostname a hundred times. So [method ensure] builds the URL from this,
## against [member local_search_dirs] first and then [member http_base_urls], and a map
## that wants a URL of its own overrides it per-map.
##
## [code]{base}[/code], [code]{id}[/code] and [code]{version}[/code] are substituted.
## The default matches what [DotCloudPublisher] writes: a manifest at the root of an
## output directory, with the id and the version as the path above it, which is the
## same [code]id/version[/code] namespacing a mount uses.
@export var manifest_url_template: String = "{base}/{id}/{version}/manifest.json"

## Allow content to arrive over the game connection when no HTTP source works.
##
## Needs a delegate; dot-server supplies one. See [DotCloudSourceNetchan].
@export var allow_netchan_fallback: bool = true

@export_group("Service")

## Publish this client in [DotRegistry] so other addons can find it.
##
## [b]Three addons look for it there and none of them imports this one.[/b] dot-server's
## [code]DotClientLink[/code] asks for it to download a game's content;
## [code]DotGameManager[/code] asks for it to release the previous game's;
## [code]DotBuiltinCommands[/code]'s content command reports on it; and
## dot-user-avatar's [code]DotAvatarCatalogue[/code] asks for it to turn a cosmetic's
## content id into a path. All four are duck-typed, all four look under
## [constant SERVICE], and until this existed all four found nothing — so a client could
## never download content, a game change never released any, and a cosmetic delivered
## through the cloud was unreachable. Nothing errored: every one of those call sites
## treats an absent cloud as "this deployment ships its content in the build", which is a
## legitimate configuration and therefore indistinguishable from the bug.
@export var register_service: bool = true

## Suffix for this client's registry name.
##
## Two clients in one process — a test running both halves, a tool publishing while a
## client consumes — would otherwise both claim [constant SERVICE] and the second would
## displace the first.
@export var service_scope: StringName = &""

@export_group("Wiring")

## Where to find a [DotScheduler] for hashing work.
##
## Defaults to creating a child. Point it at the host project's existing
## scheduler to share one frame budget across every subsystem — otherwise two
## schedulers each spend their own budget and together drop the frame.
@export var scheduler_ref: DotNodeRef = null

var store: DotCloudStore = null
var mounter: DotCloudMounter = null
var downloader: DotCloudDownloader = null
var scheduler: DotScheduler = null

## Sources in preference order. Mutable at runtime — dot-server appends a netchan
## source once a session exists.
var sources: Array[DotCloudSource] = []

var _phase: Phase = Phase.IDLE
var _http: DotHttp = null
var _started: bool = false
var _registered_name: StringName = &""

## content_key -> DotCloudManifest, for everything currently mounted.
var _acquired: Dictionary = {}


# --- Lifecycle -------------------------------------------------------------

## Publishes the client so the addons that look for it can find it.
##
## In [method Node._ready] rather than in [method start], because [method start] awaits —
## the browser reports its storage quota asynchronously — and a consumer that resolved the
## service between the two would get null from a client that was about to work. Nothing
## found here has to be started: [method acquire] starts itself if it has not been.
func _ready() -> void:
	if Engine.is_editor_hint() or not register_service:
		return

	_registered_name = (
		DotRegistry.scoped_name(SERVICE, service_scope) if service_scope != &""
		else SERVICE
	)
	DotRegistry.register(_registered_name, self)


## Opens the cache and prepares the sources. Must be awaited before [method acquire].
##
## Separate from [method Node._ready] because it awaits: the browser reports its
## storage quota asynchronously, and a cache whose ceiling is not yet known would
## either refuse valid downloads or accept ones it cannot store.
func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if config == null:
		config = DotCloudConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return _fail(loaded.error)

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		return _fail(valid.error)

	config.warn_about_risky_settings()

	_resolve_scheduler()

	_http = DotHttp.new()
	_http.name = "ManifestHttp"
	_http.timeout_sec = 30.0
	# A manifest is small; a hostile host should not be able to stream gigabytes
	# into memory before we notice it is not JSON.
	_http.max_response_bytes = 8 * 1024 * 1024
	add_child(_http)

	store = DotCloudStore.new(config)
	var opened := await store.open()
	if not opened.ok:
		return _fail(opened.error)

	store.sweep_partials()

	if config.verify_cache_on_start:
		_set_phase(Phase.VERIFYING, "Checking downloaded content…")
		await store.verify_all(scheduler)

	mounter = DotCloudMounter.new(config)

	_build_sources()

	downloader = DotCloudDownloader.new()
	downloader.name = "Downloader"
	downloader.config = config
	downloader.store = store
	downloader.scheduler = scheduler
	downloader.sources = sources
	downloader.progress_changed.connect(_on_progress)
	add_child(downloader)

	_started = true
	_set_phase(Phase.IDLE, "")

	DotLog.info(CHANNEL, "client ready", store.describe())
	return DotResult.success(self)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""

	if store != null:
		store.close()


func _resolve_scheduler() -> void:
	if scheduler_ref == null:
		scheduler_ref = DotNodeRef.of_created(&"CloudScheduler", DotScheduler)

	var res := scheduler_ref.resolve(self)
	if res.ok and res.value is DotScheduler:
		scheduler = res.value as DotScheduler
		return

	# A missing scheduler is recoverable — make one rather than refusing to run,
	# because the most common cause is a ref pointing at a node the host renamed.
	DotLog.warn(
		CHANNEL,
		"could not resolve a scheduler; creating one",
		{"ref": scheduler_ref.describe()}
	)
	scheduler = DotScheduler.new()
	scheduler.name = "CloudScheduler"
	add_child(scheduler)


func _build_sources() -> void:
	sources.clear()

	if not local_search_dirs.is_empty():
		var local := DotCloudSourceLocal.new()
		local.search_dirs = local_search_dirs
		# First: a file already on disk costs nothing to check and beats any
		# network round trip.
		local.priority = 10
		sources.append(local)

	var http_source := DotCloudSourceHttp.new()
	http_source.base_urls = http_base_urls
	http_source.priority = 50
	http_source.http = _http
	sources.append(http_source)

	if allow_netchan_fallback:
		var netchan := DotCloudSourceNetchan.new()
		# Last: it costs the game server's own bandwidth, so it is what you fall
		# back to, never what you reach for.
		netchan.priority = 900
		sources.append(netchan)


## Gives the netchan source its transport delegate.
##
## Called by dot-server once a session is established. Until then the netchan
## source reports itself unsupported and is skipped.
func set_netchan_delegate(delegate: Object) -> void:
	for s in sources:
		var nc := s as DotCloudSourceNetchan
		if nc != null:
			nc.delegate = delegate
			DotLog.debug(
				CHANNEL,
				"netchan delegate set",
				{"delegate": delegate.get_class() if delegate != null else "<none>"}
			)


# --- Acquiring content -----------------------------------------------------

## The whole flow for one content set: fetch, verify, download, mount.
##
## Returns the entry scene path when the manifest declares one, otherwise the
## mount prefix. Idempotent — calling it for content already mounted returns
## immediately.
func acquire(
	manifest_url: String,
	groups: PackedStringArray = PackedStringArray()
) -> DotResult:
	if not _started:
		var started := await start()
		if not started.ok:
			return started

	_set_phase(Phase.FETCHING_MANIFEST, "Getting content information…")

	var fetched := await fetch_manifest(manifest_url)
	if not fetched.ok:
		return _fail(fetched.error)

	var manifest: DotCloudManifest = fetched.value
	return await acquire_manifest(manifest, groups)


## [method acquire] for a manifest already in hand.
##
## dot-server pushes manifests down the game connection rather than making every
## client fetch the same document over HTTP, so this is the path it uses.
func acquire_manifest(
	manifest: DotCloudManifest,
	groups: PackedStringArray = PackedStringArray()
) -> DotResult:
	if not _started:
		var started := await start()
		if not started.ok:
			return started

	var key := manifest.key()

	if mounter.is_mounted(key):
		_set_phase(Phase.READY, "Ready.")
		return _ready_result(manifest)

	_set_phase(Phase.PLANNING, "Checking what needs downloading…")

	var plan := plan_for(manifest, groups)

	DotLog.info(
		CHANNEL,
		"acquiring content",
		{
			"content": key,
			"need": plan["missing_files"],
			"bytes": DotPaths.format_bytes(int(plan["missing_bytes"])),
		}
	)

	if int(plan["missing_files"]) > 0:
		_set_phase(
			Phase.DOWNLOADING,
			"Downloading %s…" % DotPaths.format_bytes(int(plan["missing_bytes"]))
		)

		scheduler.set_boost(600.0)
		var synced := await downloader.sync(manifest, groups)
		scheduler.clear_boost()

		if not synced.ok:
			return _fail(synced.error)

	_set_phase(Phase.MOUNTING, "Preparing content…")

	var mounted := await mounter.mount(manifest, store, scheduler)
	if not mounted.ok:
		return _fail(mounted.error)

	_acquired[key] = manifest

	_set_phase(Phase.READY, "Ready.")
	content_ready.emit(manifest, str(mounted.value))

	return _ready_result(manifest)


## [method acquire] for content addressed by id and version rather than by URL.
##
## [b]This is the interface the rest of the family duck-types against, and until now it
## did not exist.[/b] [DotMapLoader] has called [code]ensure(content_id, version)[/code]
## and [code]is_mounted(content_id, version)[/code] on whatever it found under
## [constant SERVICE] since it was written; this client offered [method acquire] and
## [method is_ready], which take a URL and a [code]id@version[/code] key. The two ends
## had never met, so every *delivered* map failed with "the registered cloud client does
## not speak the content interface" — and no suite could see it, because dot-map's only
## loader test runs with no cloud client at all, which is the branch that falls back to
## the disk and passes.
##
## Idempotent: content already mounted returns immediately without touching the network.
##
## [param manifest_url] overrides [member manifest_url_template] for callers that have a
## URL of their own. Empty resolves one against [member local_search_dirs] and then
## [member http_base_urls], in that order — the disk before the network, so a development
## tree and an offline install work without a server.
func ensure(
	content_id: StringName,
	version: String = "",
	groups: PackedStringArray = PackedStringArray(),
	manifest_url: String = ""
) -> DotResult:
	var id := String(content_id)

	if id == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "No content id to ensure."
		)

	var effective_version := version if version != "" else "0.0.0"

	if is_mounted(content_id, effective_version):
		var manifest: DotCloudManifest = _acquired.get(
			content_key_for(content_id, effective_version)
		)
		if manifest != null:
			_set_phase(Phase.READY, "Ready.")
			return _ready_result(manifest)
		# Mounted by an earlier run of this process, from a client that has since
		# gone. The paths are there and resolvable, which is all a caller needs.
		return DotResult.success(mount_prefix_for(content_id, effective_version))

	var candidates := (
		PackedStringArray([manifest_url]) if manifest_url != ""
		else manifest_urls_for(content_id, effective_version)
	)

	if candidates.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE,
			"There is nowhere to fetch %s from." % id,
			"set local_search_dirs or http_base_urls on this DotCloudClient, or give "
			+ "the content a manifest_url of its own"
		)

	var last: DotResult = null

	for candidate in candidates:
		var fetched := await fetch_manifest(candidate)

		if not fetched.ok:
			# Tried in order and the first hit wins, so a base that does not have this
			# content is not a failure until every base has been asked. Only the last
			# error is kept — reporting five 404s helps nobody.
			last = fetched
			continue

		var manifest: DotCloudManifest = fetched.value

		# The manifest decides what it is, and it has to agree with what was asked
		# for. Without this a mirror serving the wrong document mounts content under
		# the id the caller wanted and the paths inside it are somebody else's.
		if manifest.content_id != id:
			last = DotResult.fail(
				DotError.CODE_INVALID,
				"The manifest at %s is for different content." % candidate,
				"asked for '%s', it says '%s'" % [id, manifest.content_id]
			)
			continue

		if version != "" and manifest.version != effective_version:
			last = DotResult.fail(
				DotError.CODE_INVALID,
				"The manifest at %s is the wrong version." % candidate,
				"asked for '%s', it says '%s'" % [effective_version, manifest.version]
			)
			continue

		# [b]A published directory holds a manifest AND the objects it names.[/b]
		# [DotCloudPublisher] writes `manifest.json` beside `objects/`, so a base that
		# answered for the manifest is by construction where the content is — and
		# without this the id-and-version form found a manifest it could not then
		# fetch a single file for, failing with "Content is not in any local source
		# directory" while the bytes sat next to the document that named them.
		#
		# The URL form does not need it: a caller with a URL has configured the
		# sources to match it. This one built the URL itself, so it knows.
		if is_local_manifest_url(candidate):
			_adopt_local_dir(_local_manifest_path(candidate).get_base_dir())

		return await acquire_manifest(manifest, groups)

	return (
		last if last != null
		else DotResult.fail(
			DotError.CODE_IO, "Could not get %s's manifest." % id
		)
	)


## Adds a directory to the local source, creating one if there was none.
##
## Idempotent, and it also updates [member local_search_dirs] so [method describe] and a
## later rebuild both agree with what is actually being searched.
func _adopt_local_dir(dir: String) -> void:
	if dir == "" or local_search_dirs.has(dir):
		return

	local_search_dirs.append(dir)

	for source in sources:
		if source is DotCloudSourceLocal:
			var local: DotCloudSourceLocal = source
			if not local.search_dirs.has(dir):
				local.search_dirs.append(dir)
			return

	# There was no local source, because there were no directories when the sources
	# were built. One now, at the same priority _build_sources gives it.
	var created := DotCloudSourceLocal.new()
	created.search_dirs = PackedStringArray([dir])
	created.priority = 10
	sources.append(created)


## Whether content addressed by id and version is mounted and ready to load from.
##
## The id-and-version half of [method is_ready], for the same reason [method ensure]
## exists.
func is_mounted(content_id: StringName, version: String = "") -> bool:
	return is_ready(content_key_for(content_id, version))


## The [code]id@version[/code] key this content is known by.
##
## Duplicated from [method DotCloudManifest.key] deliberately: a caller asking whether
## content is mounted does not have the manifest — getting it is the expensive thing it
## is trying to avoid.
static func content_key_for(content_id: StringName, version: String = "") -> String:
	return "%s@%s" % [String(content_id), version if version != "" else "0.0.0"]


## Where this content mounts, whether or not it is mounted yet.
static func mount_prefix_for(content_id: StringName, version: String = "") -> String:
	return "res://dot_cloud/%s/%s" % [
		String(content_id), version if version != "" else "0.0.0"
	]


## Manifest URLs to try for this content, best first.
##
## Local directories before HTTP bases: the disk is faster, works offline, and is what a
## development tree and a bundled install both look like.
func manifest_urls_for(
	content_id: StringName, version: String = ""
) -> PackedStringArray:
	var out := PackedStringArray()

	for base in local_search_dirs:
		out.append(_expand_manifest_url(base, content_id, version))

	for base in http_base_urls:
		out.append(_expand_manifest_url(base, content_id, version))

	return out


func _expand_manifest_url(
	base: String, content_id: StringName, version: String
) -> String:
	return manifest_url_template \
		.replace("{base}", base.trim_suffix("/")) \
		.replace("{id}", String(content_id)) \
		.replace("{version}", version if version != "" else "0.0.0")


## Whether a manifest URL names a file on this machine rather than a server.
##
## [b]A scheme-less string is not automatically a path, and getting that wrong breaks
## the browser.[/b] The obvious rule — "no [code]://[/code] means local" — is wrong for
## exactly the deployment the web target wants: a page served from the same origin as
## its content uses a root-relative URL like [code]/content/x/1.0.0/manifest.json[/code],
## because same-origin is what avoids CORS entirely, and [DotHttp] resolves it against
## [member DotHttp.base_url] like any other request. Treating it as a file would make
## the one CORS-free configuration the only one that cannot fetch a manifest.
##
## So: the three file schemes are local outright, anything with another scheme is not,
## and a bare path is local only if it is actually there. That last check is why this is
## not a pure function, and it is worth it — the alternative is guessing.
static func is_local_manifest_url(manifest_url: String) -> bool:
	if manifest_url.begins_with("res://") or manifest_url.begins_with("user://"):
		return true
	if manifest_url.begins_with("file://"):
		return true
	if manifest_url.contains("://"):
		return false
	return FileAccess.file_exists(manifest_url)


static func _local_manifest_path(manifest_url: String) -> String:
	return (
		manifest_url.trim_prefix("file://") if manifest_url.begins_with("file://")
		else manifest_url
	)


## Downloads and verifies a manifest without acting on it.
##
## Signature verification runs over the bytes as received, never a
## re-serialisation — see [DotCloudSignature].
##
## [b]A local path is read rather than requested.[/b] [DotCloudSourceLocal] already
## serves a published tree off the disk — that is what [member local_search_dirs] is —
## but the manifest at the top of that tree was still going through [DotHttp], and
## [HTTPRequest] cannot fetch a [code]res://[/code] or [code]user://[/code] path. So a
## deployment whose content is on disk beside the executable, and every test that
## publishes into a temporary directory, could reach every object in a pack and not the
## one document naming them.
func fetch_manifest(manifest_url: String) -> DotResult:
	var bytes: PackedByteArray

	if is_local_manifest_url(manifest_url):
		var read := DotPaths.read_bytes(_local_manifest_path(manifest_url))
		if not read.ok:
			return read.wrap("Could not read the content manifest.")
		bytes = read.value
	else:
		var res := await _http.get_bytes(manifest_url)
		if not res.ok:
			return res.wrap("Could not download the content manifest.")
		bytes = res.value

	var parsed := DotCloudManifest.from_json_bytes(bytes)
	if not parsed.ok:
		return parsed

	var manifest: DotCloudManifest = parsed.value

	var checked := verify_manifest(manifest)
	if not checked.ok:
		return checked

	return DotResult.success(manifest)


## Checks a manifest's signature against the configured trusted keys.
func verify_manifest(manifest: DotCloudManifest) -> DotResult:
	if not config.require_signed_manifests:
		if manifest.signature != "":
			# Verify anyway when a signature is present: it costs nothing and a
			# manifest that claims to be signed but is not should be refused
			# whatever the policy says.
			var opportunistic := DotCloudSignature.verify_any(
				manifest.raw_bytes,
				manifest.signature,
				config.trusted_keys,
				manifest.signature_key_id
			)
			if not opportunistic.ok and not config.trusted_keys.is_empty():
				return opportunistic
		return DotResult.success(true)

	_set_phase(Phase.VERIFYING_SIGNATURE, "Checking content signature…")

	if manifest.raw_bytes.is_empty():
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"This manifest cannot be verified.",
			"it was constructed in memory rather than received, so there are no "
			+ "signed bytes to check"
		)

	return DotCloudSignature.verify_any(
		manifest.raw_bytes,
		manifest.signature,
		config.trusted_keys,
		manifest.signature_key_id
	)


## What acquiring this manifest would cost, without doing it.
##
## For a "this map needs 240 MB, continue?" prompt — worth showing on mobile and
## on metered connections, and cheap because it is only cache lookups.
func plan_for(
	manifest: DotCloudManifest,
	groups: PackedStringArray = PackedStringArray()
) -> Dictionary:
	var wanted := manifest.wanted_files(groups)

	var seen := {}
	var missing_files := 0
	var missing_bytes := 0
	var cached_files := 0

	for f in wanted:
		if seen.has(f.sha256):
			continue
		seen[f.sha256] = true

		if store.has(f.sha256):
			cached_files += 1
		else:
			missing_files += 1
			missing_bytes += f.size

	return {
		"content": manifest.key(),
		"total_files": wanted.size(),
		"unique_files": seen.size(),
		"cached_files": cached_files,
		"missing_files": missing_files,
		"missing_bytes": missing_bytes,
		"missing_human": DotPaths.format_bytes(missing_bytes),
		"cache_shortfall": store.shortfall(missing_bytes),
		"already_mounted": mounter.is_mounted(manifest.key()),
	}


## Releases content.
##
## [b]Free everything referencing it first.[/b] Nodes holding resources from the
## pack keep them in the resource cache, and Godot cannot unmount a pack — see
## [DotCloudMounter]. This makes the content unreachable and its cache objects
## evictable; it does not and cannot reclaim the file table.
func release(content_key: String) -> DotResult:
	if not mounter.is_mounted(content_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "Not mounted.", content_key
		)

	var res := mounter.unmount(content_key, store)
	_acquired.erase(content_key)

	if res.ok:
		content_released.emit(content_key)

	return res


func cancel() -> void:
	if downloader != null and downloader.is_running():
		downloader.cancel()


# --- State ----------------------------------------------------------------

func phase() -> Phase:
	return _phase


func is_ready(content_key: String) -> bool:
	return mounter != null and mounter.is_mounted(content_key)


func acquired_keys() -> PackedStringArray:
	var out := PackedStringArray(_acquired.keys())
	out.sort()
	return out


func manifest_for(content_key: String) -> DotCloudManifest:
	return _acquired.get(content_key)


func _ready_result(manifest: DotCloudManifest) -> DotResult:
	var entry := manifest.entry_scene_path()
	if entry != "":
		return DotResult.success(entry)
	return DotResult.success(manifest.mount_prefix())


func _set_phase(p: Phase, text: String) -> void:
	if _phase == p:
		return
	_phase = p
	phase_changed.emit(p, text)


func _fail(error: DotError) -> DotResult:
	_set_phase(Phase.FAILED, error.message)
	DotLog.error(
		CHANNEL,
		error.message,
		{"code": error.code, "detail": error.detail}
	)
	failed.emit(error)
	return DotResult.failure(error)


func _on_progress(p: Dictionary) -> void:
	progress_changed.emit(p)


static func phase_name(p: Phase) -> String:
	return Phase.keys()[p]


func describe() -> Dictionary:
	return {
		"phase": phase_name(_phase),
		"started": _started,
		"acquired": Array(acquired_keys()),
		"store": store.describe() if store != null else {},
		"mounts": mounter.describe() if mounter != null else {},
		"downloader": downloader.describe() if downloader != null else {},
	}


## Lines for a `cloud_status` console command.
func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("phase            %s" % phase_name(_phase))

	if store != null:
		out.append_array(store.describe_lines())

	if mounter != null:
		out.append("mounts:")
		for l in mounter.describe_lines():
			out.append("  " + l)

	out.append("sources:")
	for s in sources:
		var h := s.health()
		out.append("  %-10s %s" % [
			str(h["source"]),
			"ok" if bool(h["available"]) else "unavailable",
		])

	return out
