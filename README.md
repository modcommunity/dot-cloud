This is the **content delivery** asset for TMC's **Dot** collection. It is how a game gets its content to a player at runtime instead of baking all of it into the download.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Runtime Content Delivery
Runtime content delivery for Godot 4. A server hands a client a manifest; the
client downloads what it is missing, verifies it, and mounts it — on Windows,
macOS, Linux, Android, iOS and in the browser.

Part of the `dot-*` family alongside [dot-core](../dot-core),
[dot-server](../dot-server) and [dot-auth](../dot-auth).

## Install

Copy `addons/dot_core/` and `addons/dot_cloud/` into your project and enable both
in *Project → Project Settings → Plugins*. Requires Godot 4.4+.

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

Publish content with the headless CLI:

```bash
godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    keygen --private keys/content.key --public keys/content.pub

godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    publish --source content/dm_arena --out dist/dm_arena \
    --id dm_arena --version 1.2.0 --entry arena.tscn --key keys/content.key
```

The output is a static directory — `manifest.json` plus an `objects/` tree — that
any web server or CDN can host with no configuration.

## What it does

- **Content-addressed cache.** Files are stored under their SHA-256, so two games
  sharing an asset download it once and republishing re-downloads only what
  changed.
- **Signed manifests.** A manifest decides what gets mounted, and Godot packs can
  contain scripts — so it is signed, and verification is on by default.
- **Resumable parallel downloads.** Mirror failover, HTTP range resume, circuit
  breaking per source, bandwidth throttling, honest progress and ETA.
- **Three sources.** HTTP/CDN, a local directory (development, LAN, bundled
  content), and in-band over the game connection for servers with no web host.
- **Namespaced mounting.** Content mounts at
  `res://<root>/<content_id>/<version>/`, which is what makes swapping games at
  runtime work — see below.
- **Quota awareness.** Browser storage estimates, mobile-specific ceilings,
  least-recently-used eviction that never evicts content currently in use.

## Two things worth knowing before you build on it

**Godot cannot unmount a resource pack.** Not slowly, not with a workaround — the
API does not exist. dot-cloud handles this by giving every content set its own
versioned path so nothing ever needs replacing, and "unloading" means dropping
references rather than reclaiming the file table. See
[CLAUDE.md](CLAUDE.md#read-this-first-the-two-constraints-that-shaped-everything).

**Unsigned content is remote code execution.** `require_signed_manifests`
defaults to on and the config refuses to validate without a trusted key. You can
turn it off for LAN or first-party servers; it will warn every time.

## Try it

```bash
godot --headless --path . res://examples/sync_demo.tscn
godot --headless --path . res://examples/http_demo.tscn
godot --headless --path . res://examples/store_demo.tscn
```

The first generates a keypair, publishes a small content set, syncs it, mounts
it, reads a file back out of the mount, then releases and re-acquires it.

The second serves that published directory over HTTP — from a small test server
written in GDScript, so it still needs no network and nothing installed — and
drives a client through it: mirror failover, the content-addressed URL layout,
range resume, a host that refuses ranges, and a mirror serving corrupted bytes.

The third drives the cache on its own, with no network and no manifest: a full
cache evicting least-recently-used, references keeping mounted content out of
the eviction candidates, a cache that cannot shrink reporting so instead of
deleting content a player is reading, and the index being rebuilt from the
object directory after an unclean shutdown.

All three run offline and headless, and all three exit non-zero if a check
fails.

## Licence

MIT — see [LICENSE](LICENSE).
