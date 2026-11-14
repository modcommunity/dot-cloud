# dot-cloud

Runtime content delivery for Godot 4.7+. A server hands a client a manifest. The client downloads what it is missing, verifies it and mounts it, so a game does not have to bake all its content into the download. It works on Windows, macOS, Linux, Android, iOS and in the browser. Part of the [dot-*](https://github.com/modcommunity) family, alongside [dot-core](https://github.com/modcommunity/dot-core), [dot-server](https://github.com/modcommunity/dot-server) and [dot-auth](https://github.com/modcommunity/dot-auth).

## Install

1. Copy `addons/dot_core/` and `addons/dot_cloud/` into your project.
2. Enable both in *Project > Project Settings > Plugins*.

## Use

```gdscript
var cloud := DotCloudClient.new()
add_child(cloud)

cloud.config = DotCloudConfig.new()
cloud.config.trusted_keys = {"default": PUBLIC_KEY_PEM}

await cloud.start()

cloud.phase_changed.connect(func(_p, text): status_label.text = text)
cloud.progress_changed.connect(func(p): bar.value = p.fraction * 100.0)

var res := await cloud.acquire("https://cdn.example.com/dm_arena/manifest.json")
if res.ok:
    get_tree().change_scene_to_file(res.value)
```

## Publish content

The headless CLI makes a key and publishes a directory:

```bash
godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    keygen --private keys/content.key --public keys/content.pub

godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    publish --source content/dm_arena --out dist/dm_arena \
    --id dm_arena --version 1.2.0 --entry arena.tscn --key keys/content.key
```

The output is a static directory with a `manifest.json` and an `objects/` tree. Any web server or CDN can host it with no configuration.

To publish through the site to the CDN and pin the result in `content.lock.json`, use `tools/publish_pack.sh` (`tools/publish_pack.ps1` on Windows). The token goes in `$DOT_CLI_TOKEN`, never an argument.

```bash
tools/publish_pack.sh --source content/dm_arena --id dm_arena --version 1.2.0 --lock content.lock.json
tools/publish_pack.sh --source content/dm_arena --id dm_arena --bump patch   # only changed files travel
tools/publish_pack.sh versions --id dm_arena                                 # what the CDN holds
```

Every option and a worked example are in [docs/cdn-publish.md](docs/cdn-publish.md).

## What it does

| Feature | What it does |
| --- | --- |
| Content-addressed cache | Files are stored under their SHA-256. Two games sharing an asset download it once, and a republish downloads only what changed. |
| Signed manifests | A manifest decides what is mounted, and Godot packs can contain scripts, so it is signed. Verification is on by default. |
| Downloads | Parallel and resumable, with mirror failover, HTTP range resume, a circuit breaker per source, bandwidth throttling, progress and ETA. |
| Sources | HTTP or CDN, a local directory (development, LAN, bundled content), and in-band over the game connection for servers with no web host. |
| Namespaced mounting | Content mounts at `res://<root>/<content_id>/<version>/`, which is what makes swapping games at runtime work. |
| Server auto-update | A dedicated server checks for newer signed versions of the packs it runs and restarts to install them. It restarts at once when empty, otherwise after waiting for empty or a countdown that players see. On by default (`enabled` in its config). See [docs/auto-update.md](docs/auto-update.md). |
| Quota awareness | Browser storage estimates, mobile ceilings, and least-recently-used eviction that never evicts content in use. |

## Two things to know first

**Godot cannot unmount a resource pack.** The API does not exist. dot-cloud gives every content set its own versioned path, so nothing ever needs replacing. "Unloading" means dropping references, not freeing the file table. See [docs/mounting.md](docs/mounting.md#a-mounted-resource-pack-can-never-be-unmounted).

**Unsigned content is remote code execution.** `require_signed_manifests` is on by default, and the config refuses to validate without a trusted key. You can turn it off for LAN or first-party servers; it warns every time. See [docs/trust.md](docs/trust.md).

## More documentation

The [docs index](docs/README.md) lists everything. Start with [docs/client.md](docs/client.md), [docs/sources.md](docs/sources.md), [docs/store.md](docs/store.md) and [docs/publishing.md](docs/publishing.md).

## Test

```bash
godot --headless --path . --import
godot --headless --path . res://examples/sync_demo.tscn
godot --headless --path . res://examples/http_demo.tscn
godot --headless --path . res://examples/store_demo.tscn
```

| Demo | What it checks |
| --- | --- |
| `sync_demo` | Generates a keypair, publishes a small content set, syncs and mounts it, reads a file back, then releases and re-acquires it. |
| `http_demo` | Serves the published directory from a small GDScript test server: mirror failover, URL layout, range resume, a host that refuses ranges, and a mirror serving corrupt bytes. |
| `store_demo` | Drives the cache alone: least-recently-used eviction, references keeping mounted content, a cache that cannot shrink saying so, and index rebuild after an unclean shutdown. |

All three run offline and headless and exit non-zero on any failure.

## Status

Built and maintained with Claude Code. The test suites pass, but little of this has been in front of real players yet. Please report rough edges by opening an issue.

## Licence

MIT. See [LICENSE](LICENSE). Only the TMC back-end web infrastructure is not open source.
