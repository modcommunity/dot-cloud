# Server auto-update

`DotCloudAutoUpdate` (`addons/dot_cloud/server/`) keeps a dedicated server on the newest published version of the packs it runs. It is on by default. Clients are never touched, and in a browser (`DotPlatform.is_web()`, or any build that cannot listen) it does nothing.

Every game gets it without code of its own: dot-game's `DotGameModule` starts one per headless server process the first time a game module loads (`DotGameModule.start_auto_update`), loads this script by path (dot-cloud stays optional), parents it to the `DotServer` so a game change keeps it, and registers it as `dot_cloud_autoupdate`. A host that builds its own sets the callables below and adds the node itself; `start_auto_update` then finds it in the registry and adds no second one.

## What it checks

`watch_fn` returns the packs this process runs as `{id, version}`. dot-game's returns, for every delivered game in the server's `DotGameManager`, the game's own pack and every pack in `dependencies`, `server_dependencies` and `maps`. A game built into the binary contributes nothing, so a game repository's own `game.sh server` watches nothing and never restarts.

Each check asks `latest_fn(id)`. The default reads `<base>/<id>/latest.json` from the registered `DotCloudClient`'s HTTP bases (the same pointer a publish writes and dot-server-deploy's installer reads; `moved_to` is followed one hop), then fetches that version's manifest through `DotCloudClient.resolve_manifest`, which verifies it against the client's trusted keys exactly as a client download would. An unsigned manifest is refused. A server with no HTTP bases (content from local directories only) has nothing to ask and stays quiet.

## Applying an update is a restart

A mounted resource pack can never be unmounted, and packs mount at `res://dot_cloud/<id>/<version>/`, so a new version cannot replace the old one in a running process. The update is applied by exiting and starting again: the start installs the newest version (dot-server-deploy's `./server` runs `install-games` before the engine, which resolves every unpinned pack to `latest.json`).

**The contract:** the process exits with `restart_exit_code`, **75** by default (EX_TEMPFAIL), after `DotServer.shutdown()` has told every player why. Whatever supervises the process restarts it on that code:

| Supervisor | Honours 75 |
| --- | --- |
| systemd (dot-server-deploy's `deploy/install-systemd.sh`) | `Restart=on-failure` plus `RestartForceExitStatus=75` |
| docker compose | `restart: unless-stopped`; the entrypoint returns the server's status. A bare `docker run` needs `--restart unless-stopped` |
| the Pterodactyl egg | the panel's crash detection restarts a server that exits on its own (it skips a second crash within 60 s, which a restart for an update never is) |
| a terminal | nothing restarts it; run under a supervisor or set `enabled: false` |

`restart_fn` replaces the exit for a host with a restart mechanism of its own.

**A restart that did not install the update is not repeated.** Before exiting the updater records the version it restarted for in `state_path` (`user://dot_cloud/autoupdate_state.json`). If the next process still runs the old version while `latest.json` names the recorded one, the pack is pinned (`owner/name@1.2.0` in the games list), `TMC_NO_INSTALL` is set, or the install failed: one WARN, and no restart for that version again. A newer version is a new update. `ignore` skips ids outright.

## When it restarts

Once an update is found (INFO `update found`):

1. **Nobody connected** (`players_fn` returns 0; dot-game counts every session, including players still loading): restart at once, with no warning.
2. **Players present, `when_empty` on** (the default): keep waiting, re-reading the player count every frame, and restart the moment it is empty. With `max_wait` above 0, once that many seconds have passed since the update was found, start the warning countdown anyway. `max_wait: 0` never forces: the server restarts only when empty.
3. **Players present, `when_empty` off**: start the countdown at once.
4. **The countdown**: one warning at `warn_seconds`, then one at each `warn_steps` value below it, sent through `warn_fn` (dot-game: `DotServer.broadcast_message`, a system chat line) and logged at INFO. At 0 it restarts. If the server empties during the countdown it restarts then. `warn_seconds: 0` restarts without a countdown.

Turning `enabled` off drops a pending update.

## Configuration

`DotCloudAutoUpdateConfig`, layered like every `DotConfig`: exported defaults < `autoupdate.yml` < environment < command line, and the cvars for a running server.

The file follows the family's addon layout (`DotAddonConfig.file_layers("dot-cloud", "autoupdate.yml")`): `cfg/addons/dot_cloud/autoupdate.yml`, the game's `cfg/game/<game>/dot_cloud/`, then the operator's `cfg/server/addons/dot_cloud/autoupdate.yml`, which is where a box sets its own. Environment is `DOT_CLOUD_AUTOUPDATE_<KEY>`, command line `--autoupdate-<key>=value`.

| Key | Default | Cvar | Meaning |
| --- | --- | --- | --- |
| `enabled` | `true` | `sv_autoupdate` | master switch |
| `check_interval` | `600` | `sv_autoupdate_check_interval` | seconds between checks (at least 10); the first is one interval after start |
| `when_empty` | `true` | `sv_autoupdate_when_empty` | restart only when nobody is connected (or after `max_wait`) |
| `max_wait` | `3600` | `sv_autoupdate_max_wait_seconds` | with `when_empty`, seconds after which it warns and restarts anyway; `0` waits for empty forever |
| `warn_seconds` | `300` | `sv_autoupdate_warn_seconds` | the countdown players see |
| `warn_steps` | `[300, 60, 10, 5]` | `sv_autoupdate_warn_steps` (`300,60,10,5`) | seconds left at which the warning repeats |
| `message` | `Server restarting in {seconds}s to update to {version}.` | `sv_autoupdate_message` | `{seconds}`, `{version}`, `{content}` filled in |
| `ignore` | `[]` | | content ids never checked |
| `restart_exit_code` | `75` | | the exit code the supervisor restarts on |
| `state_path` | `user://dot_cloud/autoupdate_state.json` | | the restart record |

`max_wait` defaults to an hour rather than 0: a server that is never empty would otherwise never update, and an hour plus a five-minute warning is a rare, announced interruption. Operators who want empty-only restarts set it to 0.

## Logging

Channel `cloud.autoupdate`. INFO: update found, waiting for empty, each warning, the restart, running the updated version. WARN: a check that could not reach the origin or verify a manifest (once per run of failures, DEBUG after), a refused configuration, a restart that did not install its update. `describe()` reports the state, settings, pending updates, the next check and the last one.

## Tests

`examples/auto_update_demo.tscn`: a fake clock, a fake origin and a fake player count. Update while empty restarts at once with no warning; players present wait for empty; the cap warns at every step then restarts; a disabled cap never restarts while occupied; `when_empty` off counts down; disabled never checks; the restart record stops a loop; file < environment layering; the cvars; `latest.json` parsing.
