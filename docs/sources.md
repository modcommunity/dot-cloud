# Sources and the downloader

Sources are tried in priority order, with per-source circuit breaking (`failure_threshold`, `cooldown_sec`, half-open retry).

| Source | Priority | Use |
| --- | --- | --- |
| `DotCloudSourceLocal` | 10 | Development, LAN shares, content bundled in the build. Verifies hashes like everything else. |
| `DotCloudSourceHttp` | 50 | The normal case. Content-addressed URLs, mirror failover with a sticky preference, range resume. |
| `DotCloudSourceNetchan` | 900 | Bytes over the game connection. Needs no web host, no CORS, no certificate; costs the server's bandwidth. The fallback when there is no download host. |

## Three reasons to skip a source

`is_supported()` answers "on this platform, at all"; `is_available()` answers "not in circuit-breaker cooldown"; `can_serve(manifest)` answers "with a way to reach this content". The third exists because `DotCloudClient` always builds an HTTP source whether or not it was given base URLs (a manifest may carry its own mirrors), so in a netchan-only or local-only deployment that source is healthy, permanently available, and unable to fetch a byte. Without `can_serve` it sat ahead of the in-band fallback, spent one of `max_attempts_per_file` per file on a guaranteed failure, and once netchan tripped its breaker every download failed with "No content URL is configured." `netchan_demo`'s last section is the assertion.

## The in-band source

**`DotCloudSourceNetchan` does not know how to send a packet.** dot-cloud must not depend on dot-server, so it calls a duck-typed delegate:

```gdscript
func cloud_chunk_size() -> int
func cloud_request_chunk(sha256: String, offset: int, length: int) -> DotResult
```

The delegate owns rate limiting and **must refuse hashes the client has no business requesting**, or it is a way to read the server's cache.

**It needs all three of its bounds.** `max_chunks_per_file` caps round trips, `chunk_timeout_sec` caps one wait, and `file_timeout_sec` caps their product. Without the third, a peer that answers every chunk correctly but slowly is bounded only by 16384 x 30 s, over 130 hours holding the game connection, with no failure for the breaker to count. The per-chunk wait is clamped to what is left of the file budget, and when that expires the failure says "The in-band transfer took too long." Both timeouts keep the partial: a stalled transfer is a reason to come back, not to discard what arrived.

## Resume

`DotCloudSourceHttp` resumes an interrupted transfer by asking for `bytes=N-`, where N is what is already in `<cache>/partial/<hash>.part`. Those N bytes have been verified by **nothing**: `commit_partial` checks only the whole object. A partial can be wrong for reasons unconnected to the mirror serving now: a process killed mid-write, a bad sector, a caching proxy answering a range with the wrong window, an HTTP layer whose resume does not append.

So a post-resume hash failure is usually **not** the mirror's fault, and treating it as one is worse than useless: `commit_partial` has already discarded the partial, so the retry that would succeed is exactly the one the mirror loop skips, and on a single-mirror host (the normal deployment) the content could never be acquired. The source restarts that one transfer from zero against the same mirror before writing it off. `http_demo`'s "poisoned partial" section plants garbage as the partial and requires the acquire to succeed.

dot-core's `DotHttp.download_to_file` writes a ranged response to a sibling file and joins it on, because `HTTPRequest` has no append mode and truncates its target. `http_demo` prints the bytes transferred against the content size each run.

## The downloader

