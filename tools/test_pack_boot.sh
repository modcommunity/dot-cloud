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

# A game without netcode (no _net_config) keeps the inherited null bridge, and the host boots it: so must the gate.
python3 -I - "$TMP/good" "$TMP/nonet" <<'PY'
import hashlib, json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
shutil.copytree(src, dst)
m = json.load(open(os.path.join(dst, "manifest.json")))
def put(path, text):
    b = text.encode(); sha = hashlib.sha256(b).hexdigest()
    os.makedirs(os.path.join(dst, "objects", sha[:2]), exist_ok=True)
    open(os.path.join(dst, "objects", sha[:2], sha), "wb").write(b)
    m["files"] = [f for f in m["files"] if f["path"] != path] + [{"path": path, "sha256": sha, "size": len(b)}]
put("game/no_net_module.gd", "extends DotGameModule\n")
yml = next(f for f in m["files"] if f["path"] == "game.yml")
text = open(os.path.join(dst, "objects", yml["sha256"][:2], yml["sha256"])).read()
put("game.yml", "\n".join("module: game/no_net_module.gd" if l.startswith("module:") else l for l in text.split("\n")))
json.dump(m, open(os.path.join(dst, "manifest.json"), "w"))
PY
bash "$HERE/tools/pack_boot_test.sh" "$TMP/nonet" "$LOCK" >"$TMP/nonet.log" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "a module without netcode boots (no bridge asked for)" || { fail "a module without netcode was refused (exit $rc)"; grep '^pack_boot' "$TMP/nonet.log"; }

# A signed manifest (the envelope dot_cloud_envelope.gd writes: {"payload": base64url of the manifest}) is read through.
python3 -I - "$TMP/nonet" "$TMP/signed" <<'PY'
import base64, json, os, shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2])
p = os.path.join(sys.argv[2], "manifest.json")
raw = open(p, "rb").read()
json.dump({"payload": base64.urlsafe_b64encode(raw).decode().rstrip("="), "signatures": []}, open(p, "w"))
PY
bash "$HERE/tools/pack_boot_test.sh" "$TMP/signed" "$LOCK" >"$TMP/signed.log" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "a signed manifest envelope is unwrapped and boots" || { fail "a signed manifest gave exit $rc (want 0)"; grep '^pack_boot' "$TMP/signed.log"; }

# A script built into a scene (a .tscn sub_resource GDScript) is no file of its own; it must still compile.
python3 -I - "$TMP/nonet" "$TMP/builtin" <<'PY'
import hashlib, json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
shutil.copytree(src, dst)
m = json.load(open(os.path.join(dst, "manifest.json")))
b = ('[gd_scene load_steps=2 format=3]\n\n[sub_resource type="GDScript" id="GDScript_1"]\n'
     'script/source = "extends Node\n\nfunc f() -> int:\n\tvar n := undefined_thing\n\treturn n\n"\n\n'
     '[node name="Broken" type="Node"]\nscript = SubResource("GDScript_1")\n').encode()
sha = hashlib.sha256(b).hexdigest()
os.makedirs(os.path.join(dst, "objects", sha[:2]), exist_ok=True)
open(os.path.join(dst, "objects", sha[:2], sha), "wb").write(b)
m["files"].append({"path": "game/builtin_broken.tscn", "sha256": sha, "size": len(b)})
json.dump(m, open(os.path.join(dst, "manifest.json"), "w"))
PY
bash "$HERE/tools/pack_boot_test.sh" "$TMP/builtin" "$LOCK" >"$TMP/builtin.log" 2>&1
rc=$?
[ $rc -eq 1 ] && grep -q '^pack_boot: FAIL .*built into game/builtin_broken.tscn' "$TMP/builtin.log" \
    && ok "a broken script built into a scene is refused and named" || { fail "a broken built-in script gave exit $rc"; grep '^pack_boot' "$TMP/builtin.log"; }

# Two runs at once on one host (two publishes, a sweep beside a publish) each run their own probe.
bash "$HERE/tools/pack_boot_test.sh" "$TMP/nonet" "$LOCK" >"$TMP/c1.log" 2>&1 & c1=$!
bash "$HERE/tools/pack_boot_test.sh" "$TMP/bad" "$LOCK" >"$TMP/c2.log" 2>&1; r2=$?
wait $c1; r1=$?
[ $r1 -eq 0 ] && [ $r2 -eq 1 ] && ok "concurrent runs keep their own verdicts" || fail "concurrent runs gave $r1/$r2 (want 0/1)"

# A bridge that needs the running game (reads `game`, null off the tree) cannot be judged by the probe: exit 2, never 1.
python3 -I - "$TMP/nonet" "$TMP/stateful" <<'PY'
import hashlib, json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
shutil.copytree(src, dst)
m = json.load(open(os.path.join(dst, "manifest.json")))
def put(path, text):
    b = text.encode(); sha = hashlib.sha256(b).hexdigest()
    os.makedirs(os.path.join(dst, "objects", sha[:2]), exist_ok=True)
    open(os.path.join(dst, "objects", sha[:2], sha), "wb").write(b)
    m["files"] = [f for f in m["files"] if f["path"] != path] + [{"path": path, "sha256": sha, "size": len(b)}]
