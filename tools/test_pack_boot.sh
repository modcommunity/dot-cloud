#!/bin/bash
# Regression test for the delivered-pack boot gate, on the pack that caused it: game-hungario 0.1.19 as published to the
# prod content origin. On a host at dot-server-deploy's addons.lock (dot-net v0.1.36 or later types identity as Node) its
# hungry_net_bridge.gd no longer compiles ("Cannot infer the type of "net_id""), _make_bridge hands back null and a
# server logs only "A game has to supply the bridge between itself and the netcode." The gate must refuse it and name the
# bridge and the parse error; a published version with the fix (--good, default the dev origin's latest) must pass.
#   tools/test_pack_boot.sh [HOST_LOCK] [--good ORIGIN ID VERSION]
# HOST_LOCK defaults to ../dot-server-deploy/addons.lock. Needs the network (it fetches both packs).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$HERE/../dot-server-deploy/addons.lock"
case "${1:-}" in --*|"") ;; *) LOCK="$1"; shift ;; esac
GOOD_ORIGIN="https://tmcdevgames.net/content"; GOOD_ID="gamemann/game-hungario"; GOOD_VER=""
if [ "${1:-}" = --good ]; then GOOD_ORIGIN="${2:?}"; GOOD_ID="${3:?}"; GOOD_VER="${4:-}"; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
ok() { echo "  ok   $1"; }

python3 -I "$HERE/tools/pack_fetch.py" https://content.gamespice.net/content gamemann/game-hungario "$TMP/bad" --version 0.1.19 >/dev/null \
    || { echo "test_pack_boot: could not fetch game-hungario 0.1.19" >&2; exit 2; }
bash "$HERE/tools/pack_boot_test.sh" "$TMP/bad" "$LOCK" >"$TMP/bad.log" 2>&1
rc=$?
[ $rc -eq 1 ] && ok "0.1.19 is refused" || fail "0.1.19 was not refused (exit $rc)"
grep -q '^pack_boot: FAIL .*hungry_net_bridge.gd does not compile .*hungry_net_bridge.gd:[0-9][0-9]*: Parse Error: Cannot infer the type of "net_id"' "$TMP/bad.log" \
    && ok "the refusal names hungry_net_bridge.gd with its parse error and line" || fail "no FAIL line names hungry_net_bridge.gd with its parse error and line"
grep -q '^pack_boot: FAIL game.yml module (.*): _make_bridge() hands back no bridge\|^pack_boot: FAIL game.yml module (.*) does not \(load\|instantiate\)' "$TMP/bad.log" \
    && ok "the refusal says the module would not start" || fail "the refusal does not say the module would not start"

GARGS=(); [ -n "$GOOD_VER" ] && GARGS=(--version "$GOOD_VER")
gv="$(python3 -I "$HERE/tools/pack_fetch.py" "$GOOD_ORIGIN" "$GOOD_ID" "$TMP/good" "${GARGS[@]}" | tail -1)" \
    || { echo "test_pack_boot: could not fetch $GOOD_ID from $GOOD_ORIGIN" >&2; exit 2; }
bash "$HERE/tools/pack_boot_test.sh" "$TMP/good" "$LOCK" >"$TMP/good.log" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "$GOOD_ID $gv boots" || { fail "$GOOD_ID $gv did not boot (exit $rc)"; tail -15 "$TMP/good.log"; }
grep -q 'the module makes its bridge' "$TMP/good.log" && ok "$gv makes its bridge" || fail "$gv: the probe never made the bridge"

# No engine is "could not judge" (2), never a verdict on the pack (1): a sweep must not report a good pack as broken.
GODOT=/nonexistent/godot bash "$HERE/tools/pack_boot_test.sh" "$TMP/good" "$LOCK" >"$TMP/noengine.log" 2>&1
rc=$?
[ $rc -eq 2 ] && ok "no engine is exit 2, not a refusal" || fail "no engine gave exit $rc (want 2)"

[ $fails -gt 0 ] && { echo "--- 0.1.19 log"; cat "$TMP/bad.log"; }
echo "test_pack_boot: $fails failed"
exit $(( fails > 0 ))
