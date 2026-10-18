# The Workshop: subscribed packs in solo play

A player subscribes to a pack on the site (a map pack, a weapon pack, props, NPCs, a pack of tools), for every game or for chosen games, and the next solo launch of a game on any device downloads it, mounts it and shows it in that game's menus. An online session never sees any of it. This file is the contract every piece is built against: the `provides` block a pack publishes, the runtime index that carries a mounted pack's entries to the game, the sync client, the solo launch flow and the isolation rules. The site's half (scope, compatibility, the wire format) is website-city's `docs/workshop.md`; the two files describe one interface and change together.

The pieces and where they live:

| Piece | Where | Names |
| --- | --- | --- |
| What a pack provides | the pack source's `provides.json`, signed into the manifest as `provides` | `DotCloudProvides` (dot-cloud `manifest/`) |
| The runtime index | dot-core `core/` | `DotContentIndex`, `DotContentEntry`, registry name `dot_content_index` |
| Registering on mount, session tags, the code scan | dot-cloud `client/`, `mount/` | `DotCloudClient.ensure_for_session`, `DotCloudScriptScan` |
| The sync client | dot-cloud `workshop/` | `DotCloudWorkshop` (registry name `dot_workshop`), `DotCloudWorkshopList`, `DotCloudWorkshopDevice` |
| The site API | website-city | `GET /api/app/v1/workshop`, `POST /api/app/v1/workshop/scope` |
| Solo launch and the panel | dot-server-deploy `client/` | `TmcSoloSession`, `TmcWorkshopPanel` |
| Consumers | dot-map, dot-weapon, dot-props, dot-npc, game-playground | `follow_content(index)` on each catalogue |

## Why the sync client is in dot-cloud and not a new addon

A `dot-workshop` addon on dot-cloud and dot-auth was the alternative. It would be a second repository, a `projects.tsv` row, a family entry, an `addons.lock` line and a new shell build for about four files, and it would be the third addon in the family that needs two others. dot-cloud already speaks to the site (`DotCloudRegistry` is the publishing half of the same backbone), and everything the client does after the list arrives is dot-cloud's own `ensure`. The one thing it needs from dot-auth is a bearer token, and that arrives as a `Callable` (`token_fn`) the host sets, so dot-cloud still imports nothing but dot-core. If the Workshop grows a UI of its own or a second backbone (a server-side subscription list for a community server), that is the point to split it out.

## What a pack provides

### `provides.json`

A pack that wants to appear anywhere in a game says so in one file at the root of its source:

```json
{
    "schema": 1,
    "title": "Utopia surf maps",
    "kinds": ["map"],
    "games": "*",
    "categories": [
        {"id": "utopia", "name": "Utopia", "icon": "icons/utopia.png"}
    ],
    "entries": [
        {
            "kind": "map", "id": "surf_utopia", "name": "Utopia",
            "scene": "maps/surf_utopia/map.tscn", "map_kind": "surf",
            "thumbnail": "maps/surf_utopia/thumb.png", "category": "utopia"
        }
    ]
}
```

`DotCloudPublisher` reads it, validates it, and writes it into the manifest as the `provides` key, so it is covered by the same signature as every hash. The file also ships in the pack, but nothing reads the copy: the manifest is the one source, because it is the only one that is verified before anything is downloaded. The site's packer (website-city's `pack-publish` worker) does the same for packs uploaded through the site.

Top-level fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | int | The version the writer knew. Version 1 is this document |
| `title` | string | The pack's name in menus (a category per pack is titled with it) |
| `kinds` | string array | Every kind the entries contain. A pack with maps and props lists both; there is no `mixed` kind |
| `games` | `"*"` or string array | The author's statement of which games it is for, by game content id (`gamemann/game-playground`). The site turns it into the asset's compatibility, which the owner can then edit. Absent means `"*"` |
| `categories` | object array | Optional spawn-menu groupings: `id`, `name`, optional `icon` |
| `entries` | object array | One per thing the pack contributes |
| `accepts` | object | **Game packs only** (kind `game`): which kinds of subscribed pack the game takes. See below |

Every path is **relative to the pack root**, never `res://`: the index resolves it onto the mount prefix. The publisher refuses a path that is absolute, contains `..`, or names a file the pack does not ship (an imported asset counts when its `.import` marker ships, the same rule as the rest of the publisher).

### The kinds and their entries

Every entry has `kind`, `id` (unique within the pack and kind, `[a-z0-9_]+`), `name`, and may have `category` (an id from `categories`), `thumbnail` (a pack path to an image), `tags` (string array) and `meta` (a free dictionary the consumer of that kind defines). The kind-specific fields:

