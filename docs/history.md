# History

Bugs worth recognising if they come back. Almost none produced an error. The rule each left is in the topic docs.

- **Every signature failed to verify.** The first design signed a canonical re-serialisation of a manifest whose file on disk was pretty-printed. `sync_demo` caught it; no parse check could have. Hence the envelope.
- **The fan-out hang.** Workers resolving synchronously emitted every completion before the await existed. Hence the member counter.
- **A 1024-bit key verified without complaint**, because the floor was checked only in `generate_keypair`.
- **`version: "../.."` mounted at `res://`**: the version was checked only for slugifying to something non-empty, and the prefix check was a raw `begins_with`.
- **`purge_resources` logged `purged=4` having purged nothing**, after re-reading the whole content set to say it.
- **The index forgot what a crash had in flight**, making those objects uncountable and unevictable; the cache read as exactly at its limit with three times that on disk.
- **The always-built HTTP source with no URLs** sat ahead of the in-band fallback and turned every download's failure into "No content URL is configured."
- **A slow but correct in-band peer** could hold the game connection for over 130 hours before the file timeout existed.
- **A bad partial made content unacquirable on a single-mirror host**: every attempt resumed onto the same bytes, failed the hash, and blamed the only mirror. At the time dot-core's `DotHttp.download_to_file` also overwrote the partial with the ranged tail instead of appending (since fixed in dot-core), so resume saved nothing and was rescued only by the restart.
- **Nobody could find the client.** It was never registered in `DotRegistry`, and four consumers each treated its absence as a build with content baked in. Found by game-hungario (then dot-2d-hungry), the first project to deliver cosmetics through the cloud, whose catalogue never asked.
- **`ensure` and `is_mounted` did not exist**, while dot-map had called them since it was written; every delivered map failed, and dot-map's only loader test ran with no cloud client, so it passed. Found by reading the two sides next to each other, the family's cheapest bug-finding technique.
- **A local manifest could not be fetched** (`HTTPRequest` cannot read `res://`), and then its directory's objects could not be found ("Content is not in any local source directory" with the bytes beside it).
- **A delivered scene named its script by the authored path**: the pack mounted, the scene loaded, and nothing said a word until a method was called. Every game had to move to relative preloads; the publisher now rewrites paths.
- **A delivered `.glb` shipped as its source** and no `load()` could open it (`file=true`, `load=null`).
- **mg-buses-from-hell's crates had no art**: the imported binary scene referred to its atlas by an unregistered UID and the authoring path, and both lines were warnings. Hence `_register_uids`.
- **A pack against a newer addon failed to parse mid-load** with "not declared in the current scope" before `requires.json` was checked.
- **A browser reloaded six times in seventy seconds** on an addon overlay, because the engine dropped the filesystem sync after the last write and the plan was lost. The diagnosis was wrong and so was the four-requests fix: the engine queues syncs, but one sync of the whole `user://` takes seconds, and the reload came first. Production still re-downloaded the addons, restarted twice and joined on the old ones as a guest. Instrumenting `GodotFS.sync` in an exported shell showed it; `persisted()` now reads IndexedDB back before a restart.
- **`sync_demo` could not fail**: it printed its failures and exited 0.

Cross-repo: the path-rebasing forms of the mount constraint that the games found (mg-buses-from-hell's sixth, mg-smash-copter's seventh) are recorded in those games' own docs ([mg-buses-from-hell](../../mg-buses-from-hell/docs/delivery.md#an-imported-models-own-texture-dependency-the-sixth-form), [mg-smash-copter](../../mg-smash-copter/docs/delivery.md#the-seventh-form-a-path-already-rewritten-rebased-again)); the family's bug list is [game-dev/docs/bugs-found.md](../../../docs/bugs-found.md).
