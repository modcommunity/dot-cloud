# dot-cloud

Runtime content delivery for Godot 4: a game server hands a client a manifest,
the client works out what it is missing, downloads it, verifies it, and mounts it
— on desktop, mobile and in the browser.

**The distributable is `addons/dot_cloud/`.** It requires
[dot-core](../dot-core), which is a separate repository.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Read this first: the two constraints that shaped everything

### 1. A mounted resource pack can never be unmounted

There is no `unload_resource_pack`. On any platform, in any version. Once
`ProjectSettings.load_resource_pack()` returns, that pack's file table is merged
into the virtual filesystem for the life of the process, and the engine does not
track which pack contributed which entry, so there is nothing to unwind even in
principle.

The brief is "dynamically load and unload games while users are connected". The
naive implementation — mount game A at `res://game/`, later mount game B at the
same paths with `replace_files = true` — is broken in a way that shows up late:

- files that existed in A and not in B **still resolve**, to A's bytes;
- the resource cache may hand back A's instance for a path B also defines;
- nothing errors — the game behaves as a blend of two content sets.

**So dot-cloud never reuses a path.** Content mounts at
`res://<mount_root>/<content_id>/<version>/`, with the version *in the path*.
Mounting B cannot shadow A because they do not overlap. "Unloading" means: tear
down the scene tree, release the store's refs so the objects become evictable,
and never look at those paths again.

**Tearing down the scene tree is what frees the resources**, and nothing else
can. Godot's resource cache holds no reference of its own — a `Resource`
registers itself on load and unregisters in its destructor — so a path leaves
the cache exactly when the last real reference to it drops. There is no
script-exposed eviction, and `DotCloudMounter.purge_resources` used to pretend
otherwise: it called `load(path, "", CACHE_MODE_IGNORE)` on every path under the
prefix and counted the successes, which returns a *new* instance and leaves the
cached one untouched. `unmount` logged `purged=4` having purged nothing, after
re-reading the whole content set from disk to say it. It now reports what is
still referenced — a leak count, and a real one: a non-zero value means the
caller did not free its nodes, which is the one thing that breaks re-entering
this version later. `mount_demo`'s section 5 asserts it is zero.

The file-table entries linger — a few kilobytes per mount, against content
measured in megabytes. `DotCloudMounter.restart_process()` is the only true
unmount and exists for cases where even that is unacceptable. Needing it means
content is being mounted at colliding paths, which the namespacing exists to
prevent.

### 1a. Nothing can use a client it cannot find

`DotCloudClient` publishes itself in `DotRegistry` under `SERVICE`
(`dot_cloud_client`), and that one line is load-bearing for three other addons that
deliberately do not import this one:

| Who | For what | Without the registration |
| --- | --- | --- |
| `DotClientLink._begin_content_sync` | downloading a game's content | a client can never fetch anything |
| `DotGameManager._unload_current` | releasing the previous game's | content is never released on a map change |
| `DotBuiltinCommands` | the `content` console command | reports nothing |
| `DotAvatarCatalogue` | a cosmetic's content id → a path | cloud-delivered cosmetics are unreachable |

All four are duck-typed and all four look under the same name. Until the registration
existed they all found `null` — and **none of them errored**, because every one of them
treats an absent cloud as "this deployment ships its content in the build", which is a
legitimate configuration and therefore indistinguishable from the bug. Found by
`dot-2d-hungry`, which is the first project to deliver cosmetics through the cloud and
noticed that its catalogue never asked.

It registers in `_ready`, not in `start()`: `start()` awaits — the browser reports its
storage quota asynchronously — and a consumer resolving the service in between would get
null from a client that was about to work. Nothing found this way has to be started;
`acquire()` starts itself.

### 1b. Two ways to name content, and only one of them existed

`acquire(manifest_url, groups)` is the URL form, and it is what dot-server uses: an
operator wrote the URL in a game's configuration, so the server has one to hand.

