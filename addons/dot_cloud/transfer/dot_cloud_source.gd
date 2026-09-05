@tool
class_name DotCloudSource
extends Resource

## Base class for somewhere content can be fetched from.
##
## Three exist, and a deployment usually wants more than one:
##
## - [DotCloudSourceHttp] — a web server or CDN. The normal case, and the only
##   one that scales, because the game server never touches the bytes.
## - [DotCloudSourceLocal] — a directory already on disk. For development, for
##   LAN play from a shared folder, and for content shipped with the build.
## - [DotCloudSourceNetchan] — the bytes come down the multiplayer connection
##   itself. The fallback for a server with no web host, equivalent to Source's
##   pre-FastDL behaviour: it works everywhere, including in a browser, and it
##   costs the server's own bandwidth.
##
## Sources are tried in order, so listing a CDN then a netchan gives you "fast
## when the CDN is up, still playable when it is not".

const CHANNEL := "cloud.src"

## Priority when several sources are available. Lower is tried first.
@export var priority: int = 100

## Whether this source is currently usable. See [method health].
var _failures: int = 0
var _last_failure_ms: int = 0

## Consecutive failures before the source is skipped.
@export var failure_threshold: int = 3

## Seconds a failed source is skipped for before being retried.
##
## Failing over permanently would be wrong: a CDN with a five-minute outage
## should not be abandoned for the rest of the session.
@export var cooldown_sec: float = 60.0


# --- Subclass interface ----------------------------------------------------

## Human-readable name for logs and progress UI.
func source_name() -> String:
	return "source"


## Whether this source can be used on this platform at all.
##
## Answered without a manifest, so it can only speak to the platform and to
## whatever the source was handed at build time. "Can this source serve [i]this[/i]
## content?" is [method can_serve].
func is_supported() -> DotResult:
	return DotResult.success(true)


## Whether this source could serve this particular manifest's content at all.
##
## Distinct from [method is_supported] and from [method is_available], and the
## distinction earns its keep: a source that is perfectly healthy can still have
## no way to reach a given content set — an [DotCloudSourceHttp] with no
## [member DotCloudSourceHttp.base_urls] and a manifest carrying no mirrors is
## the case that motivated this.
##
## Such a source used to be tried anyway, and cost real things. It sat at
## priority 50, ahead of the in-band fallback, and burned one of
## [member DotCloudConfig.max_attempts_per_file] on every file to produce the
## same error every time. Worse, it never called [method note_failure] for it —
## correctly, since nothing failed — so it never entered cooldown and never
## stopped being "available". When the source that [i]could[/i] serve the content
## tripped its own breaker, this one was the only candidate left, and the caller
## was told "No content URL is configured." about a download that had been
## failing for an entirely different reason.
##
## Returning a failure here means "skip me for this manifest, and say why";
## it is not recorded as a failure against the circuit breaker.
func can_serve(_manifest: DotCloudManifest) -> DotResult:
	return DotResult.success(true)


## Fetches one file into the store's partial slot, then commits it.
##
## Implementations must:
## 1. write to [method DotCloudStore.partial_path] for the file's hash,
## 2. resume from [method DotCloudStore.partial_size] when they can,
## 3. call [method DotCloudStore.commit_partial], which verifies the hash.
##
## Never write into the object directory directly — commit is the only place
## verification happens, and bypassing it is how unverified content gets mounted.
func fetch(
	_file: DotCloudFile,
	_manifest: DotCloudManifest,
	_store: DotCloudStore,
	_scheduler: DotScheduler
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"%s does not implement fetch()." % source_name()
	)


# --- Health ----------------------------------------------------------------

## Whether this source should be tried right now.
func is_available() -> bool:
	if not is_supported().ok:
		return false

	if _failures < failure_threshold:
		return true

	var elapsed := float(Time.get_ticks_msec() - _last_failure_ms) / 1000.0
	if elapsed >= cooldown_sec:
		# Half-open: allow one attempt through, and one more failure puts it back
		# in cooldown. Resetting the counter to zero would let a dead source
		# absorb `failure_threshold` requests every cooldown period.
		_failures = failure_threshold - 1
		return true

	return false


func note_success() -> void:
	if _failures > 0:
		DotLog.debug(CHANNEL, "source recovered", {"source": source_name()})
	_failures = 0


func note_failure() -> void:
	_failures += 1
	_last_failure_ms = Time.get_ticks_msec()

	if _failures == failure_threshold:
		DotLog.warn(
			CHANNEL,
			"source is failing; backing off",
			{"source": source_name(), "cooldown": cooldown_sec}
		)


## Seconds until a source in cooldown is tried again. Zero when it is not.
func cooldown_remaining_sec() -> float:
	if _failures < failure_threshold:
		return 0.0
	var elapsed := float(Time.get_ticks_msec() - _last_failure_ms) / 1000.0
	return maxf(0.0, cooldown_sec - elapsed)


## Why this source is being skipped right now, or "" when it is not.
##
## Lives here rather than in [DotCloudDownloader] so there is one place that
## knows what the breaker's state means. A caller reading a failed download
## otherwise has to guess between "misconfigured" and "backing off", which are
## opposite things to do about.
func unavailable_reason() -> String:
	var supported := is_supported()
	if not supported.ok:
		return "unsupported: %s" % supported.error.message

	var remaining := cooldown_remaining_sec()
	if remaining > 0.0:
		return "in cooldown for another %.0f s after %d failures" % [
			remaining, _failures
		]

	return ""


func health() -> Dictionary:
	return {
		"source": source_name(),
		"available": is_available(),
		"failures": _failures,
		"cooldown_remaining": cooldown_remaining_sec(),
	}
