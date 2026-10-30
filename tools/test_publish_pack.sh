#!/bin/bash
# Runs publish_pack.sh against tools/test/mock_site.py (no network, no bucket): first publish, no-op skip, --bump with one changed file,
# versions, a wrong token, and the lock file after each. Usage: tools/test_publish_pack.sh [godot-binary]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="${1:-${GODOT:-godot}}"; export GODOT
W="$(mktemp -d)"; PASS=0; FAIL=0
chk() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
python3 -I "$HERE/test/mock_site.py" "$W/log" secret > "$W/port" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
until grep -q PORT= "$W/port"; do sleep 0.2; done
export DOT_SITE="http://127.0.0.1:$(sed 's/PORT=//' "$W/port")"
mkdir -p "$W/src/sub"; echo one > "$W/src/a.txt"; echo two > "$W/src/sub/b.txt"; echo big > "$W/src/c.txt"
echo '[{"paths": [""], "licence": "CC0-1.0", "author": "Tester", "url": "https://example.com"}]' > "$W/src/licence.json"
cd "$W"
pub() { DOT_CLI_TOKEN="${TOK:-secret}" "$HERE/publish_pack.sh" --source "$W/src" --id demo --lock "$W/content.lock.json" "$@" > "$W/out" 2>&1; }
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
DOT_CLI_TOKEN=secret "$HERE/publish_pack.sh" versions --id demo > "$W/v" 2>&1
chk "versions lists both" "grep -q 1.0.0 v && grep -q 1.0.1 v"
TOK=wrong pub --bump patch
chk "wrong token fails" "[ $? -ne 0 ]"
chk "lock untouched by failure" "grep -q '\"version\": \"1.0.1\"' content.lock.json"
DOT_CLI_TOKEN=x "$HERE/publish_pack.sh" --token abc --source src --id demo >/dev/null 2>&1
chk "--token refused" "[ $? -eq 2 ]"
# (b) an unfinished claim: without --resume a clear error, with it the claim is reused
curl -s -H "Authorization: Bearer secret" -d '{"action":"claim","repoName":"demo","version":"2.0.0","fileCount":1,"byteSize":1}' "$DOT_SITE/api/app/v1/packs" > /dev/null
pub --version 2.0.0
chk "open claim without --resume fails" "[ $? -ne 0 ]"
chk "error names version_taken and --resume" "grep -q version_taken out && grep -q -- '--resume' out"
pub --version 2.0.0 --resume
chk "--resume reuses the claim and exits 0" "[ $? -eq 0 ] && grep -q 'resuming claim' out"
chk "lock now 2.0.0" "grep -q '\"version\": \"2.0.0\"' content.lock.json"
pub --version 2.0.0
chk "READY version taken says use --bump" "grep -q -- '--bump' out"
# (c) a HELD release has no lock line until approved; relock writes it
rm -f held.lock.json
DOT_CLI_TOKEN=secret "$HERE/publish_pack.sh" --source "$W/src" --id heldpack --version 1.0.0 --lock "$W/held.lock.json" > "$W/out" 2>&1
chk "held publish exits 0 without a lock" "[ $? -eq 0 ] && grep -qi 'held for review' out && [ ! -f held.lock.json ]"
DOT_CLI_TOKEN=secret "$HERE/publish_pack.sh" relock --id heldpack --lock "$W/held.lock.json" --version 1.0.0 > "$W/out" 2>&1
chk "relock before approval fails" "[ $? -ne 0 ] && grep -q 'no READY' out && [ ! -f held.lock.json ]"
curl -s -X POST "$DOT_SITE/__approve/heldpack/1.0.0" > /dev/null
DOT_CLI_TOKEN=secret "$HERE/publish_pack.sh" relock --id heldpack --lock "$W/held.lock.json" --version 1.0.0 --into .stores/h --kind store > "$W/out" 2>&1
chk "relock after approval exits 0" "[ $? -eq 0 ]"
chk "relock wrote the entry with sha, into and kind" "grep -q 'tester/heldpack' held.lock.json && grep -q '\"manifest_sha256\": \"[0-9a-f]\{64\}' held.lock.json && grep -q '\.stores/h' held.lock.json && grep -q '\"store\"' held.lock.json && grep -q 'cdn.test' held.lock.json"
DOT_CLI_TOKEN=secret "$HERE/publish_pack.sh" relock --id heldpack --lock "$W/held.lock.json" > "$W/out" 2>&1
chk "relock with no --version reads it from the lock and keeps into" "[ $? -eq 0 ] && grep -q '\.stores/h' held.lock.json"
env -u DOT_CLI_TOKEN HOME="$W/nohome" DOT_CLI_TOKEN_FILE="$W/none" "$HERE/publish_pack.sh" --source "$W/src" --id demo --version 9.0.0 --out "$W/dry" --dry-run > "$W/out" 2>&1
chk "--dry-run builds with no token and sends nothing" "[ $? -eq 0 ] && [ -f '$W/dry/manifest.json' ] && ! grep -q '9.0.0' log"
echo "publish_pack tests: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
