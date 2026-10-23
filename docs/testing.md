# Testing

The family's method is in [game-dev/docs/testing.md](../../../docs/testing.md); this is what is specific here.

| Scene | What it covers |
| --- | --- |
| `examples/sync_demo.tscn` | end to end through the local source: keygen, publish, sign, sync, mount, read back, release, re-acquire; dedup, tampering, a weak key, an empty body, namespacing, optional groups, a warm re-acquire |
| `examples/http_demo.tscn` | the same pipeline over a real socket (`examples/http_test_server.gd`, a static file server in GDScript, so it runs offline and headless): mirror failover, the content-addressed URL layout, range resume, a host that refuses ranges, a corrupt mirror, a poisoned partial |
| `examples/netchan_demo.tscn` | the in-band source against a stand-in for dot-server's delegate: a peer that answers, one that never suspends, resume, silence, a mid-file drop, one that over-serves, one that is merely slow, a source with nowhere to fetch from |
| `examples/delivered_scene_demo.tscn` | a scene delivered in a pack, with its script, actually running; a pack needing a newer addon API refused before it mounts; `extra_files` (in the pack, replaces a source file, a missing file or `..` path fails) |
| `examples/store_demo.tscn` | the cache alone: eviction under pressure, refs, LRU order, the index against the directory, partial housekeeping, `verify_all`, `clear_all` |
| `examples/mount_demo.tscn` | the mounter alone: version traversal, half-downloaded content, two versions mounted at once, unmount and re-entry with a zero leak count, a rotted object, the queries |
| `examples/workshop_demo.tscn` | `provides.json` validation at publish (missing file, `..`, `res://`, kind not listed, duplicate), `runs_code` computed, a data pack mounting as a solo subscription and the index listing it, online seeing none of it, `tag_pack` reuse by a server, a forged manifest whose files run code refused (`CODE_FORBIDDEN`), an addon overlay refused with `allow_root: false`, `uid_policy: add_only` leaving the game's and the host's UIDs alone (armed: a plain mount does move one), the script scan on its own |
| `examples/workshop_sync_demo.tscn` | `DotCloudWorkshop` against a fake site (`workshop_backbone.gd`) and real signed packs over HTTP: first sync, an unchanged revision, a removal, offline (503, a timeout, no cache, another account's cache), one broken pack among three, a wrong-key pack, device-off and script policy, metered ask/never/allow, quota and `workshop_max_packs`, guest, a refused token, disabled, online refused (index session and `dot_client_link`), the scope write and the stale-revision rule after it |
| `examples/sides_demo.tscn` | client-only and server-only files (API 8): the tags as published from `sides.json`, a flipped and a dropped tag failing the signature (and `verify_manifest`), a server fetching and mounting no client-only object with every required file of its side present, a client fetching no server-only object, `both`, the config's `auto` and its refusal of a misspelt side, the publisher's refusals (cross-side references in a scene, a file the other side needs), a client mount widened to both in one process, the parser reading an unknown side as both |
| `examples/bundle_demo.tscn` | the small-object bundle (API 9): a cold acquire is one bundle request plus the oversized object, a warm one only the manifest, a corrupt bundle falls back to 41 per-file requests |
| `examples/auto_update_demo.tscn` | `DotCloudAutoUpdate` with a fake clock, origin and player count: restart at once when empty, waiting for empty, `max_wait` forcing a warned countdown, `max_wait: 0` never forcing, `when_empty` off, disabled, the restart record that stops a loop, file < environment layering, the cvars, `latest.json` parsing, failures |
| `examples/tokens_demo.tscn` | a pack whose scripts ship as binary tokens (API 11): tokenizes a tiny project with the engine's exporter, publishes with and without `script_tokens_dir`, mounts, loads and runs the script; needs `godot` on PATH |
| `examples/addon_set_demo.tscn` | newer addons over the build: the policy, an overlay built through a real client, fresh processes through the boot scene ([addon-packs.md](addon-packs.md#testing)) |

**Run them all.** `sync_demo` routes every byte through the local source, which resolves synchronously, builds no URL, parses no response and resumes nothing, so for a long time the source every shipped game uses had no executable coverage. Every demo publishes data except `delivered_scene_demo`, which is why a script that could not be found in a mounted scene went unnoticed.

**A demo must be able to fail.** `sync_demo` once printed "NO — this is a bug" and exited 0. `_check()` counts and `_finish()` carries the count out as the exit code. A test that always passes is worse than no test, because it gets believed.

Recent sections are armed: they state what they measured with the fix reverted. Revert and watch one fail before trusting it.

## The fan-out trap

`DotCloudDownloader.sync()` runs a worker pool, and both obvious spellings are wrong:

1. `workers.append(_worker(...))` is a **parse error**: GDScript has no task handle, and a `void` coroutine's call expression has no value.
2. Firing workers off and then `while remaining > 0: await _worker_done` **hangs** when a source resolves synchronously (local source, warm HTTP cache): those workers run to completion inside the call, emitting every signal before the await exists.

The working pattern is bare statement calls plus a **member counter**:

```gdscript
_workers_finished = 0
for _i in range(worker_count):
    _worker(todo, results, manifest)
while _workers_finished < worker_count:
    await _worker_done
```

Every return path in `_worker` must increment the counter **and** emit. This is general to GDScript; see [gdscript-hazards.md](../../../docs/gdscript-hazards.md).