`DotCloudDownloader.sync()` runs a worker pool with failover, a throttle and progress. Its fan-out is the GDScript trap described in [testing.md](testing.md#the-fan-out-trap): every return path in `_worker` must increment `_workers_finished` and emit `_worker_done`.

## The bundle: one request for the small files

An imported level is hundreds of `.ctex`, `.import` and `.res` objects of a few KiB each, and one request per object costs a round trip each plus a content-addressed file on disk. `DotCloudPublisher.write_bundle` (on by default) also writes `bundles/<sha256>.zip`, a ZIP of every unique object up to `bundle_max_object_bytes` (1 MiB), each entry named by its own hash, and names it in the manifest's signed `bundle` block (API level 9). When at least `bundle_min_missing` (8) of the files a client lacks are in it and they are at least half the archive, `DotCloudDownloader` asks the HTTP source for the archive first (`fetch_bundle`), verifies the archive hash, then puts each wanted entry through `put_bytes()`, which verifies it again. Objects over the cap stay individual and download in parallel. A corrupt or missing bundle logs a warning and the per-file path takes over, so the bundle can only make a sync faster. A refresh that lacks three files fetches three files.

What a refresh costs: the objects, the index and the built `packs/*.pck` live under `user://dot_cloud`, which is IndexedDB on web, so a warm load sends the manifest request and nothing else (`bundle_demo` asserts it). `DotCloudMounter` no longer re-hashes every object when the pack for this exact file list already exists. What a refresh can still lose is outside this addon: the shell, the engine `.wasm` and the exported `.pck` come from the origin's HTTP cache, so the host's `Cache-Control` decides whether they are fetched again. `no-store` there re-downloads tens of MiB on every refresh; `no-cache` revalidates by ETag and answers 304. Content under `/content/` is hash-named and wants `public, max-age=31536000, immutable` (only `manifest.json` revalidates), which dot-server-deploy's origin template already has.

## Published mirrors (API 13)

The site publishes a signed list of community mirrors of a game origin at `DotCloudConfig.mirrors_url` (for example `<origin>/content/mirrors.json`): a `DotCloudEnvelope` around `{"format": 1, "kind": "dot_cloud_mirrors", "issued_at", "expires_at", "origin", "mirrors": [{"id", "base_url", "operator", "regions", "packs", "avatars"}]}`. `DotCloudClient.start()` loads it when the URL is set, or call `load_mirror_list(url)` yourself; a list that fails to load is logged and delivery carries on from the origin.

**Trust: a mirror can withhold or corrupt, never substitute.** It serves objects whose hashes a signed manifest already names, so a bad byte fails verification and the next base is tried. Manifests and `latest.json` never come from a mirror. The list itself must verify against a key trusted for the pseudo content id `_platform/mirrors`, so a publisher key scoped to `alice/*` cannot point anybody anywhere. An expired list, a newer format, a bad origin or more than 64 mirrors refuses the whole list; a malformed entry (not http(s), user info, a query, a fragment, dot segments, a duplicate) is dropped on its own.

**Privacy: a mirror sees your address.** `DotCloudConfig.use_mirrors = false` turns the list off entirely: nothing is fetched or probed, every byte comes from the origin, and `mirror_alternatives()` returns nothing.

**Ordering.** `DotCloudMirrorList.rank()` probes each mirror once (HEAD of its copy of `mirrors.json`, all at once, 3 s each) and sorts by latency, unreachable last. For a pack the HTTP source tries: its sticky preferred base (unless that is the origin while mirrors exist), then mirrors the manifest names that are not the origin, then the published mirrors carrying the pack (`packs`: `*`, `owner/*` or an exact id) in rank order, then the origin. A mirror's pack directory is the origin's path under `/content` on the mirror's own `<base_url>/content`. `mirror_alternatives(url)` maps an origin URL (an avatar, say) to the same path on every mirror with `avatars: true`; it returns nothing for a URL outside the origin.

**Per-base health.** A base that fails twice cools down for `cooldown_sec` and moves to the end of the order; it is never removed, because it may be the only one left. The source's own breaker counts **files**, one failure only after every base failed for that file, so one dead mirror cannot take the HTTP source out. `health()` lists `published_mirrors` and `cooling_bases`. Resume and the post-resume restart work against a mirror exactly as against the origin.

## Prefetch (API 13)

`DotCloudClient.prefetch(doc)` warms the cache before a join from a server's prefetch document: `{"format": 1, "kind": "dot_cloud_prefetch", "server_id", "app_id", "packs": [{"id", "version", "bytes"}], "avatar_library", "mirrors_url"}`. Each id and version passes the manifest's own shape check, so a document cannot traverse the cache. Packs are taken in order up to `prefetch_max_packs`; a pack whose missing bytes exceed what is left of `prefetch_max_bytes` is skipped, not truncated. Fetched objects are committed and verified but not mounted, and their refs are released at once, so they stay evictable and the later `ensure()` mounts without fetching them again. On the web it refuses with `CODE_UNSUPPORTED` unless `prefetch_on_web` is on, because the browser cache is small and metered. It returns `{packs_fetched, packs_skipped, bytes, skipped: [{id, version, why}], avatar_library}`.

## Delta patches (designed, not built)

A new version re-downloads every changed file whole. The design: each file entry in the signed manifest may carry `"chunks": {"algo": "fastcdc-v1", "avg": 1048576, "min": 262144, "max": 4194304, "list": [[sha256, size], ...]}`. Chunks are stored as ordinary `objects/<aa>/<sha>`, so mirrors and the store need nothing new. The client rebuilds a file from the chunks it already holds from the previous version, fetches the rest, and verifies the whole-file sha256 before commit, so a wrong chunk can only fail, never substitute. `DotCloudFile` already ignores the key today; building it is a new API level.