**Half the family does not.** dot-map addresses a map by `content_id` and
`content_version` out of a catalogue, because a catalogue of two hundred maps should not
repeat the same CDN hostname two hundred times. `DotMapLoader` has called
`ensure(content_id, version)` and `is_mounted(content_id, version)` on whatever it found
under `dot_cloud_client` since the day it was written, and **this client offered neither**
— so every delivered map failed with "the registered cloud client does not speak the
content interface", and dot-map's only loader test runs with *no* cloud client, which is
the branch that falls back to the disk and passes. Nobody had read the two sides side by
side, which is this family's cheapest bug-finding technique and the one that also caught
the leaderboard and stats reporters sending their file formats as the wire.

So `ensure()` and `is_mounted()` are here now. `ensure` resolves a manifest URL from
`manifest_url_template` against `local_search_dirs` first and `http_base_urls` second,
tries each in order, and checks that the manifest it gets back agrees about its own id
and version before mounting anything — a mirror serving the wrong document would
otherwise mount somebody else's content under the id the caller asked for.

Two details that are load-bearing:

- **A local manifest is read, not requested.** `HTTPRequest` cannot fetch `res://` or
  `user://` at all, so a deployment serving content off the disk — which is exactly what
  `local_search_dirs` is for — could reach every object in a pack and not the one
  document naming them.
- **A scheme-less string is not automatically a path.** The obvious rule breaks the one
  CORS-free browser configuration there is: a page served from its content's origin uses
  a root-relative URL like `/content/x/1.0.0/manifest.json`. So the three file schemes are
  local outright, anything else with a scheme is not, and a bare path is local only if
  the file is actually there.
- **A published directory holds the manifest *and* its objects**, so `ensure` adopts the
  directory a local manifest came from into the local source. Without it the id-and-version
  form found a manifest it could not fetch a single file for, failing with "Content is not
  in any local source directory" while the bytes sat next to the document naming them.

### 2. The manifest is the entire trust boundary

Everything downstream trusts it: the hashes decide what counts as a valid
download, and the paths decide what gets mounted. Godot packs can contain
scripts, so **a client that mounts content from an unsigned manifest runs
whatever the server sent.** Per-file hashes do not help — they prove a file
matches what the manifest said, and the manifest is the thing under attack.

`DotCloudConfig.require_signed_manifests` defaults to `true` and `validate()`
refuses to boot without a trusted key. Turning it off is legitimate for LAN play,
first-party servers and development, and logs a warning every time.

**Both path components of the mount prefix are server-supplied, and both need
checking.** `content_id` was always required to equal its own slug. `version` was
not — it cannot be, because `slugify("1.0.0")` is `1_0_0` and equality would
refuse every semver ever published — and for a long time the only check on it
was that it slugified to something non-empty. `slugify("../evil")` is `"evil"`,
non-empty, and `mount_prefix()` interpolates the *raw* string, so a manifest
declaring `version: "../.."` validated cleanly and mounted at `res://` — exactly
the shadowing `mount_root` exists to prevent. It now gets `safe_relative` plus a
separator check, because a version is one path *component*, not a path.
`DotCloudMounter._check_prefix` was no help: it compared with a raw
`begins_with()`, and `"res://a/b/../../evil"` does begin with `"res://a/b/"`.
Both sides are simplified before comparing now, so the belt is independent of
the braces rather than agreeing with whatever they let through.
`mount_demo`'s section 1 is the assertion.

## The signing design, and the bug that produced it

**Signatures live outside the document they sign.** A published manifest is a
`DotCloudEnvelope`:

```json
{ "dot_cloud_signed": 1, "algorithm": "RS256", "key_id": "default",
  "signature": "<base64>", "payload": "<base64url of the manifest JSON>" }
```

The first version put a `signature` field inside the manifest and signed a
canonical re-serialisation. **Every signature it produced failed to verify**,
because the file written to disk was pretty-printed and the signed bytes were
not. `examples/sync_demo.tscn` caught it; no parse check could have.

