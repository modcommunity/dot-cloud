# Mounting

## A mounted resource pack can never be unmounted

There is no `unload_resource_pack`, on any platform, in any version. Once `ProjectSettings.load_resource_pack()` returns, that pack's file table is merged into the virtual filesystem for the life of the process, and the engine does not track which pack contributed which entry, so there is nothing to unwind even in principle.

The brief is "load and unload games while users are connected". The naive implementation (mount game A at `res://game/`, later mount game B at the same paths with `replace_files = true`) is broken in a way that shows up late:

- files that existed in A and not in B **still resolve**, to A's bytes;
- the resource cache may hand back A's instance for a path B also defines;
- nothing errors: the game behaves as a blend of two content sets.

**So dot-cloud never reuses a path.** Content mounts at `res://<mount_root>/<content_id>/<version>/`, with the version in the path. Mounting B cannot shadow A because they do not overlap, and two versions of one content set can be mounted at once.

## Unloading is freeing the nodes

"Unloading" means: tear down the scene tree, release the store's refs so the objects become evictable, and never look at those paths again.

**Tearing down the scene tree is what frees the resources, and nothing else can.** Godot's resource cache holds no reference of its own (a `Resource` registers itself on load and unregisters in its destructor), so a path leaves the cache exactly when the last real reference drops. There is no script-exposed eviction. `DotCloudMounter.purge_resources` therefore reports what is **still referenced**: a leak count, and a real one. Non-zero means the caller did not free its nodes, which is the one thing that breaks re-entering this version later. (It once called `load(path, "", CACHE_MODE_IGNORE)` on every path and counted successes, which returns a new instance and evicts nothing.)

The file-table entries linger: a few kilobytes per mount, against content measured in megabytes. `DotCloudMounter.restart_process()` is the only true unmount; needing it means content is being mounted at colliding paths, which the namespacing exists to prevent.

## A pack says which addon API it needs

A delivered pack carries none of the dot-* addons (the client shell and the server that mount it do), so its scripts compile against this build's addons. A pack written against a newer dot-net than the host has fails to **parse**, mid-load, with "Identifier not declared in the current scope", which reads as a broken pack.

dot-cloud reads the pack's `requires.json` (dot-core's `DotAddonApi`: `{"addons": {"dot_net": 3}}`, written by dot-ci's `package.sh --pack`) **out of the store; since API level 3 it fetches just that file first and refuses before the pack is downloaded**, and checks again between download and mount, and refuses with "This game needs dot-net API level 3 or newer; this client has level 2." as `CODE_VERSION`. Between download and mount, not after: the file is verified like every other object by then, so nothing has to be mounted to read it, and a refusal after a mount would leave the pack's files in the tree for good.

`host_role` is the noun in that sentence (`"build"` unless the host says `"server"` or `"client"`), because dot-cloud mounts the same way on both and the reader needs to know which to update. `addon_api.overrides` is how a test stands in for an older build. A pack with no `requires.json` (published before it existed, or from a checkout rather than by dot-ci) is not checked.

A game pack mounted at a prefix carries no global class list, so its own scripts cannot use `class_name`; games reference their files by path. (An addon overlay mounted at the root can add class names: see [addon-packs.md](addon-packs.md#three-engine-facts).)

## A pack can leave files out per side

A manifest entry may carry `"side": "client"` or `"side": "server"` (`DotCloudFile.side`, API level 8; written from the source's `sides.json`, see [publishing.md](publishing.md#a-file-only-one-side-needs-sidesjson)). An entry with no `side` is for both, which is every entry published before the field existed and every file no rule matched.

**The fetcher decides which side it is, never the document.** `DotCloudConfig.side` is `auto`, `client`, `server` or `both`; `auto` is `server` on a headless process and `client` otherwise, and a web build resolves to `client` whatever the setting says (`resolved_side()`), because a browser can only be a client. A host that knows what it is says so: dot-server-deploy's server and its installer set `server`, its client shell sets `client` (so a suite running the shell headless fetches what a player fetches) and `both` while it hosts a solo game in-process, and a listen server or a tool that inspects packs sets `both`. `DotCloudClient` stamps the resolved side on the manifest (`DotCloudManifest.fetch_side`, not part of the document) on every way in: `acquire_manifest`, `download_manifest`, `plan_for`.

**Filtered in one place.** `DotCloudManifest.wanted_files()` leaves out the other side's entries, and it is the list the downloader queues, the plan counts, the mounter checks for "everything required is present", builds the pack from, checks for "readable after mounting" and registers UIDs from, and the code rescan reads. A required lightmap a server skipped is therefore never reported missing on the server, and is still required on a client. Nothing is shared across sides in the cache except by hash.

**Signed.** The tag is in the payload the signature covers: a server or mirror that flips `client` to `server`, or drops the tag, breaks the signature, so nobody can talk a client out of a file it needs with an unsigned field. A side value this build does not know is read as both: a later API level may add one, and refusing it would fail the whole manifest on every released build that day. Fetching it everywhere is what a build before API 8 does with any tag; it costs bytes and never a missing file, and the value is still signed. A side is a fetch hint, never access control: every object of a pack sits on the same public mirrors.

**A process that hosts what it joined gets the rest.** A pack cannot be unmounted, so a shell that mounted a game as a client and then hosts it in-process (solo) would have its server-only files missing under a prefix that is already taken. `DotCloudMounter.covers()` says whether the mount holds every file the manifest now wants; when it does not, `acquire_manifest` and `ensure` fetch the difference and the mounter mounts it as a second pack at the same prefix, replacing nothing (`sides_demo`'s widen section). The same applies to a wider group set.

**An older build mounts a tagged pack unchanged.** `DotCloudFile.from_dict` has always ignored keys it does not know, so a build below API 8 reads a tagged entry as an untagged one and fetches both sides, as before. No format version bump: a tagged pack needs nothing new of its reader, it only lets a new one fetch less. An untagged entry serialises without the key, so a pack with no `sides.json` publishes byte-identical manifests and signatures.

## UIDs at mount

An imported asset's binary form refers to its dependencies by UID with the authored absolute path as a fallback, and neither survives being mounted somewhere else. `DotCloudMounter._register_uids` walks the pack's `.import` markers after the mount and points each UID at the mounted copy; see [publishing.md](publishing.md#binary-imports-are-fixed-at-mount). The count is in the mount's log line (`uids=N`).

`ResourceUID.set_id` when the host already knows an id, `add_id` when it does not: they are separate calls and the wrong one is an error, which a host that has mounted an earlier version of the same pack will hit.

## The prefix check

`DotCloudMounter._check_prefix` simplifies both sides before comparing, because `"res://a/b/../../evil"` does begin with `"res://a/b/"`. It is a belt independent of the manifest's own validation; see [trust.md](trust.md#both-path-components-are-checked).
