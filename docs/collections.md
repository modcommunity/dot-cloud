# Downloading a whole map set: bundle, collection, or as is

Solo (offline) play wants every map on the disk; an online client wants only the current map and its materials. About forty separate packs is slow for solo (a manifest fetch, a signature check and a mount each) and was noisy in the shell, which now shows one overall bar ([client](client.md), `DotCloudJobProgress`, API 18).

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

## Not built

- Dependencies are acquired one after another: `_download` is serialised by the client's single sync, and the downloader parallelises only the files inside a pack. Fetching several packs at once needs a sync per pack and is the next step if forty serial manifest round trips are still slow.
- Nothing publishes the collection yet: the game repositories' publish scripts (and the suggested-packs list in `DotCloudSuggested`, which is the other way solo gets maps) need to emit it.