Canonical JSON is a whole specification (RFC 8785). Implementing it to work
around a self-inflicted problem would be the wrong fix. An opaque base64url
payload means the verifier checks the exact bytes it received with no
reformatting anywhere in the path — the same reason JWS is shaped this way.

`DotCloudManifest.from_json_bytes()` is the single entry point and unwraps the
envelope transparently, so no caller can verify against the wrong bytes.

**RSA, not Ed25519.** Godot's `Crypto` exposes RSA sign/verify via mbedTLS and no
EdDSA. Ed25519 would be better and needs a GDExtension.

**A key floor, enforced on verify.** `MIN_KEY_BITS` is 2048, and for a long time
it was checked only in `generate_keypair` — so a 1024-bit key never made here
verified without complaint. That is not hypothetical: the demo generates one
through `Crypto` directly and, before the check existed, `verify()` accepted its
signature. It only had to reach `trusted_keys`, which is layered config and can
arrive from a JSON file or the environment.

The check is on the *signature length*, not the key: an RSA signature is exactly
as long as the modulus, so 128 bytes means a 1024-bit key and cannot be padded to
claim otherwise — a longer signature just fails `Crypto.verify`. `CryptoKey`
exposes no bit count, and the alternative was walking the DER inside the PEM.
A weak key is `CODE_FORBIDDEN` (not considered), never `CODE_INTEGRITY` (
considered, bytes disagreed); the demo asserts on which.

## Content addressing

Objects are stored under their SHA-256, not their path:
`<cache>/objects/<aa>/<full-hash>`. This is what makes the rest affordable:

- two games sharing a texture pack download it once;
- republishing re-downloads only what changed;
- a partial download cannot be confused with a different file at the same path,
  which is what makes HTTP range resume safe;
- verification is a property of the object, done once, in one place.

**`DotCloudStore.commit_partial()` is that one place.** It hashes the partial,
requires a match, and only then moves it into `objects/`. Nothing unverified is
ever written there, which is why `has()` can be a cheap existence check. Never
write to the object directory from anywhere else.

Partials live in a separate directory keyed by hash. The index
(`<cache>/index.json`) holds size, last-use and refs, and is disposable — it can
always be rebuilt from the directory, because the filenames *are* the hashes.

**The index is always behind the directory, and `open()` reconciles the two.**
Objects are flushed to storage the moment they commit — a tab closed mid-download
has to keep what already finished — while the index is only written at the end of
a sync, at mount and at prune. So every run that ends without `close()` leaves a
valid, parseable index that is missing whatever was in flight, and *because* it
parses, `_rebuild_index()` never gets a chance to notice. An untracked object is
worse than a missing one: `has()` finds it so it is never re-downloaded, `touch()`
cannot stamp it, `_total_bytes` omits it so `shortfall()` under-reports, and
`prune()` iterates the index, so **it can never be evicted**. The ceiling stops
being a ceiling by exactly the amount the last crash had in flight, permanently —
and on mobile that ceiling is what keeps the app from being killed for disk use.
`_reconcile_with_disk()` adopts what it finds, drops entries whose file is gone,
and costs one directory walk, which is what a rebuild costs anyway and what
`sweep_partials()` already spends on the sibling directory. `store_demo`'s
section 4 is the assertion; removing the call turns five checks red, including
one that reports the cache as exactly at its 1 KiB limit with 3 KiB on disk.

**A partial is dead once its object exists.** Resume only ever runs for content
that is *missing*, so an object arriving by another route — the in-band source
after HTTP failed part-way, or another manifest that shares it — strands the
partial. `put_bytes()` discards it, and `sweep_partials()` drops any partial whose
object is present regardless of age, rather than holding the largest files in the
cache twice over for a day. Disk pressure is usually what caused the failover.

## Platform notes

