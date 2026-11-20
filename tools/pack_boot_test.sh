#!/bin/bash
# Mounted-pack boot test: mounts a pack (a publish dry-run's --out, or a published version fetched by tools/pack_fetch.py) in a
# host project built at the exact tags of dot-server-deploy's addons.lock, the way a server mounts it, and fails when a script
# does not compile there, game.yml's module or scenes do not load, the module will not make its netcode bridge, or
# requires.json names an addon or level the host lacks. tools/publish_pack.sh runs it before every upload of a game pack
# whose --host-addons is an addons.lock; dot-server-deploy's tools/published_packs_boot.sh runs it over every game's
# published versions against a candidate lock.
# Why: Airdrift and Playlot 0.1.33 and Zombie Zone 0.1.40 (stale trees, a renamed addon) booted nothing on servers, and
# Hungario 0.1.19, published without this gate, stopped compiling once the lock moved to dot-net v0.1.36 (identity typed Node).
#   tools/pack_boot_test.sh OUT_DIR HOST_LOCK     (HOST_LOCK: a dot-server-deploy checkout's addons.lock, or a candidate lock beside it)
# The host is built once per lock and dot-server-deploy commit under ${GS_PACK_BOOT_CACHE:-~/.cache/pack-boot}.
# GODOT names the engine (as for publish_pack.sh). Exit 0 boots, 1 does not boot, 2 could not judge (no engine, host or mount).
set -euo pipefail
# Anything that stops the script before the probe's verdict is "could not judge", never a refusal of the pack.
trap 'echo "pack_boot: the host could not be prepared (line $LINENO); the pack was not judged" >&2; exit 2' ERR
[ $# -eq 2 ] || { echo "usage: tools/pack_boot_test.sh OUT_DIR HOST_LOCK" >&2; exit 2; }
[ -f "$1/manifest.json" ] || { echo "pack_boot: no manifest.json in $1" >&2; exit 2; }
[ -f "$2" ] || { echo "pack_boot: no lock at $2" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(cd "$1" && pwd)"
LOCK="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
# An explicit GODOT is used as given (a missing one is exit 2); only an unset one falls back to ~/.local/bin/godot.
if [ -z "${GODOT+x}" ]; then
    GODOT=godot
    command -v godot >/dev/null 2>&1 || ! [ -x "$HOME/.local/bin/godot" ] || GODOT="$HOME/.local/bin/godot"
fi
# Exit 2 is "could not judge" (no engine, no host, the probe did not finish); 1 is only ever the probe's verdict on the pack.
command -v "$GODOT" >/dev/null 2>&1 || { echo "pack_boot: no engine at GODOT=$GODOT" >&2; exit 2; }
DEPLOY="$(dirname "$LOCK")"
SIB="$(cd "$DEPLOY/.." && pwd)"
[ -f "$DEPLOY/project.godot" ] || { echo "pack_boot: $DEPLOY is not a dot-server-deploy checkout" >&2; exit 2; }
KEY="$( { git -C "$DEPLOY" rev-parse HEAD; sha256sum < "$LOCK"; } | sha256sum | cut -c1-16)"
CACHE="${GS_PACK_BOOT_CACHE:-$HOME/.cache/pack-boot}"
HOST="$CACHE/$KEY"
if [ ! -f "$HOST/.ready" ]; then
    mkdir -p "$CACHE"
    # One build per host at a time: a second publish waits, then finds .ready. Only a host with .ready is ever probed,
    # so under the lock a host dir without it is a dead build and can go.
    exec 9>"$CACHE/$KEY.lock"
    flock 9
    if [ ! -f "$HOST/.ready" ]; then
        echo "pack_boot: building the host at the addons.lock tags in $HOST" >&2
        rm -rf "$HOST"
        PART="$(mktemp -d "$HOST.part.XXXXXX")"
        trap 'rm -rf "$PART"; echo "pack_boot: the host could not be built (line $LINENO); the pack was not judged" >&2; exit 2' ERR
        git -C "$DEPLOY" archive HEAD | tar -x -C "$PART"
        cp "$LOCK" "$PART/addons.lock"
        rm -rf "$PART/addons"
        TMC_SIBLINGS="$SIB" bash "$PART/tools/check-pinned.sh" "$PART/addons" >&2 \
            || { rm -rf "$PART"; echo "pack_boot: could not build addons/ at the lock's tags (fetch the sibling repos' tags)" >&2; exit 2; }
        timeout 1800 "$GODOT" --headless --path "$PART" --import >"$PART/import.log" 2>&1 || true
        [ -f "$PART/.godot/global_script_class_cache.cfg" ] \
            || { tail -20 "$PART/import.log" >&2; rm -rf "$PART"; echo "pack_boot: the host did not import" >&2; exit 2; }
        touch "$PART/.ready"
        mv -T "$PART" "$HOST"
        trap 'echo "pack_boot: the host could not be prepared (line $LINENO); the pack was not judged" >&2; exit 2' ERR
    fi
    flock -u 9
fi
# Each run has its own probe dir in the shared host: two publishes or a sweep at once never run each other's probe.
PD="$(mktemp -d "$HOST/pack_boot.XXXXXX")"; PR="res://$(basename "$PD")"
LOG="$(mktemp)"; trap 'rm -rf "$LOG" "$PD"' EXIT
cp "$HERE/tools/pack_boot_probe.gd" "$PD/probe.gd"
printf '[gd_scene format=3]\n\n[ext_resource type="Script" path="%s/probe.gd" id="1"]\n\n[node name="PackBoot" type="Node"]\nscript = ExtResource("1")\n' "$PR" > "$PD/probe.tscn"
# `|| rc=$?`: a non-zero probe is a result to read, not a setup error for the ERR trap (which set +e would not stop).
rc=0
timeout 1200 "$GODOT" --headless --path "$HOST" "$PR/probe.tscn" -- "$OUT" >"$LOG" 2>&1 || rc=$?
grep -E "^pack_boot:|SCRIPT ERROR|Parse Error|Compile Error|Failed to load|^ +at: " "$LOG" | grep -v "^pack_boot: game.yml .* loads" >&2 || true
if [ $rc -eq 0 ] && grep -qE "^pack_boot: [0-9]+ script\(s\) compiled, 0 failure\(s\)$" "$LOG"; then
    echo "pack_boot: the pack boots mounted on the pinned host" >&2
    exit 0
fi
# A refusal needs the probe's own verdict: it exited 1 after its summary line named the failures.
if [ $rc -eq 1 ] && grep -qE "^pack_boot: [0-9]+ script\(s\) compiled, [1-9][0-9]* failure\(s\)$" "$LOG"; then
    echo "pack_boot: the pack does not boot mounted on the pinned host; not publishing" >&2
    exit 1
fi
[ -s "$LOG" ] && tail -5 "$LOG" >&2
echo "pack_boot: the probe did not finish (exit $rc: a timeout, a crash, or the probe itself did not load); the pack was not judged" >&2
exit 2
