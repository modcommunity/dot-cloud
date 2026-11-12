@tool
class_name DotCloudConfig
extends DotConfig

## Everything configurable about content delivery.
## Layered like every [DotConfig]: exported defaults, JSON file, [code]DOT_CLOUD_*[/code] environment, [code]--cloud-*[/code] arguments.

@export_group("Cache")

## Root of the content cache; everything dot-cloud writes lives under here. On web it is inside IndexedDB.
@export var cache_dir: String = "user://dot_cloud"

## Cache ceiling in bytes; 0 is unlimited. Unreferenced objects are evicted LRU past it.
## Defaults to 4 GiB, far too much for a phone (see [member mobile_cache_bytes]).
@export var cache_bytes: int = 4 * 1024 * 1024 * 1024

## Cache ceiling on mobile, where filling the device's storage gets the app
## killed or uninstalled rather than merely inconvenienced.
@export var mobile_cache_bytes: int = 1024 * 1024 * 1024

## Fraction of the browser's reported quota used as the ceiling on web.
## Not all of it: the origin shares the quota, and hitting the real limit is an opaque write failure.
@export_range(0.1, 0.95, 0.05) var web_quota_fraction: float = 0.6

## Ask the browser to make storage persistent, so a low-disk browser is less
## likely to evict the whole cache.
@export var request_persistent_storage: bool = true

@export_group("Integrity")

## Refuse manifests that are not signed by a trusted key.
## [b]Leaving this on separates a content system from a remote code execution system[/b]: packs can contain
## scripts. Turn off only for LAN play, first-party servers or development; it warns every time.
@export var require_signed_manifests: bool = true

## Trusted signing keys, as [code]key_id -> PEM public key[/code]; several is normal while rotating (see [DotCloudSignature]).
## An entry can also say what it is trusted FOR, which matters with more than one publisher:
## [codeblock]
## {
##     "first-party": "-----BEGIN PUBLIC KEY-----\n…",
##     "community-alice": {
##         "key": "-----BEGIN PUBLIC KEY-----\n…",
##         "content_ids": ["alice/*"]
##     }
## }
## [/codeblock]
## A bare PEM means every content id. [method validate] warns about several keys with one unscoped.
@export var trusted_keys: Dictionary = {}

## Re-hash every cached object on startup. Off: minutes for a large cache, and objects are verified on write.
## Turn on to investigate corruption or on storage you do not trust.
@export var verify_cache_on_start: bool = false

## Re-hash an object before mounting it, against storage that changed underneath us
## (a partially evicted IndexedDB, a trimmed mobile sandbox).
@export var verify_before_mount: bool = true

@export_group("Transfer")

## Origins a game without a server fetches from; read by dot-game from the shared client content.json, declared so that file does not warn here.
@export var content_urls: PackedStringArray = PackedStringArray()

## Files fetched at once. A game pack is hundreds of small files, so a cold download is bound by round
## trips: the reference pack (~460 objects) acquired in 8.2 s at 6 and 6.6 s at 12 over 40 ms, 50 Mbit/s.
## Browsers queue past ~6 HTTP/1.1 connections; over HTTP/2 all 12 share one. Stay at or under
## [code]DotHttp.MAX_POOL[/code] (16), which bounds the request nodes.
@export_range(1, 32, 1) var parallel_downloads: int = 12

## Packs downloaded at once (API 19): a collection's dependencies run side by side, each pack with its own share of [member parallel_downloads]. 1 restores one pack at a time.
@export_range(1, 16, 1) var parallel_packs: int = 4

## Fetch a manifest's bundle (one archive of its small objects) when enough are missing.
@export var use_bundles: bool = true
@export var bundle_min_missing: int = 8

## Resume partial downloads with HTTP range requests.
## Needs host support (on web, [code]Accept-Ranges[/code] exposed through CORS); restarts when refused.
@export var resume_downloads: bool = true

## On web, where in-progress downloads are written: Emscripten's in-memory [code]/tmp[/code], not
## [code]user://[/code]. [code]user://[/code] there is an IndexedDB mirror saved by an asynchronous sync
## that lists the files first and reads them afterwards, so a partial renamed into the objects or
## deleted in between failed the whole save ("Failed to save IDB file system", 70 times over one
## Fatal Contact first start), and every save rewrote the growing partial into IndexedDB as well.
## The cost is that a reload restarts an unfinished file instead of resuming it. Empty: use
## [method persisted_partials_dir] on web too.
@export var web_partials_dir: String = "/tmp/dot_cloud_partial"

## Attempts per file before it is treated as failed, across all mirrors.
@export_range(1, 20, 1) var max_attempts_per_file: int = 4

## Bandwidth ceiling in bytes/sec; 0 is unlimited.
## For background downloads during play: saturating the connection is worse than a slower download.
@export var throttle_bytes_per_sec: int = 0

## Per-file timeout in seconds. Generous because it covers a whole file; a timeout that fires on a
## 200 MB pack over a slow link becomes an infinite retry loop.
@export_range(10.0, 3600.0, 10.0) var file_timeout_sec: float = 600.0

@export_group("Mirrors and prefetch")

## URL of the site's signed mirror list (`<game origin>/content/mirrors.json`); "" = none (API 13).
@export var mirrors_url: String = ""

## Fetch packs from published community mirrors. Off is the privacy opt-out: a mirror sees
## which addresses fetch which packs, so off means the origin only.
@export var use_mirrors: bool = true

