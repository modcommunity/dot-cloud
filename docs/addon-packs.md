# Addons as packs: a newer addon without a new build

**An addon release should not need a new client build.** Every addon tag is published by the site as a signed pack (`modcommunity/dot-ui@0.1.5`, the addon's directory at the pack root). A server announces the addon versions it runs (dot-server's `addon_set`, in the signon challenge); a client whose build is older fetches those packs, assembles ONE overlay pack that lays them over its own `res://addons/<dir>/`, writes a plan, and restarts: a page reload in a browser, a relaunch on desktop. `addon_set/dot_cloud_addon_set.gd` decides and builds; `boot/dot_cloud_boot.gd` mounts.

## Three engine facts

Each was measured on an exported build, and each is silent when ignored:

- **A script compiled in this process keeps its code.** Mount a newer file over it and the old code runs on: `load`, `CACHE_MODE_REPLACE` and `Script.reload()` all hand back the old one. So the overlay is mounted by a main scene that names **no** addon class (`dot_cloud_boot.gd`, not even dot-cloud's own; its paths and plan fields are written out again on purpose), before anything else loads. That is why this is a restart and never an in-game swap.
- **An export stores `x.gd` as `x.gdc` behind `x.gd.remap`, and `x.tscn` as a binary `.scn` behind `x.tscn.remap`.** The loader follows the build's remap to the build's bytes, so a newer `x.gd` mounted beside it is never read. Every resource in the overlay gets a `.remap` pointing at itself (`REMAPPED`). Without them: old code, new class list, no error.
- **`ProjectSettings.load_resource_pack` re-reads `res://.godot/global_script_class_cache.cfg`.** A pack mounted at the root that carries that file can ADD `class_name`s. The file is one list for the whole project, so the overlay carries the build's own list (saved by the boot before any overlay replaced it, `shell_classes.cfg`) with the overlaid addons' entries swapped in. `DotCloudScriptClass` writes those entries from each script's header, and `addon_set_demo` checks them field by field against the list the editor wrote. A game pack at a mount prefix carries no class list, which is why games still reference their files by path ([mounting.md](mounting.md#a-pack-says-which-addon-api-it-needs)).

## What keeps it from doing harm

- **Only upward**: a version not newer than the build's (`res://addons.lock`, which every export carries) or than the running overlay's is never taken, so a server cannot pin its players to an old addon.
- **Only from `namespaces`**: an owner ending in `/`, or one exact id (`alice/x` does not admit `alice/x-evil`).
- **Only signed** (`resolve_manifest` verifies), only a repository that is the pack's own name, only into a directory that is one plain name, and only into a directory that either does not exist in the build or already holds the plugin script the pack's `plugin.cfg` names (`_is_that_addon`), so a list saying `dir: dot_ui` with the dot-net pack is refused before anything is written.
- **An overlay names the build it was made for** and is ignored by any other build.
- **Boot confirmation.** The plan says `booting` before the mount and the shell says `ok` with `confirm_boot()` once it has built itself; two starts that never arrived mark the overlay `failed` and the build comes up on its own addons (`failed_before` then stops the shell building that set again). In an exported build `confirm_boot()` also loads one script per overlaid addon (`probes`, its `_api.gd` when it has one) and requires its source text: a `.gdc` has none, so "the build's compiled copy is still the one running" is caught and the overlay turned off.

**The overlay is named by its contents** (every file's path and hash, plus the build), so the same set is the same file and is reused rather than rewritten. That is required: the file of that name may be mounted in this very process. An addon pack is downloaded with `download_manifest()` / `resolve_manifest()` and never also mounted at its own content prefix.

## In a browser

`user://` reaches IndexedDB only through `FS.syncfs`, and the engine **drops** a sync requested while one runs. dot-cloud asks after every object, so the request after the last write was routinely the one dropped, and a reload lost the plan and the overlay: a page that came back, saw the same newer addons, and reloaded again. The shell asks for the sync four times, 0.75 s apart, before it reloads, and counts restarts per server and set in `sessionStorage` (synchronous, survives a reload of the tab) so a loop stops at two.

## Testing

`examples/addon_set_demo.tscn` publishes `modcommunity/dot-probe@0.2.0` with a run key, builds the overlay through a real client, and starts this project again as separate processes through `addon_boot_probe.tscn` (a boot, a start whose two predecessors never arrived, an overlay for another build, no plan), reading back what each found (`addon_boot_check.gd`). It writes `res://addons.lock` for the run (gitignored). The end-to-end proof, an old exported shell meeting a newer server and relaunching onto site-signed addon packs, was done from dot-server-deploy.
