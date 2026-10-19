# Publishing

## The CLI

```bash
godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    keygen --private keys/content.key --public keys/content.pub

godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
    publish --source content/dm_arena --out dist/dm_arena \
    --id dm_arena --version 1.2.0 --entry arena.tscn \
    --key keys/content.key --mirror https://cdn.example.com/dm_arena
```

Output is a static directory (`manifest.json` + `objects/`) to drop behind any web server. Exit codes: 0 ok, 1 usage error, 2 operation failed, so CI can tell "called it wrong" from "content is bad".

The client-side pack is built at mount time by `PCKPacker`, not by the publisher: cached objects live at hash-named paths and must appear inside the pack at `res://<prefix>/<manifest path>`, which no export preset can express.

## An imported asset is not shippable as its source

A `.glb` or a `.png` is **not a loadable resource**. The editor imports it into `.godot/imported/` and the `.import` marker beside it redirects every load there; nothing imports at runtime, on any platform. A pack that ships the source bytes without the imported form ships an asset no `load()` can open, and says nothing, because the file is right there:

```
character-a.glb    exists=false  file=true   load=null
arena.tscn         exists=true   file=true   load=PackedScene
```

`file=true` is the trap. `include_imported` (on by default) ships the imported form and the markers, and `_is_text_resource` covers `.import` so the rewrite below moves the three absolute paths inside each marker (the imported resource, the source file, `dest_files`) onto the mount. The `.md5` companions stay behind: only the editor reads them.

**The source project has to have been imported first.** A repository that has never been opened has no `.godot/imported/`, and there is nothing to ship.

## The source of an imported asset stays behind

The reverse is also true: once the imported form ships, the source is bytes nothing opens. A load follows the marker, `ResourceLoader.exists` asks for the marker, and an exported build carries no sources at all, so a game that works exported works without them. They were about half of every game pack: the reference deathmatch shipped 3.5 MB of `.glb` and 0.5 MB of `.png` beside the `.scn` and `.ctex` it actually loaded (7.7 MB and 543 files became 3.6 MB and 412 files; the largest game, 21.9 MB, became 8.1 MB).

So `ship_import_sources` is off (API level 4): a file is left out when its marker named an output this pack ships. An asset imported as `keep` or `skip` has no output, its file is the asset, and it stays. The left-out path is still in the rewrite's map, so a scene naming `res://assets/crate.glb` is rebased onto the mount, where the marker that resolves it is. Content that reads its own files raw (`Image.load_from_file`, `GLTFDocument`) turns it on, or passes `--with-sources` to the CLI. A map loader that tries `ResourceLoader` first and falls back to the raw file (both BSP loaders do) is fine either way.

## A file that is not under the source: `extra_files`

`DotCloudPublisher.extra_files` maps a pack path to a file anywhere (`{"requires.json": "/tmp/build/requires.json"}`). It exists for a file a build step derives when the source is somebody's checkout: writing it into the tree for the length of a publish leaves an untracked file there whenever the run is killed. Each entry goes through the same path as an imported output (hashed, copied, listed, rewritten if it is a text resource), replaces a source file at the same pack path, and ignores the exclusions because it was named on purpose. A missing file or an unsafe pack path fails the publish, because a pack that ships without its derived file fails later on somebody else's machine. dot-server-deploy's packer adds its derived `requires.json` this way; before the hook it overrode the private `_imported_outputs_for`, which no subclass should touch. Added at dot-cloud API level 2 (`addons/dot_cloud/dot_cloud_api.gd`).

## A file only one side needs: `sides.json`

