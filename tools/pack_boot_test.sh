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
# GODOT names the engine (as for publish_pack.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(cd "${1:?usage: tools/pack_boot_test.sh OUT_DIR HOST_LOCK}" && pwd)"
LOCK="$(cd "$(dirname "${2:?usage: tools/pack_boot_test.sh OUT_DIR HOST_LOCK}")" && pwd -P)/$(basename "$2")"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || ! [ -x "$HOME/.local/bin/godot" ] || GODOT="$HOME/.local/bin/godot"
DEPLOY="$(dirname "$LOCK")"
SIB="$(cd "$DEPLOY/.." && pwd)"
[ -f "$DEPLOY/project.godot" ] || { echo "pack_boot: $DEPLOY is not a dot-server-deploy checkout" >&2; exit 2; }
KEY="$( { git -C "$DEPLOY" rev-parse HEAD; sha256sum < "$LOCK"; } | sha256sum | cut -c1-16)"
CACHE="${GS_PACK_BOOT_CACHE:-$HOME/.cache/pack-boot}"
HOST="$CACHE/$KEY"
if [ ! -f "$HOST/.ready" ]; then
    echo "pack_boot: building the host at the addons.lock tags in $HOST" >&2
    mkdir -p "$CACHE"
    # A private build dir: two publishes may build the same host at once.
    PART="$(mktemp -d "$HOST.part.XXXXXX")"
    git -C "$DEPLOY" archive HEAD | tar -x -C "$PART"
    cp "$LOCK" "$PART/addons.lock"
    rm -rf "$PART/addons"
    TMC_SIBLINGS="$SIB" bash "$PART/tools/check-pinned.sh" "$PART/addons" >&2 \
        || { rm -rf "$PART"; echo "pack_boot: could not build addons/ at the lock's tags (fetch the sibling repos' tags)" >&2; exit 2; }
    timeout 1800 "$GODOT" --headless --path "$PART" --import >"$PART/import.log" 2>&1 || true
    [ -f "$PART/.godot/global_script_class_cache.cfg" ] \
        || { tail -20 "$PART/import.log" >&2; rm -rf "$PART"; echo "pack_boot: the host did not import" >&2; exit 2; }
    touch "$PART/.ready"
    # The first finished build wins; a later one is dropped.
    [ -f "$HOST/.ready" ] || rm -rf "$HOST"
    mv -T "$PART" "$HOST" 2>/dev/null || rm -rf "$PART"
fi
mkdir -p "$HOST/pack_boot"
cp "$HERE/tools/pack_boot_probe.gd" "$HOST/pack_boot/probe.gd"
printf '[gd_scene format=3]\n\n[ext_resource type="Script" path="res://pack_boot/probe.gd" id="1"]\n\n[node name="PackBoot" type="Node"]\nscript = ExtResource("1")\n' > "$HOST/pack_boot/probe.tscn"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
set +e
timeout 1200 "$GODOT" --headless --path "$HOST" res://pack_boot/probe.tscn -- "$OUT" >"$LOG" 2>&1
rc=$?
set -e
grep -E "^pack_boot:|SCRIPT ERROR|Parse Error|Compile Error|Failed to load|^ +at: " "$LOG" | grep -v "^pack_boot: game.yml .* loads" >&2 || true
if [ $rc -ne 0 ] || ! grep -q "^pack_boot: .* 0 failure(s)" "$LOG"; then
    echo "pack_boot: the pack does not boot mounted on the pinned host (exit $rc); not publishing" >&2
    exit 1
fi
echo "pack_boot: the pack boots mounted on the pinned host" >&2
