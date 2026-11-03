# Downloading a whole map set: bundle, collection, or as is

Solo (offline) play wants every map on the disk; an online client wants only the current map and its materials. About forty separate packs is slow for solo (a manifest fetch, a signature check and a mount each) and was noisy in the shell, which now shows one overall bar ([client](client.md), `DotCloudJobProgress`, API 18, parallel since API 19).

## The options

| | (a) one bundle pack with every map | (b) a collection manifest naming the per-map packs | (c) as is |
| --- | --- | --- | --- |
| Bytes | Duplicated: every map is in the bundle and again in its own pack, or the per-map packs stop existing | None extra: same objects, same hashes | None extra |
| Publish cost | Rebuild and re-upload the whole set for one map change | One small manifest per set version | None |
| Version churn | One map edit is a new bundle version, a new mount path (`id/version`), and a client that has the old one mounts the whole set twice | A map edit is a new version of that map and of the collection manifest only | Per map |
| Online | Wrong: a player joining needs one map, not the set | Right: ignore the collection, `ensure` the one map pack | Right |
| Solo | One big transfer, one mount | One signed manifest, then every map fetched and mounted through one job | Same fetches, but unlisted and so unaccounted |
| Mount rule | One path holds everything, so an update can never replace a map | Each map keeps its own `id/version` path | Same |

## Recommendation: (b)

A dependency list already is a collection: a manifest with no files and `dependencies` (API 15) mounts nothing of its own and acquires each named pack first. The aggregate job makes the many fetches one bar, with totals known up front because the dependency manifests are resolved and planned before the first download. (a) duplicates bytes and breaks per-map updates and the online case, and (c) is what was complained about.

What is built: a manifest with no files may name up to `DotCloudManifest.MAX_COLLECTION` (128) dependencies, where a pack with files keeps the cap of eight (`dependency_demo`, "collection"). A game publishes `<game>-all-maps@N` with `--depends` for each map pack, and solo mode `ensure`s that one id; online the server hands out the single map pack.

## Parallel downloads (API 19)

A collection's dependencies download side by side, `DotCloudConfig.parallel_packs` at a time (default 4, 1 to 16; `--cloud-parallel-packs`, `DOT_CLOUD_PARALLEL_PACKS`, or the JSON file, so an admin panel can set it). `DotCloudDownloaderPool` gives each concurrent pack its own `DotCloudDownloader` and so its own HTTPRequest pool: no threads, so it is the same on web. Extra downloaders fetch with a share of `parallel_downloads` (the setting divided by the cap, at least 2) so four packs do not open four times the connections; the first downloader keeps the full setting for a lone pack. Syncs past the cap wait for a free downloader, which also holds for unrelated callers (a prefetch beside the boot map).

- Progress: each pack reports against its own key, and `DotCloudJobProgress` sets rather than adds, so the overall bar stays monotonic and sums the same as in a serial run.
- Failure: a failing dependency stops new ones starting and lets the running ones finish (no hang). The result names the first failure in list order (`<collection> needs <id>@<version>`, cause kept by `wrap`), and `error.context["failed_dependencies"]` lists every failed id.
- `client.pool.peak` is the most syncs seen running together; `dependency_demo` ("parallel") checks it against the cap.
- Manifests resolve through the same cap: `register_dependencies` fetches each level `parallel_packs` manifests at a time (the manifest `DotHttp`'s HTTPRequest pool, no threads), then registers the packs in list order, so job totals do not depend on which fetch finished first and are all known before the first byte. Resolving is not counted as progress; the bar starts when downloads do, as before. A manifest that fails to resolve is skipped there and fails the collection in `ensure_all` with its context. `client.resolve_peak` is the most manifests fetched together; `dependency_demo` checks it against the cap.

## Not built

- Nothing publishes the collection yet: the game repositories' publish scripts (and the suggested-packs list in `DotCloudSuggested`, which is the other way solo gets maps) need to emit it.
