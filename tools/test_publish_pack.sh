#!/bin/bash
# Runs publish_pack.sh against tools/test/mock_site.py (no network, no bucket): first publish, no-op skip, --bump with one changed file,
# versions, a wrong token, and the lock file after each. Usage: tools/test_publish_pack.sh [godot-binary]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="${1:-${GODOT:-godot}}"
# Resolve to an absolute path: the --dry-run check runs with HOME overridden, which hides $HOME/.local/bin from publish_pack's fallback.
[ -x "$GODOT" ] || GODOT="$(command -v "$GODOT" 2>/dev/null || true)"; [ -n "$GODOT" ] || GODOT="$HOME/.local/bin/godot"; export GODOT
[ -x "$GODOT" ] || { echo "test_publish_pack: no godot binary (pass one, set GODOT, or put godot on PATH)" >&2; exit 2; }
# The publish CLI needs dot-core's classes; without the link every check below fails with an unrelated parse error.
[ -d "$HERE/../addons/dot_core" ] || { echo "test_publish_pack: addons/dot_core missing; run: ln -s ../../dot-core/addons/dot_core addons/dot_core (then rm -rf .godot if a run already cached without it)" >&2; exit 2; }
W="$(mktemp -d)"; PASS=0; FAIL=0
chk() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
python3 -I "$HERE/test/mock_site.py" "$W/log" secret > "$W/port" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
until grep -q PORT= "$W/port"; do sleep 0.2; done
export GS_SITE="http://127.0.0.1:$(sed 's/PORT=//' "$W/port")"
mkdir -p "$W/src/sub"; echo one > "$W/src/a.txt"; echo two > "$W/src/sub/b.txt"; echo big > "$W/src/c.txt"
echo '[{"paths": [""], "licence": "CC0-1.0", "author": "Tester", "url": "https://example.com"}]' > "$W/src/licence.json"
cd "$W"
pub() { GS_CLI_TOKEN="${TOK:-secret}" "$HERE/publish_pack.sh" --source "$W/src" --id demo --lock "$W/content.lock.json" "$@" > "$W/out" 2>&1; }
pub --version 1.0.0 --into .stores/x --kind store --lock-optional
chk "first publish exits 0" "[ $? -eq 0 ]"
chk "lock has 1.0.0" "grep -q '\"version\": \"1.0.0\"' content.lock.json"
chk "lock keeps into/kind/optional" "grep -q '\.stores/x' content.lock.json && grep -q '\"store\"' content.lock.json && grep -q 'optional' content.lock.json"
chk "objects were PUT" "[ \$(grep -c '^PUT' log) -ge 3 ]"
P1=$(grep -c '^PUT' log)
echo changed > src/c.txt
pub --bump patch
chk "bump exits 0" "[ $? -eq 0 ]"
chk "lock now 1.0.1" "grep -q '\"version\": \"1.0.1\"' content.lock.json && ! grep -q '\"version\": \"1.0.0\"' content.lock.json"
chk "republish keeps the entry's into" "grep -q '\.stores/x' content.lock.json"
chk "only the changed object travelled" "[ \$(( \$(grep -c '^PUT' log) - P1 )) -le 2 ]"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" versions --id demo > "$W/v" 2>&1
chk "versions lists both" "grep -q 1.0.0 v && grep -q 1.0.1 v"
"$HERE/publish_pack.sh" frobnicate --source src --id demo > "$W/o2" 2>&1; RC=$?
chk "unknown verb exits 2 and publishes nothing" "[ $RC -eq 2 ] && grep -q 'unknown verb' o2 && ! grep -q 'frobnicate' log"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" publish --source src --id demo versions > "$W/o2" 2>&1
chk "stray word after publish (wrapper 'versions') exits 2" "[ $? -eq 2 ] && grep -q unexpected o2"
NPUT=$(grep -c '^PUT' log)
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" --source src --id demo --version latest > "$W/o2" 2>&1
chk "non-semver --version exits 2" "[ $? -eq 2 ] && grep -q 'not semver' o2 && [ \$(grep -c '^PUT' log) -eq $NPUT ]"
TOK=wrong pub --bump patch
chk "wrong token fails" "[ $? -ne 0 ]"
chk "lock untouched by failure" "grep -q '\"version\": \"1.0.1\"' content.lock.json"
GS_CLI_TOKEN=x "$HERE/publish_pack.sh" --token abc --source src --id demo >/dev/null 2>&1
chk "--token refused" "[ $? -eq 2 ]"
# (b) an unfinished claim: without --resume a clear error, with it the claim is reused
curl -s -H "Authorization: Bearer secret" -d '{"action":"claim","repoName":"demo","version":"2.0.0","fileCount":1,"byteSize":1}' "$GS_SITE/api/app/v1/packs" > /dev/null
pub --version 2.0.0
chk "open claim without --resume fails" "[ $? -ne 0 ]"
chk "error names version_taken and --resume" "grep -q version_taken out && grep -q -- '--resume' out"
pub --version 2.0.0 --resume
chk "--resume reuses the claim and exits 0" "[ $? -eq 0 ] && grep -q 'resuming claim' out"
chk "lock now 2.0.0" "grep -q '\"version\": \"2.0.0\"' content.lock.json"
pub --version 2.0.0
chk "READY version taken says use --bump" "grep -q -- '--bump' out"
# (b2) --asset sends assetId; an asset that publishes under another name is refused and its claim failed
pub --version 3.0.0
pub --version 3.0.1 --asset 7
chk "--asset sends assetId and publishes" "[ \$? -eq 0 ] && grep -q 'CLAIM asset=7' log"
pub --version 3.0.2
chk "no --asset sends no assetId" "[ \$(grep -c 'CLAIM asset' log) -eq 1 ]"
pub --version 3.0.3 --asset 8
chk "asset naming another pack is refused" "[ \$? -ne 0 ] && grep -q 'publishes as' out"
pub --version 3.0.4 --asset abc
chk "bad --asset is refused" "[ \$? -ne 0 ] && grep -q 'positive asset id' out"
# (b3) --member-of sends memberOf and keeps --id; with --asset it is refused; `member` relinks published versions
pub --version 3.1.0 --member-of 116
chk "--member-of sends memberOf and publishes as --id" "[ \$? -eq 0 ] && grep -q 'CLAIM memberOf=116' log && grep -q '\"version\": \"3.1.0\"' content.lock.json"
pub --version 3.1.1 --member-of 116 --asset 7
chk "--member-of with --asset is refused" "[ \$? -ne 0 ] && grep -q 'no --asset' out"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" member --id demo --member-of 116 > "$W/out" 2>&1
chk "member relinks the pack's versions" "[ \$? -eq 0 ] && grep -q 'MEMBER demo asset=116' log && grep -q 'members of asset 116' out"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" member --id nosuch --member-of 116 > "$W/out" 2>&1
chk "member of an unpublished pack fails" "[ \$? -ne 0 ]"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" member --id demo > "$W/out" 2>&1
chk "member without --member-of is a usage error" "[ \$? -ne 0 ] && grep -q 'needs --member-of' out"
# (c) a HELD release has no lock line until approved; relock writes it
rm -f held.lock.json
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" --source "$W/src" --id heldpack --version 1.0.0 --lock "$W/held.lock.json" > "$W/out" 2>&1
chk "held publish exits 0 without a lock" "[ $? -eq 0 ] && grep -qi 'held for review' out && [ ! -f held.lock.json ]"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" relock --id heldpack --lock "$W/held.lock.json" --version 1.0.0 > "$W/out" 2>&1
chk "relock before approval fails" "[ $? -ne 0 ] && grep -q 'no READY' out && [ ! -f held.lock.json ]"
curl -s -X POST "$GS_SITE/__approve/heldpack/1.0.0" > /dev/null
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" relock --id heldpack --lock "$W/held.lock.json" --version 1.0.0 --into .stores/h --kind store > "$W/out" 2>&1
chk "relock after approval exits 0" "[ $? -eq 0 ]"
chk "relock wrote the entry with sha, into and kind" "grep -q 'tester/heldpack' held.lock.json && grep -q '\"manifest_sha256\": \"[0-9a-f]\{64\}' held.lock.json && grep -q '\.stores/h' held.lock.json && grep -q '\"store\"' held.lock.json && grep -q 'cdn.test' held.lock.json"
GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" relock --id heldpack --lock "$W/held.lock.json" > "$W/out" 2>&1
chk "relock with no --version reads it from the lock and keeps into" "[ $? -eq 0 ] && grep -q '\.stores/h' held.lock.json"
env -u GS_CLI_TOKEN HOME="$W/nohome" GS_CLI_TOKEN_FILE="$W/none" "$HERE/publish_pack.sh" --source "$W/src" --id demo --version 9.0.0 --out "$W/dry" --dry-run > "$W/out" 2>&1
chk "--dry-run builds with no token and sends nothing" "[ $? -eq 0 ] && [ -f '$W/dry/manifest.json' ] && ! grep -q '9.0.0' log"
# (d) --host-addons: addons/dot_core is host-owned and left out, addons/zz_x stays; without the flag both ship
mkdir -p "$W/h/addons/dot_core" "$W/h/addons/zz_x" "$W/hostdir/dot_core" "$W/hostdir/other"; echo c > "$W/h/addons/dot_core/c.gd"; echo x > "$W/h/addons/zz_x/x.gd"; echo r > "$W/h/root.txt"
printf '# lock\ndot-core\tv1\n' > "$W/addons.lock"
hp() { "$HERE/publish_pack.sh" --source "$W/h" --id hostdemo --version 1.0.0 --out "$W/ho" --dry-run "$@" > "$W/out" 2>&1; }
hp --pack-addon dot_core
chk "no --host-addons packs both and says so" "[ $? -eq 0 ] && grep -q dot_core ho/manifest.json && grep -q zz_x ho/manifest.json && grep -q 'no --host-addons' out"
rm -rf ho; hp --host-addons "$W/addons.lock"
chk "lock: dot_core left out, zz_x kept, logged" "[ $? -eq 0 ] && ! grep -q dot_core ho/manifest.json && grep -q zz_x ho/manifest.json && grep -q 'left out 1 host-owned addon(s): dot_core' out"
rm -rf ho; hp --host-addons "$W/hostdir"
chk "directory form excludes dot_core" "[ $? -eq 0 ] && ! grep -q dot_core ho/manifest.json && grep -q zz_x ho/manifest.json"
rm -rf ho; printf 'dot-core\n' > "$W/names.txt"; hp --host-addons "$W/names.txt"
chk "name-list form excludes dot_core" "[ $? -eq 0 ] && ! grep -q dot_core ho/manifest.json && grep -q zz_x ho/manifest.json"
# a linked addon whose folder differs from its repository (zee-dot-weapons ships addons/zee_weapons)
mkdir -p "$W/zee-dot-weapons/addons/zee_weapons" "$W/h/addons"; echo z > "$W/zee-dot-weapons/addons/zee_weapons/z.gd"; ln -sfn ../../zee-dot-weapons/addons/zee_weapons "$W/h/addons/zee_weapons"
printf 'zee-dot-weapons\tv1\n' > "$W/zee.lock"
mkdir -p "$W/h/cfg/addon/zee_weapons" "$W/h/cfg/game/g/dot_core"; echo a > "$W/h/cfg/addon/zee_weapons/ads.yml"; echo m > "$W/h/cfg/game/g/dot_core/ph_%.yml"
rm -rf ho; hp --host-addons "$W/zee.lock" --host-addons "$W/hostdir"
chk "a linked addon is matched by its repository" "[ $? -eq 0 ] && ! grep -q zee_weapons/z.gd ho/manifest.json && grep -q zz_x ho/manifest.json"
# only addons/<name> is left out: a game's settings for that addon elsewhere (cfg/addon/zee_weapons/ads.yml) still ship
chk "a host addon's name elsewhere in the tree still ships" "grep -q 'cfg/addon/zee_weapons/ads.yml' ho/manifest.json && grep -q 'cfg/game/g/dot_core/ph_%.yml' ho/manifest.json && ! grep -q 'dot_core/c.gd' ho/manifest.json"
rm -f "$W/h/addons/zee_weapons"
hp --host-addons "$W/missing"
chk "missing --host-addons argument fails" "[ $? -ne 0 ]"
# examples/ at the source root is editor-only and never packed; a nested folder of that name is content
mkdir -p "$W/h/examples" "$W/h/sub/examples"; echo e > "$W/h/examples/e.gd"; echo n > "$W/h/sub/examples/n.txt"
rm -rf ho; hp
chk "root examples/ left out, nested examples/ kept" "[ $? -eq 0 ] && ! grep -q 'examples/e.gd' ho/manifest.json && grep -q 'sub/examples/n.txt' ho/manifest.json"
# a source outside any Godot project ships its raw images and no .import markers (a marker would name a ctex the pack lacks)
mkdir -p "$W/h/tex"; echo png > "$W/h/tex/t.png"; echo 'path="res://.godot/imported/t.png-x.ctex"' > "$W/h/tex/t.png.import"
rm -rf ho; hp
chk "no project: raw image kept, .import marker dropped" "[ $? -eq 0 ] && grep -q 'tex/t.png\"' ho/manifest.json && ! grep -q 't.png.import' ho/manifest.json"
# resolved family addons (what a copy with links resolved looks like) are left out; a pile of other addons is refused
mkdir -p "$W/h/addons/dot_core" "$W/h/addons/pg_timer"; echo a > "$W/h/addons/dot_core/x.gd"; echo b > "$W/h/addons/pg_timer/y.gd"
rm -rf ho; hp
chk "dot_* addon left out, own adapter kept" "[ $? -eq 0 ] && ! grep -q 'dot_core/x.gd' ho/manifest.json && grep -q 'pg_timer/y.gd' ho/manifest.json"
rm -rf ho; hp --pack-addon dot_core
chk "--pack-addon packs a dot_ addon on purpose" "[ $? -eq 0 ] && grep -q 'dot_core/x.gd' ho/manifest.json"
for i in 1 2 3 4 5 6; do mkdir -p "$W/h/addons/own$i"; echo z > "$W/h/addons/own$i/z.gd"; done
rm -rf ho; hp
chk "more than 5 packed addons is refused" "[ $? -ne 0 ] && grep -q Refusing out"
rm -rf "$W/h/addons"
# a desktop-only VRAM import (s3tc_bptc without etc2_astc) draws a warning, a both-format one does not
mkdir -p "$W/h/vr"; echo x > "$W/h/vr/d.png"; printf '[remap]\nimported_formats=["s3tc_bptc"]\n' > "$W/h/vr/d.png.import"
rm -rf ho; hp
chk "desktop-only VRAM import warns" "[ $? -eq 0 ] && grep -q 'desktop-only s3tc_bptc' out && grep -q 'd.png.import' out"
printf '[remap]\nimported_formats=["s3tc_bptc","etc2_astc"]\n' > "$W/h/vr/d.png.import"
rm -rf ho; hp
chk "both-format import is silent" "[ $? -eq 0 ] && ! grep -q 'desktop-only' out"
rm -rf "$W/h/vr"
# (e) requires.json: derived (dot-core's dot_requires.gd) and capped at the host lock's level; a committed one above it is refused
DC="$(readlink -f "$HERE/../addons/dot_core" 2>/dev/null || true)"; [ -d "$DC" ] || DC="$(readlink -f "$HERE/../../dot-core/addons/dot_core" 2>/dev/null || true)"
if [ -f "$DC/tools/dot_requires.gd" ]; then
    mkdir -p "$W/zz-lv/addons/zz_lv" "$W/rq/addons"
    printf 'const LEVEL := 3\n' > "$W/zz-lv/addons/zz_lv/zz_lv_api.gd"; printf 'class_name ZzLv\nextends RefCounted\n' > "$W/zz-lv/addons/zz_lv/zz_lv.gd"
    git -C "$W/zz-lv" init -q && git -C "$W/zz-lv" add -A && git -C "$W/zz-lv" -c user.name=t -c user.email=t@t commit -qm l3 && git -C "$W/zz-lv" tag v1
    printf 'const LEVEL := 5\n' > "$W/zz-lv/addons/zz_lv/zz_lv_api.gd"
    ln -s "$DC" "$W/rq/addons/dot_core"; ln -s ../../zz-lv/addons/zz_lv "$W/rq/addons/zz_lv"
    printf 'config_version=5\n[application]\nconfig/name="rq"\n' > "$W/rq/project.godot"; printf 'extends Node\nvar x := ZzLv.new()\n' > "$W/rq/main.gd"
    printf 'zz-lv\tv1\n' > "$W/rq.lock"
    rq() { "$HERE/publish_pack.sh" --source "$W/rq" --id rqdemo --version 1.0.0 --out "$W/ro" --dry-run --pack-addon zz_lv "$@" > "$W/out" 2>&1; }
    rq --host-addons "$W/rq.lock"
    chk "derived requires.json ships, capped at the lock's level" "[ $? -eq 0 ] && grep -q '\"requires.json\"' ro/manifest.json && grep -q 'zz_lv 5 capped at the host.s 3' out && [ ! -f rq/requires.json ]"
    rm -rf "$W/ro"; rq --host-addons "$W/names.txt"
    chk "no lock: derived at the build's level" "[ $? -eq 0 ] && grep -q 'derived): zz_lv 5' out"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock" --host-level zz_lv=4
    chk "--host-level names the host's level" "[ $? -eq 0 ] && grep -q 'capped at the host.s 4' out"
    printf '{"format": 1, "addons": {"zz_lv": 5}}\n' > "$W/rq/requires.json"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "committed requires.json above the host is refused" "[ $? -ne 0 ] && grep -q 'above the host' out"
    printf '{"format": 1, "addons": {"zz_lv": 3}}\n' > "$W/rq/requires.json"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "committed requires.json at the host's level ships" "[ $? -eq 0 ] && grep -q 'committed): zz_lv 3' out"
    rm -f "$W/rq/requires.json"
    # A floor is judged against the lock's level, not the linked head one past it; a floor below the pin with no guard still fails.
    printf '{"format": 1, "addons": {"zz_lv": 3}}\n' > "$W/rq/requires.floor.json"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "a floor at the lock's level passes though the linked head is newer" "[ $? -eq 0 ] && grep -q 'derived): zz_lv 3' out"
    rm -rf "$W/ro"; rq --host-addons "$W/names.txt"
    chk "without a lock the same unguarded floor is refused" "[ $? -ne 0 ] && grep -q 'no file asks the host' out"
    printf '{"format": 1, "addons": {"zz_lv": 2}}\n' > "$W/rq/requires.floor.json"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "an unguarded floor below the lock's level is refused" "[ $? -ne 0 ] && grep -q 'no file asks the host' out"
    printf '{"format": 1, "addons": {"zz_lv": 4}}\n' > "$W/rq/requires.floor.json"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "a floor above the lock's level is refused" "[ $? -ne 0 ] && grep -q 'above the 3 the pinned shell has' out"
    # A lock ref older than the addon's directory (pinned before a rename) fails naming the rename, not a level of 1.
    git -C "$W/zz-lv" tag v0 "$(git -C "$W/zz-lv" -c user.name=t -c user.email=t@t commit-tree "$(git -C "$W/zz-lv" mktree </dev/null)" -m empty)"
    printf '{"format": 1, "addons": {"zz_lv": 3}}\n' > "$W/rq/requires.floor.json"; printf 'zz-lv\tv0\n' > "$W/rq.lock"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "a lock ref without the addon's directory names the rename and pack_ready" "[ $? -ne 0 ] && grep -q 'no addons/zz_lv (pinned before a rename' out && grep -q 'pack_ready.sh' out && ! grep -q 'above the 1' out"
    rm -f "$W/rq/requires.floor.json"; printf 'zz-lv\tnosuchref\n' > "$W/rq.lock"
    rm -rf "$W/ro"; rq --host-addons "$W/rq.lock"
    chk "an unresolvable lock ref fails and names --host-level" "[ $? -ne 0 ] && grep -q -- '--host-level zz_lv=N' out"