| | |
| --- | --- |
| **Web filesystem** | `user://` is an IndexedDB mirror. `DotWeb.sync_filesystem()` is called after every committed object, not once at the end — a tab closed mid-download must keep what already finished. |
| **Web quota** | `DotCloudStore._resolve_limit()` awaits `navigator.storage.estimate()` and uses `web_quota_fraction` of it. An unavailable estimate falls back to the configured ceiling; never assume unlimited. |
| **Web CORS** | Every fetch is subject to it and `fetch()` will not say why it failed. A content host must send `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers: Range`, and `Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, ETag`. Without the `Range` header, resume is impossible; without the exposed headers, undetectable. Same-origin content avoids all of it. |
| **No threads on web** | Hashing goes through `DotHashJob` on a `DotScheduler`, sliced against a frame budget when there is no worker. |
| **Mobile** | `mobile_cache_bytes` (1 GiB) replaces `cache_bytes` (4 GiB). Filling a phone's storage gets the app killed. |

## Sources

Tried in priority order, with per-source circuit breaking (`failure_threshold`,
`cooldown_sec`, half-open retry).

| Source | Priority | Use |
| --- | --- | --- |
| `DotCloudSourceLocal` | 10 | Development, LAN shares, content bundled in the build. Verifies hashes like everything else — a dev source is being edited, so it is not automatically trustworthy. |
| `DotCloudSourceHttp` | 50 | The normal case. Content-addressed URLs, mirror failover with a sticky preference, range resume. |
| `DotCloudSourceNetchan` | 900 | Bytes over the game connection. Needs no web host, no CORS, no certificate; costs the server's bandwidth. The pre-FastDL fallback. Bounded three ways — see below. |

**The in-band source needs all three of its bounds.** `max_chunks_per_file` caps
round trips, `chunk_timeout_sec` caps one wait, and `file_timeout_sec` caps their
product. Without the third, a peer that answers every chunk correctly, in full,
just slowly, is bounded only by 16384 × 30 s — over 130 hours holding the game
connection, with no failure for the circuit breaker to count, because every
individual wait was legitimate. The per-chunk wait is clamped to whatever is left
of the file budget, and when that is what expired the failure says
`"The in-band transfer took too long."` rather than blaming the peer's latency.
Both timeouts keep the partial: a stalled transfer is a reason to come back, not a
reason to discard what arrived.

**A source is skipped for three different reasons, and they are not the same.**
`is_supported()` answers "on this platform, at all"; `is_available()` answers "not
in circuit-breaker cooldown"; `can_serve(manifest)` answers "with a way to reach
*this* content". The third exists because `DotCloudClient` always builds an HTTP
source whether or not it was given base URLs — a manifest may carry its own
mirrors — so in a netchan-only or local-only deployment that source is healthy,
permanently "available", and completely unable to fetch a byte. It sat at priority
50 ahead of the in-band fallback, spent one of `max_attempts_per_file` per file on
a guaranteed failure, and once netchan tripped its own breaker it was the only
candidate left, so every download failed with *its* complaint: `"No content URL is
configured."` `netchan_demo`'s last section is the assertion, and removing the
`can_serve` filter turns it red with `3 requests for 4 attempts` and that exact
message.

**A failed sync says why, not only which file.** `DotCloudDownloader` keeps the
first required file's failure and puts it in the summary's detail; the summary's
*code* stays `CODE_NETWORK` regardless, because callers branch on codes and the
first failure to lose the race should not change what `acquire_manifest` returns.

**`DotCloudSourceNetchan` does not know how to send a packet.** dot-cloud must not
depend on dot-server, so it calls a duck-typed delegate:

```gdscript
func cloud_chunk_size() -> int
func cloud_request_chunk(sha256: String, offset: int, length: int) -> DotResult
```

The delegate owns rate limiting and must refuse hashes the client has no business
requesting — otherwise it is a way to read the server's cache.

## The GDScript fan-out trap