A game pack goes to its server and to every player, and some of it is only ever read by one of them: baked light a headless server never draws (a game's lightmaps were about 12 MB of its pack), or a server's own tables a client never runs. A `sides.json` at the source root says so, and the publisher writes each matched entry's `side` into the manifest (API level 8):

```json
{ "client": ["lightmaps/"], "server": ["server/*.json"] }
```

A pattern ending in `/` is a directory prefix; anything else is a `String.match` glob over the pack path, where `*` crosses `/`. An imported asset's `.import` marker and its relocated `_imported/` output take the side of the asset, so a rule written against the file a person sees covers what ships. `DotCloudPublisher.side_rules` (`{pattern: "client" | "server"}`) adds rules from code and merges with the file. Refused at publish, as `CODE_INVALID`: a pattern that matches nothing (a typo would otherwise ship the files to both sides and say nothing), a file two patterns put on different sides, an unknown key, a side on `requires.json` (both sides read it before mounting), and a server-only entry scene (a client loads it). The file itself ships, like `provides.json`, and goes to both sides.

**In the source, not in one packer's config**, because a game is packed by more than one tool: this CLI, dot-server-deploy's `./server pack --source`, and the site's release sync. The source tree is the one thing all of them read; a rule in one packer's descriptor would leave the other two shipping lightmaps to servers. The site's own manifest builder has to read the same file to tag what it publishes.

The tag is part of the signed payload; how a fetcher uses it, and why an older build is unaffected, is in [mounting.md](mounting.md#a-pack-can-leave-files-out-per-side).

## A scene's references move with the pack

Godot writes a scene's script and resource references as **absolute** `res://` paths, and a pack does not mount where its content was authored. A published scene naming `res://game/thing.gd`, mounted at `res://dot_cloud/<id>/<version>/`, mounts, loads, and fails only when something calls a method on a script that is not there. It is the same constraint `class_name` has ("the pack is data, the code ships in the build") by a second route, and why every game here uses relative preloads.

`DotCloudPublisher.rewrite_resource_paths` (on by default) rewrites `res://X` to `res://<mount_root>/<id>/<version>/X` inside `.tscn` and `.tres`, for every X **the pack contains**. A reference to `res://addons/dot_core/...` means the host build's copy and is left alone; so is one already namespaced, or republishing would bury the content a level deeper every time. The rewrite happens before hashing, so the manifest covers the bytes that will be mounted. A path already rewritten must not be rebased a second time by a game's own path helper (the form of this bug mg-smash-copter found).

**Binary `.scn` and `.res` cannot be rewritten this way** and are not attempted. Godot writes text by default and the family uses text everywhere, except for the case below.

## Binary imports are fixed at mount

An imported `.glb` becomes a binary `.scn` under `.godot/imported/`, and its reference to its own texture is a UID with the authored absolute path as the fallback. Mounted elsewhere, the UID is not registered and the path names the authoring project:

```
invalid UID: 'uid://reboanwombd2' - using text path instead:
    'res://assets/kenney/survival/Textures/colormap.png'
Resource file not found: res://assets/kenney/survival/Textures/colormap.png
```

Both lines are **warnings**: the pack verified, mounted and loaded, the meshes appeared, and the art did not. `ResourceUID` is writable at runtime and every `.import` marker names a UID and its file (already moved onto the mount), so `DotCloudMounter._register_uids` points each id at the mounted copy and the binary reference resolves untouched. "The art is white" and "the art is missing" are the same picture and different causes; the `uids=N` in the mount's log line tells them apart.

`examples/delivered_scene_demo.tscn` is the only suite here that publishes a scene **with a script**; every other publishes data.

## DotCloudRegistry is written and nothing calls it

`publish/dot_cloud_registry.gd` has a full class doc, a worked example, and **no consumer anywhere in the tree**, on purpose. It is the registry's half of a publish, against the backbone rather than the filesystem: `claim` reserves `<owner>/<name>@<version>` before the bytes move (hashing and uploading is minutes, and the version has to be ours for all of it), then `complete` or `fail`. The rules (one owner per namespace, one publish per version, a failed publish keeps its number) are enforced by the site, because a check that lives only in a publishing tool protects an honest publisher from an accident and nobody else.

Before anything calls it, the endpoint at `DEFAULT_PATH` has to exist on the website-city side and `./server pack` has to grow a token; until then a publish would fail against a 404. Its suite coverage is zero, and that gap is closed by the endpoint existing, not by a fixture.