else
    echo "skip: requires.json checks need dot-core (addons/dot_core link or ../dot-core)"
fi
# (f) publish_pack.ps1 parity (no PowerShell here: a static check that it carries the same requires.json steps as the bash script)
PS1="$HERE/publish_pack.ps1"
chk "ps1 derives requires.json with dot_requires.gd and ships it as an extra file" "grep -q 'dot_requires.gd' '$PS1' && grep -q \"requires.json=\" '$PS1'"
chk "ps1 passes the host lock's levels to the floor audit like the bash script (--pin)" "grep -q 'requires.floor.json' '$PS1' && grep -q \"'--pin'\" '$PS1' && grep -q 'HostLevelOf \$h \$pp \$n' '$PS1'"
chk "ps1 takes -HostAddons and -HostLevel" "grep -q '\[string\[\]\]\$HostAddons' '$PS1' && grep -q '\[string\[\]\]\$HostLevel' '$PS1'"
chk "ps1 leaves out host-owned addons anchored at addons/ like the bash script" "grep -q 'function HostNames' '$PS1' && grep -q 'addons/\$n' '$PS1' && grep -q 'host-owned addon' '$PS1'"
chk "ps1 caps and refuses like the bash script" "grep -q \"capped at the host's\" '$PS1' && grep -q \"above the host's levels\" '$PS1' && grep -q \"capped at the host.s\" '$HERE/publish_pack.sh'"
# (g) a worktree's dangling relative addon link is relinked into the family directory
mkdir -p "$W/fam/zz-lv/addons/zz_lv" "$W/wt/deep/gm/addons"; printf 'const LEVEL := 3\n' > "$W/fam/zz-lv/addons/zz_lv/zz_lv_api.gd"
ln -s ../../zz-lv/addons/zz_lv "$W/wt/deep/gm/addons/zz_lv"; printf 'config_version=5\n' > "$W/wt/deep/gm/project.godot"; echo x > "$W/wt/deep/gm/a.txt"
GS_FAMILY_DIR="$W/fam" "$HERE/publish_pack.sh" --source "$W/wt/deep/gm" --id gm --version 1.0.0 --dry-run --no-import --pack-addon zz_lv > "$W/out" 2>&1
chk "dangling addon link is relinked to the family dir" "grep -q 'relinked .*zz_lv' out && [ -e '$W/wt/deep/gm/addons/zz_lv/zz_lv_api.gd' ]"
# (h) Valve guard: a pack with a stock file is refused (every path listed, nothing sent); a clean pack passes; the ps1 carries the guard
mkdir -p "$W/vsrc/tex"; echo ok > "$W/vsrc/a.txt"; cp "$W/src/licence.json" "$W/vsrc/"; echo v > "$W/vsrc/tex/brick.vtf"; echo v > "$W/vsrc/hl2_misc_dir.vpk"
NPUT=$(grep -c '^PUT' log)
GS_VALVE_INDEX=/nonexistent GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" --source "$W/vsrc" --id vtest --version 1.0.0 > "$W/out" 2>&1; RC=$?
chk "pack with Valve files is refused" "[ $RC -ne 0 ] && grep -q 'tex/brick.vtf' out && grep -q 'hl2_misc_dir.vpk' out && grep -q 'Nothing was sent' out && [ \$(grep -c '^PUT' log) -eq $NPUT ]"
GS_VALVE_INDEX=/nonexistent "$HERE/publish_pack.sh" --source "$W/vsrc" --id vtest --version 1.0.0 --dry-run > "$W/out" 2>&1
chk "the guard also runs on --dry-run" "[ $? -ne 0 ] && grep -q 'tex/brick.vtf' out"
rm "$W/vsrc/tex/brick.vtf" "$W/vsrc/hl2_misc_dir.vpk"
GS_VALVE_INDEX=/nonexistent GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" --source "$W/vsrc" --id vtest_orig --version 1.0.0 > "$W/out" 2>&1
chk "an _orig pack id is refused" "[ $? -ne 0 ] && grep -q '_orig' out"
GS_VALVE_INDEX=/nonexistent GS_CLI_TOKEN=secret "$HERE/publish_pack.sh" --source "$W/vsrc" --id vtest --version 1.0.0 > "$W/out" 2>&1
chk "a clean pack still publishes" "[ $? -eq 0 ] && grep -q 'clean' out"
chk "ps1 runs the Valve guard" "grep -q 'check_valve_files.py' '$HERE/publish_pack.ps1'"
# a class cache older than one of the checkout's scripts is re-imported before the CLI runs (a stale one failed every publish)
CC="$HERE/../.godot/global_script_class_cache.cfg"
if [ -f "$CC" ]; then
    touch -d '2000-01-01' "$CC"
    "$HERE/publish_pack.sh" --source "$W/vsrc" --id stale --version 1.0.0 --dry-run --no-import > "$W/out" 2>&1
    chk "a stale class cache is re-imported" "[ \$(stat -c %Y '$CC') -gt 946771200 ]"
fi
chk "ps1 re-imports a stale class cache" "grep -q 'LastWriteTime -gt' '$HERE/publish_pack.ps1'"
python3 -I "$HERE/test_check_valve_files.py" >/dev/null 2>&1
chk "check_valve_files unit tests" "[ $? -eq 0 ]"
echo "publish_pack tests: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