`DotCloudDownloader.sync()` runs a worker pool. Both obvious spellings are wrong,
and the comment there is longer than the code for good reason:

1. `workers.append(_worker(...))` is a **parse error** — GDScript has no task
   handle, and a `void` coroutine's call expression has no value.
2. Firing workers off and then `while remaining > 0: await _worker_done` **hangs**
   when a source resolves synchronously (local source, warm HTTP cache). Those
   workers run to completion *inside the call*, emitting every signal before the
   await exists.

The working pattern is bare statement calls plus a **member counter**:

```gdscript
_workers_finished = 0
for _i in range(worker_count):
    _worker(todo, results, manifest)
while _workers_finished < worker_count:
    await _worker_done
```

Every return path in `_worker` must increment the counter *and* emit. This is
general to GDScript, not specific to downloads — the same trap applies anywhere in
these repos that fans out coroutines.

## Publishing

```bash
godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    keygen --private keys/content.key --public keys/content.pub

godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    publish --source content/dm_arena --out dist/dm_arena \
    --id dm_arena --version 1.2.0 --entry arena.tscn \
    --key keys/content.key --mirror https://cdn.example.com/dm_arena
```

Output is a static directory (`manifest.json` + `objects/`) you can drop behind
any web server. Exit codes: 0 ok, 1 usage error, 2 operation failed — CI needs to
tell "called it wrong" from "content is bad".

The client-side pack is built at mount time by `PCKPacker`, not by the publisher:
cached objects live at hash-named paths and must appear inside the pack at
`res://<prefix>/<manifest path>`. No export preset can express that remapping.

## Validating changes

```bash
# Parse every script (the --import pass registers class_name globals).
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# End-to-end: keygen, publish, sign, sync, mount, read back, release, re-acquire.
godot --headless --path . res://examples/sync_demo.tscn

# The same pipeline over a real socket: mirror failover, the content-addressed
# URL layout, range resume, a host that refuses ranges, a corrupt mirror.
godot --headless --path . res://examples/http_demo.tscn

# The in-band fallback, against a stand-in for dot-server's delegate: a peer that
# answers, one that never suspends, resume, silence, a mid-file drop, one that
# over-serves, one that is merely slow, and a source with nowhere to fetch from.
godot --headless --path . res://examples/netchan_demo.tscn

# The cache on its own: eviction under pressure, refs, LRU order, the index
# against the directory, partial housekeeping, verify_all, clear_all.
godot --headless --path . res://examples/store_demo.tscn

# The mounter on its own: version traversal, half-downloaded content, two
# versions of one content set mounted at once, unmount and re-entry, a cached
# object that rotted, and the queries.
godot --headless --path . res://examples/mount_demo.tscn
```

**Both demos, not just the first.** `sync_demo` routes every byte through
`DotCloudSourceLocal`, which resolves synchronously, builds no URL, parses no
response and resumes nothing — so for a long time the source every shipped game
actually uses had no executable coverage at all. `http_demo` serves the published
directory over HTTP from `examples/http_test_server.gd` (a ~260-line static file
server in GDScript, so it runs offline and headless with nothing installed) and
drives a real client through it. It found the resume bug described below on its
first run.

**Run the demo.** It found all three real bugs in this addon (the signature
mismatch, the fan-out hang, and the unenforced key floor), and it asserts things
a reader would otherwise have to trust: that dedup happens, that tampering is
refused, that a weak key and an empty body are refused, that content lands inside
its namespace, that optional groups are skipped, that a re-acquire is warm.

**It exits non-zero when one of those fails**, which for a long time it did not:
every boolean printed `"NO — this is a bug"` and then exited 0, so the file read
like a smoke test and could not fail. `_check()` counts, and `_finish()` carries
the count out as the exit code. A test that always passes is worse than no test,
because it gets believed.

## File map