put("game/no_net_module.gd", "extends DotGameModule\n\nfunc _net_config() -> DotNetConfig:\n\treturn DotNetConfig.new()\n\n"
    "func _make_bridge() -> Node:\n\treturn Node.new() if game.get_meta(\"ready\", false) else null\n")
json.dump(m, open(os.path.join(dst, "manifest.json"), "w"))
PY
bash "$HERE/tools/pack_boot_test.sh" "$TMP/stateful" "$LOCK" >"$TMP/stateful.log" 2>&1
rc=$?
[ $rc -eq 2 ] && grep -q 'NOT JUDGED' "$TMP/stateful.log" && ok "a bridge that needs the running game is exit 2, not a refusal" \
    || { fail "a stateful bridge gave exit $rc (want 2)"; grep '^pack_boot' "$TMP/stateful.log"; }

# The same bridge returning null quietly while `game` is unset (no error logged) is not judged either.
mkdir -p "$TMP/quiet" && cp -r "$TMP/stateful/." "$TMP/quiet/"
python3 -I - "$TMP/quiet" <<'PY'
import hashlib, json, os, sys
dst = sys.argv[1]; m = json.load(open(os.path.join(dst, "manifest.json")))
b = ("extends DotGameModule\n\nfunc _net_config() -> DotNetConfig:\n\treturn DotNetConfig.new()\n\n"
     "func _make_bridge() -> Node:\n\tif game == null:\n\t\treturn null\n\treturn Node.new()\n").encode()
sha = hashlib.sha256(b).hexdigest(); os.makedirs(os.path.join(dst, "objects", sha[:2]), exist_ok=True)
open(os.path.join(dst, "objects", sha[:2], sha), "wb").write(b)
m["files"] = [f for f in m["files"] if f["path"] != "game/no_net_module.gd"] + [{"path": "game/no_net_module.gd", "sha256": sha, "size": len(b)}]
json.dump(m, open(os.path.join(dst, "manifest.json"), "w"))
PY
bash "$HERE/tools/pack_boot_test.sh" "$TMP/quiet" "$LOCK" >"$TMP/quiet.log" 2>&1
rc=$?
[ $rc -eq 2 ] && grep -q 'NOT JUDGED' "$TMP/quiet.log" && ok "a bridge that returns null quietly off the tree is exit 2, not a refusal" \
    || { fail "a quiet null bridge gave exit $rc (want 2)"; grep '^pack_boot' "$TMP/quiet.log"; }

# A server fetches no client-side file: a server module that preloads one is refused (the server would not load it),
# while the same file shipped for both sides boots. game.yml read as the host reads it: a trailing comment is no path.
python3 -I - "$TMP/nonet" "$TMP/sided" <<'PY2'
import hashlib, json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for d, side in ((dst + "_client", "client"), (dst + "_both", None)):
    shutil.copytree(src, d)
    m = json.load(open(os.path.join(d, "manifest.json")))
    def put(path, text, side=None):
        b = text.encode(); sha = hashlib.sha256(b).hexdigest()
        os.makedirs(os.path.join(d, "objects", sha[:2]), exist_ok=True)
        open(os.path.join(d, "objects", sha[:2], sha), "wb").write(b)
        e = {"path": path, "sha256": sha, "size": len(b)}
        if side: e["side"] = side
        m["files"] = [f for f in m["files"] if f["path"] != path] + [e]
    put("game/client_only.gd", "extends Node\n", side)
    put("game/no_net_module.gd", "extends DotGameModule\n\nconst C := preload(\"res://dot_cloud/%s/%s/game/client_only.gd\")\n" % (m["content_id"], m["version"]))
    yml = next(f for f in m["files"] if f["path"] == "game.yml")
    text = open(os.path.join(d, "objects", yml["sha256"][:2], yml["sha256"])).read()
    put("game.yml", "\n".join(l + "  # the server module" if l.startswith("module:") else l for l in text.split("\n")))
    json.dump(m, open(os.path.join(d, "manifest.json"), "w"))
PY2
bash "$HERE/tools/pack_boot_test.sh" "$TMP/sided_client" "$LOCK" >"$TMP/sc.log" 2>&1; r1=$?
bash "$HERE/tools/pack_boot_test.sh" "$TMP/sided_both" "$LOCK" >"$TMP/sb.log" 2>&1; r2=$?
[ $r1 -eq 1 ] && ok "a server module preloading a client-only file is refused" || { fail "client-only preload gave exit $r1 (want 1)"; grep '^pack_boot' "$TMP/sc.log"; }
[ $r2 -eq 0 ] && ok "the same file for both sides boots, with a commented game.yml module" || { fail "both-sides preload gave exit $r2 (want 0)"; grep '^pack_boot' "$TMP/sb.log"; }

# A probe that cannot judge (here: an unreadable manifest, the probe's own exit 2) is exit 2, not a refusal.
mkdir -p "$TMP/junk"; echo '[]' >"$TMP/junk/manifest.json"
bash "$HERE/tools/pack_boot_test.sh" "$TMP/junk" "$LOCK" >"$TMP/junk.log" 2>&1
rc=$?
[ $rc -eq 2 ] && ok "a probe that cannot judge is exit 2" || fail "an unreadable manifest gave exit $rc (want 2)"

[ $fails -gt 0 ] && { echo "--- 0.1.19 log"; cat "$TMP/bad.log"; }
echo "test_pack_boot: $fails failed"
exit $(( fails > 0 ))
