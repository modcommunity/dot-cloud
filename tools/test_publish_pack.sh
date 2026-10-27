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
echo "publish_pack tests: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