```
addons/dot_cloud/
  dot_cloud_config.gd            Layered config. validate() refuses unsigned-by-default.
  manifest/
    dot_cloud_file.gd            One entry. validate() refuses traversal + bad hashes.
    dot_cloud_manifest.gd        The content set. from_json_bytes() is the only parser.
    dot_cloud_envelope.gd        Signed wrapper. Read the class doc.
  store/
    dot_cloud_store.gd           Content-addressed cache, LRU eviction, refs, index.
                                 open() reconciles the index against the directory.
  transfer/
    dot_cloud_source.gd          Base + circuit breaker + can_serve().
    dot_cloud_source_http.gd     Mirrors, range resume, CORS notes. See "Resume" below.
    dot_cloud_source_local.gd    Directories. Still verifies hashes.
    dot_cloud_source_netchan.gd  In-band over the game connection, via a delegate.
    dot_cloud_downloader.gd      Worker pool, failover, throttle, progress.
  verify/
    dot_cloud_signature.gd       RSA-SHA256 sign/verify, constant-time paths.
  mount/
    dot_cloud_mounter.gd         PCK building + the unmount problem. Read the class doc.
                                 purge_resources reports leaks; it cannot evict.
  client/
    dot_cloud_client.gd          The one node a game needs. acquire() by URL,
                                 ensure() by id and version — see 1b.
  publish/
    dot_cloud_publisher.gd       Directory -> manifest + objects.
    dot_cloud_cli.gd             Headless CLI. Extends SceneTree.
```

## Resume, and why a failed hash after one is not the mirror's fault

`DotCloudSourceHttp` resumes an interrupted transfer by asking the host for
`bytes=N-`, where N is whatever is already in `<cache>/partial/<hash>.part`.

Those N bytes have been verified by **nothing**. `commit_partial` is the only
place a hash is ever checked, and it only runs once the whole object is on disk.
So a partial can be wrong for reasons that have no connection to the mirror
currently serving: a process killed mid-write, a bad sector, a caching proxy that
answered a range with the wrong window, or an HTTP layer whose resume does not
append.

That matters because the obvious reading of a post-resume hash failure — "this
mirror served bad bytes" — is usually wrong, and acting on it is worse than
useless. `commit_partial` has already discarded the partial by then, so the retry
that would have succeeded is exactly the one the mirror loop skips. On a
single-mirror host, which is the normal deployment, a bad partial turned into
content that could never be acquired: every attempt resumed onto the same bad
bytes, failed the same hash, and moved on to a mirror list with nothing else in
it.

The source now restarts that one transfer from zero against the same mirror
before writing it off. `http_demo`'s "poisoned partial" section is the assertion
— it plants 64 KiB of garbage as the partial and requires the acquire to succeed
anyway — and stubbing the restart out turns five checks red.

**Known upstream defect (2026-08-18): `DotHttp.download_to_file` does not
append.** Given an existing partial of N bytes it sends the right `Range: bytes=N-`,
receives the right response, and then writes it at offset 0 over the top of the
partial — leaving a file the size of the *remainder* and returning `ok`. Resume
therefore never actually saves bandwidth today; it costs an extra round trip and
is rescued by the restart path above. `http_demo` prints the byte count each run
(`transferred N B for M B of objects`) rather than asserting on it, so a fix
upstream shows up as that number dropping below the content size. The fix belongs
in dot-core, which was out of scope for the run that found this.

## Things deliberately not here

- **Delta patching.** Content addressing already avoids re-downloading unchanged
  *files*; bsdiff-style patching of changed files would help for large binaries
  that change slightly. Real work, clear payoff, not started.
- **Compression.** Objects are stored and transferred as-is; `Accept-Encoding:
  gzip` covers the wire for compressible content. Storing compressed would
  complicate the "filename is the hash of the content" invariant.
- **An editor dock.** Publishing is CLI-only. A dock calling `DotCloudPublisher`
  would be straightforward.
- **Ed25519 signatures.** Blocked on Godot's `Crypto`. See above.
