# DotCloudClient

## The registry name

`DotCloudClient` publishes itself in `DotRegistry` under `SERVICE` (`dot_cloud_client`, also dot-core's `DotContent.SERVICE`), and that one line is load-bearing for addons that deliberately do not import this one:

| Who | For what | Without the registration |
| --- | --- | --- |
| dot-server's `DotClientLink` | downloading a game's content | a client can never fetch anything |
| dot-server's `DotGameManager` | releasing the previous game's content | content is never released on a map change |
| dot-server's `DotBuiltinCommands` | the `content` console command | reports nothing |
| dot-user-avatar's `DotAvatarCatalogue` | a cosmetic's content id to a path | cloud-delivered cosmetics are unreachable |
| dot-map's `DotMapLoader` / `DotMapSyncClient` | a map by id and version | delivered maps cannot load |

All are duck-typed and look under the same name, and **none of them errors when it is absent**, because each treats an absent cloud as "this deployment ships its content in the build", which is a legitimate configuration and therefore indistinguishable from the bug.

It registers in `_ready`, not in `start()`: `start()` awaits (the browser reports its storage quota asynchronously), and a consumer resolving the service in between would get null from a client about to work. Nothing found this way has to be started; `acquire()` starts itself.

## acquire and ensure

Two ways to name content:

- **`acquire(manifest_url, groups)`** is the URL form, used by dot-server: an operator wrote the URL in a game's configuration.
- **`ensure(content_id, version)` and `is_mounted(content_id, version)`** are the id form, used by dot-map: a catalogue of two hundred maps should not repeat the CDN hostname two hundred times. `ensure` resolves a manifest URL from `manifest_url_template` against `local_search_dirs` first and `http_base_urls` second, tries each in order, and **checks that the manifest it gets back agrees about its own id and version** before mounting anything: a mirror serving the wrong document would otherwise mount somebody else's content under the id the caller asked for.

Load-bearing details:

- **A local manifest is read, not requested.** `HTTPRequest` cannot fetch `res://` or `user://`, so a deployment serving content off the disk could reach every object and not the one document naming them.
- **A scheme-less string is not automatically a path.** A page served from its content's origin (the one CORS-free browser configuration) uses a root-relative URL like `/content/x/1.0.0/manifest.json`. So the three file schemes are local outright, anything else with a scheme is not, and a bare path is local only if the file is actually there.
- **A published directory holds the manifest and its objects**, so `ensure` adopts the directory a local manifest came from into the local source.

`download_manifest()` and `resolve_manifest()` are the download-without-mount halves `ensure()` is built from; the addon-pack path uses them because an addon pack must never also be mounted at its own content prefix.

A failed sync says why: `DotCloudDownloader` keeps the first required file's failure in the summary's detail, while the summary's code stays `CODE_NETWORK` regardless, because callers branch on codes.

## Dependencies: a shared store is its own content

A manifest may list `dependencies` (`[{"id", "version"}]`, API level 15, signed with the rest of the payload; `DotCloudPublisher.dependencies`, CLI `--depends id@version`). `acquire_manifest` acquires each one through `ensure` before it downloads the pack itself: a dependency already mounted returns at once, and one whose files are already in the store downloads nothing, so a client pays for a shared store once however many packs name it. A pack that fails to get its dependency is refused with the dependency's key in the message and mounts nothing.

- **The version is exact**, because a mounted pack never unmounts and content mounts at `res://<mount_root>/<id>/<version>/`. A store that grows is published as a new version holding the old files too (same hashes, so a client downloads only the difference) and a pack built later names the newer one; an older pack keeps working against the older mount. `dependency_prefix(id, version)` says where a dependency is mounted, "" when it is not.
- **Loops and depth.** A chain deeper than four, or a pack reached again while its own dependencies are being acquired, is refused with `CODE_INVALID`: joining the acquisition already running would wait for itself. At most eight dependencies per manifest.
- **An older build ignores the field** and mounts the pack without the dependency, so the content that needs it fails to find its files; the pack's `requires.json` is the place to say it needs this API level.
- `examples/dependency_demo.tscn` covers it.

## Compiling a pack's scripts before its scene loads

Without threads (a browser), `load()` of a delivered scene compiles its whole script closure in one frame: game-arena's `arena.tscn` was 5.4 s, about 550 scripts, most of them addon classes the pack's scripts name. `warm_content(tree, keys)` compiles them first through `DotCloudSliceLoader`, a slice per frame: the addon classes the pack's sources name (`named_class_scripts`, a word scan; exported scripts report no dependencies), then the pack's own scripts. Keep the returned loader until the scene's `load()` is done, because its `loaded` array is what keeps the cache from dropping them. `DotClientLink` calls it before every delivered scene; it returns at once where there are threads. What it cannot split is one script's own compile (`arena_client.gd`, 2600 lines, about 0.6 s).
