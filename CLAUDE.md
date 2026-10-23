# dot-cloud

Runtime content delivery for Godot 4: a game server hands a client a manifest, the client works out what it is missing, downloads it, verifies it, and mounts it, on desktop, mobile and in the browser. It also lays newer addon releases over a client build at its next start (`DotCloudAddonSet`), so an addon release does not need a new build.

**The distributable is `addons/dot_cloud/`.** It requires [dot-core](../dot-core), which is a separate repository.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to content delivery. The reasoning is in [docs/](docs/README.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/mounting.md](docs/mounting.md) | `DotCloudMounter`, mount paths, unloading, the addon-API check, UIDs at mount |
| [docs/trust.md](docs/trust.md) | manifests, signatures, envelopes, trusted keys, anything a server or publisher supplies |
| [docs/client.md](docs/client.md) | `DotCloudClient`: the registry name, `acquire` by URL, `ensure` by id and version |
| [docs/store.md](docs/store.md) | `DotCloudStore`: content addressing, the index, partials, the web and mobile limits |
| [docs/sources.md](docs/sources.md) | local, HTTP and in-band sources, failover, resume, the downloader |
| [docs/publishing.md](docs/publishing.md) | the CLI and `DotCloudPublisher`: imported assets, path rewriting, `DotCloudRegistry` |
| [docs/addon-packs.md](docs/addon-packs.md) | `addon_set/`, `boot/`: newer addons over the build |
| [docs/workshop.md](docs/workshop.md) | `provides.json`, `DotContentIndex`, `workshop/`, session tags, anything a subscription mounts |
| [docs/testing.md](docs/testing.md) | the twelve demos, the fan-out trap, adding a check |
| [docs/history.md](docs/history.md) | a delivery bug that "cannot be happening"; how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_cloud/dot_cloud_config.gd` | layered config; `validate()` refuses unsigned by default |
| `addons/dot_cloud/dot_cloud_api.gd` | the API level (dot-core's `DotAddonApi` rule) and what each level added: 2 `DotCloudPublisher.extra_files`, 3 `acquire` refuses on `requires.json` before downloading the pack, 4 `ship_import_sources`, 5 `provides`, `DotCloudScriptScan`, `ensure_for_session`, 6 `DotCloudWorkshop`, 7 `client_platform`, 8 `DotCloudFile.side` / `DotCloudConfig.side` / `sides.json`, 9 `DotCloudManifest.bundle` (one signed ZIP of the small objects), `DotCloudPublisher.write_bundle`, `DotCloudConfig.use_bundles`, 10 `DotCloudSliceLoader.loaded` / `named_class_scripts`, `DotCloudClient.warm_content` (compiles a pack's scripts a slice per frame, reports progress), 11 `DotCloudPublisher.script_tokens_dir` (scripts as `.gdc` + `.gd.remap`, made by `publish/tokenize_scripts.sh`) |
| `addons/dot_cloud/manifest/` | `DotCloudFile` (refuses traversal and bad hashes), `DotCloudManifest` (`from_json_bytes()` is the only parser), `DotCloudEnvelope` (the signed wrapper), `DotCloudProvides` (the `provides` block, strict at publish, tolerant at mount), `DotCloudScriptScan` (`runs_code`) |
| `addons/dot_cloud/store/` | the content-addressed cache: LRU eviction, refs, the index |
| `addons/dot_cloud/transfer/` | source base with circuit breaker and `can_serve()`; HTTP, local, in-band sources; the downloader (worker pool, failover, throttle, progress) |
| `addons/dot_cloud/verify/` | RSA-SHA256 sign/verify |
| `addons/dot_cloud/mount/` | `DotCloudMounter`: PCK building and the unmount problem |
| `addons/dot_cloud/client/` | `DotCloudClient`, the one node a game needs |
| `addons/dot_cloud/addon_set/`, `boot/` | newer addons as packs; the boot scene that mounts the overlay (names no addon class, and must not) |
| `addons/dot_cloud/publish/` | publisher, CLI, `DotCloudRegistry` (built ahead of its consumer) |
| `addons/dot_cloud/workshop/` | `DotCloudWorkshop` (registry `dot_workshop`, the solo sync client), `DotCloudWorkshopConfig`, `DotCloudWorkshopList`, `DotCloudWorkshopDevice` (this device's overrides) |
| `examples/` | the twelve demos, `http_test_server.gd`, `workshop_backbone.gd` (a fake site), the addon boot probe |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then every demo: `sync_demo`, `http_demo`, `netchan_demo`, `delivered_scene_demo`, `store_demo`, `mount_demo`, `addon_set_demo`, `workshop_demo`, `workshop_sync_demo`, `sides_demo`, `bundle_demo`, `tokens_demo`. Each exits non-zero on a failed check. [testing](docs/testing.md)
- `sync_demo` alone proves nothing about the source every game uses: run `http_demo` too. `delivered_scene_demo` is the only one that publishes a scene with a script.
- A delivery change is not done until a real client has joined a delivered pack (dot-server-deploy's `examples/*_client.tscn`).

## Rules that bite

Short forms; the reasoning is in the linked file.

**Mounting**

- A mounted pack can never be unmounted. Content mounts at `res://<mount_root>/<content_id>/<version>/` and a path is never reused. [mounting](docs/mounting.md#a-mounted-resource-pack-can-never-be-unmounted)
- Unloading is freeing the nodes; `purge_resources` reports a leak count and cannot evict. A non-zero count is a caller that did not free its nodes. [mounting](docs/mounting.md#unloading-is-freeing-the-nodes)
- A pack's `requires.json` is checked between download and mount, never after. [mounting](docs/mounting.md#a-pack-says-which-addon-api-it-needs)
- A delivered game references its own files by path (no `class_name` in a game pack). [mounting](docs/mounting.md#a-pack-says-which-addon-api-it-needs)

**Workshop**

- `provides` is signed into the manifest from the source's `provides.json`; `runs_code` is computed by `DotCloudScriptScan`, never the author's. A manifest with `provides` whose stored files run code it did not declare is `CODE_FORBIDDEN` before the mount. [workshop](docs/workshop.md#runs_code)
- A subscription mounts through `ensure_for_session(..., &"solo", &"subscription", {uid_policy: "add_only", allow_root: false})`: never online, never at the root, never re-pointing a UID the process knows. [workshop](docs/workshop.md#registering-on-mount)

**Trust**

- The manifest is the whole trust boundary; packs carry scripts. `require_signed_manifests` stays true outside LAN and development. [trust](docs/trust.md#the-manifest-is-the-entire-trust-boundary)
- Both `content_id` and `version` are server-supplied path components: `version` goes through `safe_relative` plus a separator check, and `_check_prefix` simplifies both sides. [trust](docs/trust.md#both-path-components-are-checked)
- Signatures live outside the signed bytes (`DotCloudEnvelope`); `DotCloudManifest.from_json_bytes()` is the only parser. Never sign a re-serialisation. [trust](docs/trust.md#the-envelope)
- `MIN_KEY_BITS` (2048) is enforced on verify, by signature length; a weak key is `CODE_FORBIDDEN`, never `CODE_INTEGRITY`. [trust](docs/trust.md#a-key-floor-enforced-on-verify)
- `verify_for`: verification first, entitlement (`content_ids`) second. [trust](docs/trust.md#a-key-says-what-it-is-trusted-for)
- The in-band delegate must refuse hashes the client has no business asking for. [sources](docs/sources.md#the-in-band-source)

**Client**

- `DotCloudClient` registers as `dot_cloud_client` in `_ready`, not `start()`: four addons find it there and treat its absence as "content ships in the build". [client](docs/client.md#the-registry-name)
- `ensure(id, version)` checks the fetched manifest's own id and version before mounting; a local manifest is read, not requested. [client](docs/client.md#acquire-and-ensure)

**Store and sources**

- Nothing unverified is written to `objects/`: `commit_partial()` and `put_bytes()` are the only writers. [store](docs/store.md#content-addressing)
- `open()` reconciles the index against the directory; never trust the index alone. [store](docs/store.md#the-index-is-always-behind-the-directory)
- On web, sync the filesystem after every committed object; await the quota estimate; never assume unlimited. [store](docs/store.md#platform-notes)
- A source is skipped by `is_supported`, `is_available` or `can_serve`, three different questions. [sources](docs/sources.md#three-reasons-to-skip-a-source)
- The in-band source needs all three bounds (chunks, chunk timeout, file timeout). [sources](docs/sources.md#the-in-band-source)
- A hash failure after a resume restarts that transfer from zero on the same mirror before blaming it. [sources](docs/sources.md#resume)
- Fan out coroutines with bare calls plus a member counter; every return path increments and emits. [testing](docs/testing.md#the-fan-out-trap)

**Publishing**

- Ship the imported form (`include_imported`, on by default); the source project must have been imported first. [publishing](docs/publishing.md#an-imported-asset-is-not-shippable-as-its-source)
- An imported asset's source is left out (`ship_import_sources` off, API 4): it was half of every game pack and nothing at runtime opens it. A file whose marker names no output (`keep`) still ships. [publishing](docs/publishing.md#the-source-of-an-imported-asset-stays-behind)
- The publisher rewrites `res://` paths in `.tscn`/`.tres` onto the mount; binary `.scn`/`.res` it cannot, and the mount registers UIDs instead. [publishing](docs/publishing.md#a-scenes-references-move-with-the-pack)
- A file in the pack that is not under the source goes in `extra_files` (API 2); never override `_imported_outputs_for`. [publishing](docs/publishing.md#a-file-that-is-not-under-the-source-extra_files)
- A file only one side needs is declared in the source's `sides.json` (`{"client": [...], "server": [...]}`, API 8); the tag is signed into the entry, and the side a process fetches as is its own `DotCloudConfig.side` (`auto`: headless is server; web is always client). `wanted_files()` is the one filter. An unknown side value is read as both (a new side is a new level); a scene referencing the other side's file is refused at publish; a mount widens in place when the same process later wants more of it (`covers()`). [publishing](docs/publishing.md#a-file-only-one-side-needs-sidesjson), [mounting](docs/mounting.md#a-pack-can-leave-files-out-per-side)
- `DotCloudRegistry` has no caller on purpose: it waits for its site endpoint. [publishing](docs/publishing.md#dotcloudregistry-is-written-and-nothing-calls-it)

**Addon packs**

- A script compiled in this process keeps its code: an overlay takes effect only at the next start, mounted by a boot scene that names no addon class. [addon-packs](docs/addon-packs.md#three-engine-facts)
- Only upward, only signed, only from `namespaces`, only into the addon's own directory; two unconfirmed starts turn the overlay off. [addon-packs](docs/addon-packs.md#what-keeps-it-from-doing-harm)

## Deliberately not here

Delta patching (real work, clear payoff, not started), stored compression (it would break "the filename is the hash of the content"; `Accept-Encoding: gzip` covers the wire), an editor dock (publishing is CLI-only), and Ed25519 (Godot's `Crypto` has no EdDSA; it needs a GDExtension).