| Kind | Fields | Consumer |
| --- | --- | --- |
| `map` | `scene`, `map_kind` (a `DotMapDef.kind`), optional `zones`, `min_players`, `max_players`, `tier` | dot-map `DotMapCatalogue` |
| `weapon` | `def` (a `DotWeaponDef` `.tres`), optional `slot` | dot-weapon `DotWeaponCatalogue` |
| `prop` | `def` (a `DotPropDef` `.tres`) or `scene` | dot-props `DotPropCatalogue` |
| `npc` | `def` (a dot-npc definition `.tres`) or `scene` | dot-npc `DotNpcCatalogue` |
| `entity` | `script` (a path to a script a game spawns as an entity, game-playground's shape) | the game |
| `tool` | `script` | the game (game-playground's tool gun) |
| `sound` | `stream` | dot-audio, or the game |
| `script` | `script`, `hook` (the hook name, for example `playground`) | the game's hook loader (game-playground's `playground_hook.gd` contract) |
| `addon` | `dir` | **not mounted from a subscription** (see [online isolation](#online-isolation)) |
| `game` | none; uses `accepts` | the site and the shell; never subscribable |

A weapon's `def` names its behaviour script by path. A path inside the pack is rebased onto the mount by the publisher's rewrite like any other; a path under `res://addons/` is the host build's copy and is left alone, which is how a pack whose code is already in the shell (zee-dot-weapons, zed-dot-weapons) ships only its definitions and art. Per-pack art roots and similar consumer settings go in the entry's `meta` (zee's `asset_root`, relative to the pack root).

`kinds` and `map_kind` are open sets. A kind this build does not know is kept in the index and offered to nobody; an unknown field is ignored. Neither is an error, and neither is logged above DEBUG, because a newer pack on an older client is the normal case.

### What a game accepts

A game pack's `provides.json` has `"kinds": ["game"]`, no entries, and an `accepts` block:

```json
{
    "schema": 1,
    "kinds": ["game"],
    "accepts": {
        "kinds": ["map", "weapon", "prop", "npc", "entity", "tool", "script"],
        "map_kinds": ["sandbox", "surf", "bhop"]
    }
}
```

The site reads it from the game's newest ready version and offers a pack for that game only when the pack's kinds meet `accepts.kinds` (and, for a pack that provides only maps, when one of its `map_kind`s is in `accepts.map_kinds`). **A game with no `accepts` takes no subscriptions at all**: the Workshop is opt-in per game, written in the game's repository, so a game with a fixed level is never offered a map pack it cannot load. The game's consumers filter again at runtime with the same lists, because the site's check is a convenience and a stale list is possible.

### The schema rule

Changes to `provides` are additive only: a new kind, a new optional field, a new top-level key. `schema` rises with each addition so a reader can tell what the writer knew, and a reader handed a higher `schema` than its own still reads every field it knows. A change that would make an old reader misread a document is not made under this key; it gets a new key beside it.

### `runs_code`

The publisher adds `runs_code` (bool) to the manifest's `provides`, computed by `DotCloudScriptScan`, never taken from the author's file. A pack runs code when it ships any of: `.gd`, `.gdc`, `.cs`, `.gdextension`, a native library; a text resource (`.tscn`, `.tres`) with a `GDScript` or `CSharpScript` sub-resource, or an `ext_resource` naming a script inside the pack; a binary resource (`.scn`, `.res`) whose bytes contain a script class name. Kinds `entity`, `tool` and `script` always run code. **The scan is a label for honest packs, not a sandbox**: a binary resource can be crafted to hide a script from any byte search, which is why the policy below rests on the site's signature and its review, and why the client re-scans between download and mount and refuses a pack whose files say more than its manifest did.

## The runtime index

### `DotContentIndex`

dot-core, `core/dot_content_index.gd`, beside `DotContent`. It is the answer to "what has been mounted that I could offer?" for every consumer, so no game, map menu or spawn menu ever names a pack path. It is an instance, not a static class, because it needs signals (the reason `DotLogBus` and `DotRegistryBus` exist), and it lives in `DotRegistry` under `dot_content_index` (`DotContentIndex.SERVICE`).

```gdscript
static func shared() -> DotContentIndex      # the registered one, created and registered on first call
signal pack_added(pack: Dictionary, entries: Array[DotContentEntry])
signal session_changed(session: StringName)

func add_pack(info: Dictionary) -> DotResult  # {content_id, version, prefix, provides, session, source}
func tag_pack(content_id: StringName, version: String, session: StringName) -> void
func set_session(session: StringName) -> void
func session() -> StringName
func entries(kind: StringName, session: StringName = &"") -> Array[DotContentEntry]  # "" = the current session
func entry(key: String) -> DotContentEntry
func packs(session: StringName = &"") -> Array[Dictionary]
func describe_lines() -> PackedStringArray
```

`shared()` creating on demand is what makes order irrelevant: a catalogue built before the first mount and a cloud client that mounts before any catalogue exists find the same object. A test replaces it with `DotRegistry.register(DotContentIndex.SERVICE, its_own)`. A deployment without dot-cloud has an empty index, which is the same "content ships in the build" answer `DotContent` gives.

`DotContentEntry` (`RefCounted`) carries `kind`, `id`, `key` (`<content_id>@<version>:<kind>/<id>`, unique in the process), `content_id`, `version`, `pack_title`, `name`, `category`, `tags`, `meta`, `source` (`&"subscription"`, `&"server"`, `&"game"`), `sessions` (a set), `path(field) -> String` (the field resolved onto the mount prefix, `""` when absent) and `raw` (the entry dictionary as published). Consumers read typed fields and `path("scene")`; nobody joins a prefix by hand.

### Session tags

Two tags, `DotContentIndex.SESSION_SOLO` (`&"solo"`) and `SESSION_ONLINE` (`&"online"`). Every pack in the index carries the set of sessions it was mounted for, and the index has one current session, set by the host (the shell, a dedicated server, a game run from its repository):

- `entries(kind)` returns the entries of packs tagged with the **current** session and nothing else. A consumer that wants another session asks for it by name, and only tests and `describe_lines()` do.
- A subscription pack is tagged `solo` and never anything else.
- A pack mounted for an online session (the server's game, its map packs, the content a server names) is tagged `online`. A pack mounted in solo that a server then requires at the **same id and version** is not downloaded or mounted again: `tag_pack` adds `online` to it, and that is the whole of the reuse.
- A dedicated server's index is `online` from boot. A game run from its own repository with no shell is `solo`.
- `session_changed` fires on every change; a catalogue that follows the index rebuilds its delivered rows from `entries()` then. Nothing is removed at runtime, because nothing can be unmounted: entries outside the current session are invisible, not gone.

### Registering on mount

`DotCloudClient` calls `DotContentIndex.shared().add_pack(...)` after every successful mount whose manifest carries `provides`, with the session it was mounted for. `ensure()` and `acquire()` keep their signatures and tag with `DotCloudClient.session_tag` (default `&"online"`; the shell sets it). The Workshop mounts through `ensure_for_session(content_id, version, session, source, options) -> DotResult`, the one call that passes the tag and the mount options below explicitly. A manifest with no `provides` registers nothing: old packs keep working exactly as they do.

**A subscription mount never re-points a UID the process already knows.** `DotCloudMounter._register_uids` calls `ResourceUID.set_id` for an id the host already has, which is right for a second version of the same pack and wrong for anybody else's: a subscription pack shipping a resource under the UID of the game's own texture would redirect the game's references to its copy, in solo and in every later online session of the process. `ensure_for_session` with `source = &"subscription"` passes `uid_policy = "add_only"`: an id already registered to a path outside this content id's own mounts is skipped and counted (`uids_skipped=N` in the mount line).

## The sync client

`addons/dot_cloud/workshop/`. `DotCloudWorkshop` is a `Node` the host places beside its `DotCloudClient` (found through `DotContent.SERVICE`); it registers as `dot_workshop` in `_ready`. Configuration is a `DotCloudWorkshopConfig` (`DotConfig`, layered like every other):

| Key | Default | Meaning |
| --- | --- | --- |
| `workshop_enabled` | `true` | Off: `sync()` succeeds with nothing, and the panel says the Workshop is off on this build |
| `workshop_backbone_url` | `""` | The site origin; the shell passes its dot-auth `backbone_url`, never anything from a page |
| `workshop_script_packs` | `"approved"` | `never`, `approved`, `any`. See [script packs](#script-packs) |
| `workshop_key_ids` | `["tmc"]` | The `key_id`s a subscription manifest must be signed with. A key trusted for a server's content is not thereby trusted for a stranger's subscription |
| `workshop_metered` | `"ask"` | `ask`, `allow`, `never`: what to do on a metered connection |
| `workshop_ask_over_bytes` | 52428800 | On `ask`, the download size above which the player is asked even when the connection is not known to be metered |
| `workshop_timeout_sec` | 10 | The list request's timeout; past it, the cached list is used |
| `workshop_max_packs` | 200 | The most packs one launch will mount |

The host sets two callables: `token_fn() -> String` (the signed-in player's bearer, `""` for a guest) and `ask_fn(summary: Dictionary) -> bool` (awaitable; the shell shows "Download 120 MB of subscribed content?" and returns the answer; unset means "no").

```gdscript
signal progress(done: int, total: int, bytes_done: int, bytes_total: int, current: String)
signal pack_failed(content_id: String, version: String, error: DotError)
signal synced(summary: Dictionary)

func sync(game_content_id: String) -> DotResult      # value: the summary below
func set_scope(subscription_id: String, on: bool) -> DotResult      # this game only
func set_all_games(subscription_id: String, on: bool) -> DotResult  # CODE_FORBIDDEN with a game-bound token
func last_list() -> DotCloudWorkshopList
func describe() -> Dictionary
func describe_lines() -> PackedStringArray
```

`CHANNEL` is `dot.cloud.workshop`. The summary is `{guest, offline, from_cache, revision, mounted: [{content_id, version}], skipped: [{content_id, version, reason}], failed: [{content_id, version, code, message}]}`; `reason` is one of `device_off`, `metered`, `script_policy`, `quota`, `too_many`, `incompatible`.

### What `sync()` does

1. **Refuse online.** A registered `dot_client_link` or a current session of `online` fails with `CODE_FORBIDDEN`. This is the second lock; the shell never calls it there in the first place.
2. **Guest.** `token_fn` returns `""`: success with `guest: true` and nothing mounted. The panel says "Sign in to use your subscriptions", and nothing is read from the cache, because a cached list belongs to the account that fetched it.
3. **Fetch.** `GET {backbone}/api/app/v1/workshop?game=<id>&since=<revision>&platform=<web|desktop|mobile>` with the bearer. `unchanged: true` keeps the cached list; otherwise the response replaces it (it is always the complete list for that game, so there is nothing to merge). `removed` entries are dropped from the cache and logged at DEBUG with their reason.
4. **Offline.** A network failure, a timeout or a 5xx uses the cached list (`offline: true`, `from_cache: true`) and logs at INFO. A 401 drops the cache for that account and behaves as a guest. A cached list is keyed by the account id `/me` returned with it, and is ignored for any other account.
5. **Device overrides.** `DotCloudWorkshopDevice` removes what this device has turned off (`skipped: device_off`).
6. **Policy.** A pack whose `runs_code` is true is skipped unless the policy admits it (`script_policy`).
7. **Size.** The total of the remaining packs' `bytes` that are not already in the store is checked against `DotCloudStore`'s limit (the browser's quota estimate on the web; `mobile_cache_bytes` on a phone): what does not fit is skipped from the end of the list (`quota`), never evicting the game's own content to make room. On a metered connection (see below) or over `workshop_ask_over_bytes`, `ask_fn` is awaited once for the whole set.
8. **Mount.** Each pack through `ensure_for_session(id, version, &"solo", &"subscription", {uid_policy: "add_only", allow_root: false})`, in list order, one at a time so `progress` is honest and one large pack cannot starve the rest. The manifest must verify against `trusted_keys` **and** be signed by a key in `workshop_key_ids`; its own id and version must match the list's; its `requires.json` must pass. Between download and mount, `DotCloudScriptScan` re-runs over the stored files, and a pack whose files run code when its manifest says they do not is refused as `CODE_FORBIDDEN`.
9. **One pack never blocks the game.** Every failure is logged once at WARN with the pack, the code and the message, emitted as `pack_failed`, added to `failed`, and the loop moves on. `sync()` itself fails only for a programmer error (no cloud client, an empty game id); every condition a player can cause is a successful summary.

On the web, the cached list and the device file are written through `DotPaths` atomically and followed by `DotWeb.sync_filesystem()`.

### The cache and the device file

- `user://dot_cloud/workshop/<game slug>.json`: `{account, revision, fetched_at, response}`, the last list for that game. The site owns it; the device never edits it.
- `user://dot_cloud/workshop/device.json`: `{off: ["<content_id>"], metered: "ask|allow|never"}`, this device's overrides. **Overrides stay on the device**: "off on this phone" is not a subscription change and never reaches the site. Anything that should follow the player to another device is a scope change and goes through `set_scope` / `set_all_games`.

### Metered connections

There is no engine API for it. `DotCloudWorkshop.is_metered()` is true when the browser reports `navigator.connection.saveData` or a `type` of `cellular`, read through `DotWeb`, or when `DotPlatform.is_mobile()` and nothing says otherwise. A platform that later exposes a real answer replaces that one method.

## The solo launch flow

The shell (dot-server-deploy's `TmcSoloSession`), for every solo start: web `--solo`, desktop, and the app's Play solo.

1. Sign in (`try_web_handoff()` on the web, the native sign-in on desktop). The web handoff yields a game-bound token, which is enough to read and toggle this game's list.
2. `DotContentIndex.shared().set_session(&"solo")`, `cloud.session_tag = &"solo"`.
3. Fetch and mount the game pack and `client/solo.json`'s map packs, as now.
4. If the game's `provides.accepts` is absent, stop here: the game takes no subscriptions and the panel says so.
5. `await workshop.sync(game_id)` behind the loading screen, its `progress` driving the bar ("Subscribed content 3/7, Utopia surf maps").
6. Instantiate the game's `client_scene`. Its catalogues follow the index and already see every entry.

The in-shell Subscriptions panel (`TmcWorkshopPanel`) lists the game's items from `last_list()` with their state (on, off here, off on this device, skipped and why), a per-game toggle (`set_scope`), an all-games toggle (`set_all_games`; with a game-bound token it is replaced by "Change for every game on the site", which opens the asset page), a device toggle, and "Open on the site". A change made in the panel applies at the next launch, because a mounted pack cannot be taken back; the panel says so.

## Online isolation

- **A subscription is never mounted for an online session.** The shell does not call `sync()` on a join, and `sync()` refuses one.
- **A consumer in an online session never sees a solo entry.** The index's session is `online` and `entries()` filters by it.
- **A server-required pack is fetched by the join as it always was.** If the same id and version is already mounted or stored, it is reused and tagged `online`; no other relationship between a subscription and a server's content exists. A different version of the same pack is a different mount prefix and both coexist.
- **Solo, then online, in one process.** Leaving solo frees the game's tree, which frees every node a pack's content made. The pack files stay mounted (they cannot be unmounted) and their entries are invisible under `online`. UIDs were never re-pointed (`add_only`), so nothing the server's game loads resolves into a subscription pack.
- **But code stays resident.** A script pack's static variables, signal connections to static buses and anything it registered survive the tree, and a resident script in an online session is a cheat engine waiting for a server. So **if any `runs_code` subscription pack was mounted in this process, an online join restarts the process first**: a page reload carrying the join on the web, a relaunch on desktop, through the same machinery as an addon overlay (`DotCloudAddonSet.persisted` before a browser reload). Data-only packs need no restart. `DotCloudWorkshop.requires_restart_before_online()` is the question the shell asks.
- **Addon overlays (kind `addon`) are never taken from a subscription.** An overlay mounts at the root, adds class names and replaces the build's code for the whole process; that is a decision for a server's announced addon set, never a player's subscription list. `ensure_for_session` with `allow_root: false` refuses one as `CODE_FORBIDDEN`.

## Script packs

**Proposed default, Christian to confirm:** a pack that runs code (`runs_code`) is offered and mounted only when it is signed by the site and the site's reviewers approved that version (the site's pack approval queue; website-city's `docs/workshop.md` has the record). The asset page and the panel show "Runs code" on it. The device setting `workshop_script_packs` is `approved` by default; `never` turns code packs off on that device; `any` (unapproved code, still site-signed) is for a developer testing their own pack and is not offered in the shell's settings. A pack that does not run code needs no review beyond whatever the game's own approval policy asks.

Changing the default is one value here (`workshop_script_packs`) and one rule on the site (whether an unapproved `runsCode` version is listed).

## Collections

**Proposed default, Christian to confirm:** a site collection is the Workshop's collection. Subscribing to one subscribes to its packs with the scope chosen for the collection, and the client sees only the resulting packs (each item says which collection it came through). Nothing here depends on the answer; it is the site's.

## Testing

- **dot-core**: a selftest for `DotContentIndex`: two packs, two sessions, `tag_pack` reuse, `session_changed`, unknown kinds kept and offered to nobody.
- **dot-cloud**: `examples/workshop_demo.tscn` publishes a fixture pack with a map, a weapon and a prop, mounts it as `solo`, and checks the index; switches to `online` and checks nothing is visible; mounts a pack whose files carry a script its manifest did not declare and requires the refusal; mounts a pack whose resource reuses a host UID and requires it skipped. A fake backbone (`examples/workshop_backbone.gd`, a local HTTP server like `http_test_server.gd`) serves first sync, an unchanged delta, a `removed` entry, a timeout (cached list used), a 401 (guest), and one broken pack among three (the other two mount).
- **dot-server-deploy**: a solo launch with a subscribed fixture map pack shows it in the game's map menu, then an online join of the same game in the same process shows none of it. Rendered and looked at.