## Most bytes one [method DotCloudClient.prefetch] downloads; a pack that would exceed what is left is skipped.
@export var prefetch_max_bytes: int = 256 * 1024 * 1024

## Most packs one prefetch document may name; the rest are skipped.
@export var prefetch_max_packs: int = 8

## Allow prefetch in a browser, where storage is a quota shared with the whole origin.
@export var prefetch_on_web: bool = false

@export_group("Mounting")

## Which side of a game this process fetches packs as: [code]auto[/code], [code]client[/code],
## [code]server[/code] or [code]both[/code] (API 8). Entries tagged for the other side ([member DotCloudFile.side])
## are never downloaded, cached, mounted or checked for.
## `auto` is server on a headless process, client elsewhere; a client shell run headless in tests sets
## `client` so it fetches what a player's does. `both` is a listen server or a republishing tool.
## [b]A web build is always client[/b] (see [method resolved_side]).
@export_enum("auto", "client", "server", "both") var side: String = "auto"

## Verify that no mounted path escapes the manifest's mount prefix.
## [DotPaths.safe_relative] already refuses traversal at parse time; a miss would overwrite the host's
## scripts, so it is checked twice.
@export var enforce_mount_prefix: bool = true

## Load packs with [code]replace_files = true[/code]. [b]Leave off[/b]: version-namespaced mount paths
## need no replacing, and it lets downloaded content shadow shipped files. See [DotCloudMounter].
@export var allow_replace_files: bool = false

@export_group("Progress")

## Seconds between [signal DotCloudClient.progress_changed] emissions; sampled because parallel
## downloads produce thousands of chunk callbacks a second.
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

	var unscoped := PackedStringArray()

	for key_id in trusted_keys:
		var entry: Variant = trusted_keys[key_id]

		if DotCloudSignature.key_pem(entry).strip_edges() == "":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"trusted_keys['%s'] has no public key." % str(key_id),
				"an entry is a PEM string, or { \"key\": PEM, \"content_ids\": [...] }"
			)

		if DotCloudSignature.key_scope(entry).is_empty():
			unscoped.append(str(key_id))

	# Nothing scoped is a coherent model (a self-hosted operator trusting their own key beside ours): info.
	# Some scoped and some not makes the restriction decorative: warn. Neither is fatal.
	if trusted_keys.size() > 1 and not unscoped.is_empty():
		if unscoped.size() == trusted_keys.size():
			DotLog.info(
				"cloud",
				"every trusted key may sign any content",
				{"keys": trusted_keys.size()}
			)
		else:
			DotLog.warn(
				"cloud",
				"a trusted key is unscoped while others are scoped, so the scopes "
				+ "restrict nothing",
				{
					"unscoped": unscoped,
					"keys": trusted_keys.size(),
					"hint": "give every entry content_ids, or none of them",
				}
			)

	if parallel_downloads < 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "parallel_downloads must be at least 1."
		)

	if prefetch_max_bytes < 0 or prefetch_max_packs < 0:
		return DotResult.fail(DotError.CODE_INVALID, "prefetch_max_bytes and prefetch_max_packs must not be negative.")

	# A typo here (`sever`) would otherwise read as "both" and fetch everything, which works
	# and quietly undoes the setting; or as a side that matches nothing.
	if not side in ["auto", "client", "server", "both"]:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"side must be auto, client, server or both.",
			"got '%s'" % side
		)

	return DotResult.success(null)


## [member side] as the value a manifest filters on: [constant DotCloudFile.SIDE_CLIENT],
## [constant DotCloudFile.SIDE_SERVER], or [constant DotCloudFile.SIDE_BOTH] for both.
func resolved_side() -> String:
	# Web builds are clients only (no listening sockets, no dedicated export), so a config
	# file shared with the desktop build cannot make a browser skip client content.
	if DotPlatform.is_web():
		return DotCloudFile.SIDE_CLIENT
	match side:
		"client":
			return DotCloudFile.SIDE_CLIENT
		"server":
			return DotCloudFile.SIDE_SERVER
		"both":
			return DotCloudFile.SIDE_BOTH
	return DotCloudFile.SIDE_SERVER if DotPlatform.is_headless() else DotCloudFile.SIDE_CLIENT


## The cache ceiling for the platform actually running, resolved so one config file is right everywhere:
## 4 GiB suits desktop, not a phone, and means nothing on web.
func effective_cache_bytes() -> int:
	if DotPlatform.is_mobile():
		return mobile_cache_bytes
	return cache_bytes


func objects_dir() -> String:
	return cache_dir.path_join("objects")


## Where in-progress downloads live, apart from [method objects_dir] so a partial is never mistaken
## for a complete object and [method DotCloudStore.has] can be an existence check.
## On web that is [member web_partials_dir], outside the IndexedDB mirror: see there.
func partials_dir() -> String:
	if DotPlatform.is_web() and not web_partials_dir.is_empty():
		return web_partials_dir
	return persisted_partials_dir()


## The partials directory under [member cache_dir], the one every platform but web uses. On web it
## only ever holds what an older build left, which [method DotCloudStore.open] removes.
func persisted_partials_dir() -> String:
	return cache_dir.path_join("partial")


## Whether partials live in the persisted cache, so changing them needs a filesystem sync.
func partials_persisted() -> bool:
	return partials_dir() == persisted_partials_dir()


func index_path() -> String:
	return cache_dir.path_join("index.json")


## Warns once about settings that are dangerous but legal; called by [DotCloudClient] at startup.
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
