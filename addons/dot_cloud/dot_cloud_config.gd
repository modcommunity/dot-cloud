@tool
class_name DotCloudConfig
extends DotConfig

## Everything configurable about content delivery.
##
## Layered like every [DotConfig]: exported defaults, then a JSON file, then
## [code]DOT_CLOUD_*[/code] environment variables, then
## [code]--cloud-*[/code] arguments.

@export_group("Cache")

## Root of the content cache. Everything dot-cloud writes lives under here.
##
## On web this is inside IndexedDB rather than a directory; the path still works,
## it just is not somewhere a player can look.
@export var cache_dir: String = "user://dot_cloud"

## Cache ceiling in bytes. 0 means unlimited.
##
## Unreferenced objects are evicted least-recently-used first once the cache
## exceeds this. Defaults to 4 GiB, which is generous for desktop and far too
## much for a phone — see [member mobile_cache_bytes].
@export var cache_bytes: int = 4 * 1024 * 1024 * 1024

## Cache ceiling on mobile, where filling the device's storage gets the app
## killed or uninstalled rather than merely inconvenienced.
@export var mobile_cache_bytes: int = 1024 * 1024 * 1024

## Fraction of the browser's reported quota to use as the ceiling on web.
##
## Not the whole quota: the origin shares it with everything else the site
## stores, and hitting the real limit surfaces as an opaque write failure rather
## than as a manageable "cache full".
@export_range(0.1, 0.95, 0.05) var web_quota_fraction: float = 0.6

## Ask the browser to make storage persistent, so a low-disk browser is less
## likely to evict the whole cache.
@export var request_persistent_storage: bool = true

@export_group("Integrity")

## Refuse manifests that are not signed by a trusted key.
##
## [b]Leaving this on is the difference between a content system and a remote
## code execution system.[/b] Godot packs can contain scripts, so a client that
## mounts content from an unsigned manifest runs whatever the server sent. Turn
## it off only for LAN play, first-party servers, or development — and expect the
## warning it logs every time.
@export var require_signed_manifests: bool = true

## Trusted signing keys, as [code]key_id -> PEM public key[/code].
##
## Several entries is normal: rotating a key needs a window where both are
## accepted. See [DotCloudSignature].
@export var trusted_keys: Dictionary = {}

## Re-hash every cached object on startup.
##
## Off by default — it is minutes of work for a large cache, and objects are
## verified when they are written. Worth turning on when investigating
## corruption, or on a platform whose storage you do not trust.
@export var verify_cache_on_start: bool = false

## Re-hash an object before mounting it, even though it was verified on download.
##
## Cheap insurance against storage that changed underneath us — which on web
## means an IndexedDB the browser partially evicted, and on mobile a sandbox the
## OS trimmed.
@export var verify_before_mount: bool = true

@export_group("Transfer")

## Files fetched at once.
##
## Above about 8 the bottleneck stops being latency and starts being bandwidth,
## and more slots only add overhead. Browsers cap concurrent connections per host
## around 6, so higher values there are silently queued.
@export_range(1, 32, 1) var parallel_downloads: int = 6

## Resume partial downloads with HTTP range requests.
##
## Requires the content host to support ranges — and on web, to expose
## [code]Accept-Ranges[/code] through CORS. Falls back to restarting the transfer
## when a range request is refused.
@export var resume_downloads: bool = true

## Attempts per file before it is treated as failed, across all mirrors.
@export_range(1, 20, 1) var max_attempts_per_file: int = 4

## Bandwidth ceiling in bytes/sec. 0 is unlimited.
##
## Worth setting on a client downloading in the background while a game is being
## played: saturating the connection makes the game unplayable, which is a worse
## outcome than the download taking longer.
@export var throttle_bytes_per_sec: int = 0

## Per-file timeout in seconds.
##
## Generous, because this covers a whole file: a 200 MB pack on a slow
## connection is legitimately several minutes, and a timeout that fires on it
## turns a working download into an infinite retry loop.
@export_range(10.0, 3600.0, 10.0) var file_timeout_sec: float = 600.0

@export_group("Mounting")

## Verify that no mounted path escapes the manifest's mount prefix.
##
## Belt and braces — [DotPaths.safe_relative] already refuses traversal at parse
## time — but the consequence of a miss is content overwriting the host project's
## own scripts, so it is checked twice.
@export var enforce_mount_prefix: bool = true

## Load packs with [code]replace_files = true[/code].
##
## [b]Leave this off.[/b] Version-namespaced mount paths mean nothing ever needs
## replacing, and turning it on lets downloaded content shadow files the host
## project shipped. See [DotCloudMounter].
@export var allow_replace_files: bool = false

@export_group("Progress")

## Seconds between [signal DotCloudClient.progress_changed] emissions.
##
## Progress is sampled rather than emitted per chunk: a 6-way parallel download
## produces thousands of chunk callbacks a second and UI cannot use them.
@export_range(0.05, 5.0, 0.05) var progress_interval_sec: float = 0.2


func env_prefix() -> String:
	return "DOT_CLOUD_"


func cli_prefix() -> String:
	return "--cloud-"


func sensitive_keys() -> PackedStringArray:
	# Public keys are not secret, but a trusted-key set injected through the
	# environment would let anything that can set a variable in the game's
	# process become a content publisher.
	return PackedStringArray(["trusted_keys"])


func validate() -> DotResult:
	if cache_dir.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "cache_dir must not be empty."
		)

	if require_signed_manifests and trusted_keys.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"require_signed_manifests is on but no trusted_keys are configured.",
			"add a key, or set require_signed_manifests = false and accept that "
			+ "any server can mount arbitrary content in this client"
		)

	if parallel_downloads < 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "parallel_downloads must be at least 1."
		)

	return DotResult.success(null)


## The cache ceiling for the platform actually running.
##
## Resolved rather than configured directly so one config file is correct on
## every target: a 4 GiB ceiling is fine on desktop, hostile on a phone, and
## meaningless on web where the browser decides.
func effective_cache_bytes() -> int:
	if DotPlatform.is_mobile():
		return mobile_cache_bytes
	return cache_bytes


func objects_dir() -> String:
	return cache_dir.path_join("objects")


## Where in-progress downloads live.
##
## Separate from [method objects_dir] so a partial file can never be mistaken for
## a complete one — the object directory holds only verified content, which is
## what lets [method DotCloudStore.has] be a cheap existence check instead of a
## hash.
func partials_dir() -> String:
	return cache_dir.path_join("partial")


func index_path() -> String:
	return cache_dir.path_join("index.json")


## Warns once about settings that are dangerous but legal.
##
## Called by [DotCloudClient] at startup. A silent insecure default is how a
## development shortcut ships.
func warn_about_risky_settings() -> void:
	if not require_signed_manifests:
		DotLog.warn(
			"cloud",
			"manifest signature checking is OFF — any server this client "
			+ "connects to can mount arbitrary content, including scripts",
			{"setting": "require_signed_manifests"}
		)

	if allow_replace_files:
		DotLog.warn(
			"cloud",
			"allow_replace_files is ON — downloaded content can shadow files "
			+ "shipped with this project",
			{"setting": "allow_replace_files"}
		)
