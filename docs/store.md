# The store

## Content addressing

Objects are stored under their SHA-256, not their path: `<cache>/objects/<aa>/<full-hash>`. This is what makes the rest affordable:

- two games sharing a texture pack download it once;
- republishing re-downloads only what changed;
- a partial download cannot be confused with a different file at the same path, which is what makes HTTP range resume safe;
- verification is a property of the object, done once, in one place.

**`DotCloudStore.commit_partial()` is that one place.** It hashes the partial, requires a match, and only then moves it into `objects/`. Nothing unverified is ever written there, which is why `has()` can be a cheap existence check. Never write to the object directory from anywhere else (`put_bytes()` verifies the same way).

Partials live in a separate directory keyed by hash. The index (`<cache>/index.json`) holds size, last-use and refs, and is disposable: it can always be rebuilt from the directory, because the filenames are the hashes.

## The index is always behind the directory

Objects are flushed the moment they commit (a tab closed mid-download has to keep what finished), while the index is written only at the end of a sync, at mount and at prune. So every run that ends without `close()` leaves a valid, parseable index missing whatever was in flight, and because it parses, `_rebuild_index()` never notices. An untracked object is worse than a missing one: `has()` finds it so it is never re-downloaded, `touch()` cannot stamp it, `_total_bytes` omits it so `shortfall()` under-reports, and `prune()` iterates the index, so **it can never be evicted**. The ceiling stops being a ceiling by whatever the last crash had in flight, permanently, and on mobile that ceiling keeps the app from being killed. `open()` calls `_reconcile_with_disk()`, which adopts what it finds and drops entries whose file is gone, for one directory walk.

## Partials

**A partial is dead once its object exists.** Resume only runs for missing content, so an object arriving by another route (the in-band source after HTTP failed part-way, or another manifest sharing it) strands the partial. `put_bytes()` discards it, and `sweep_partials()` drops any partial whose object is present regardless of age, rather than holding the largest files twice for a day; disk pressure is usually what caused the failover.

A partial's bytes are verified by nothing until the whole object commits; see [sources.md](sources.md#resume).

## Platform notes

| | |
| --- | --- |
| **Web filesystem** | `user://` is an IndexedDB mirror. `DotWeb.sync_filesystem()` is called after every committed object, not once at the end: a tab closed mid-download must keep what finished. |
| **Web quota** | `DotCloudStore._resolve_limit()` awaits `navigator.storage.estimate()` and uses `web_quota_fraction` of it. An unavailable estimate falls back to the configured ceiling; never assume unlimited. |
| **Web CORS** | Every fetch is subject to it and `fetch()` will not say why it failed. A content host must send `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers: Range`, and `Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, ETag`. Without `Range`, resume is impossible; without the exposed headers, undetectable. Same-origin content avoids all of it. |
| **No threads on web** | Hashing goes through `DotHashJob` on a `DotScheduler`, sliced against a frame budget when there is no worker. |
| **Mobile** | `mobile_cache_bytes` (1 GiB) replaces `cache_bytes` (4 GiB). Filling a phone's storage gets the app killed. |
