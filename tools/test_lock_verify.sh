#!/bin/bash
# Local test of lock_verify.sh against a python http.server fixture CDN (no network, no token, nothing published). Run: tools/test_lock_verify.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; PASS=0; FAIL=0; PID=""
trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
chk() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
python3 -I - "$T" <<'PY'
import base64, hashlib, json, os, sys
t = sys.argv[1]; root = t + "/cdn/content"; lock = []
def pack(ver, files, bundle=None):
    d = "%s/o/demo/%s" % (root, ver); fl = []
    for path, data in files.items():
        sha = hashlib.sha256(data).hexdigest(); os.makedirs("%s/objects/%s" % (d, sha[:2]), exist_ok=True)
        open("%s/objects/%s/%s" % (d, sha[:2], sha), "wb").write(data); fl.append({"path": path, "sha256": sha, "size": len(data)})
    body = {"content_id": "o/demo", "version": ver, "files": fl}
    if bundle: body["bundle"] = bundle  # names an archive; the bundle file itself is written only when the test wants it there
    pl = base64.urlsafe_b64encode(json.dumps(body).encode()).decode().rstrip("=")
    m = json.dumps({"payload": pl}).encode(); open(d + "/manifest.json", "wb").write(m)
    return hashlib.sha256(m).hexdigest()
pack("1.0.0", {"a.txt": b"one", "b.txt": b"two", "c.txt": b"three"})
# 1.1.0 names a bundle that is NOT on the fixture: lock_verify must warn about it and still exit 0
sha = pack("1.1.0", {"a.txt": b"one", "b.txt": b"TWO", "d.txt": b"four"}, {"url_path": "bundles/absent.zip", "sha256": "0" * 64, "size": 1, "count": 3})
json.dump({"format": 1, "origin": "http://127.0.0.1:18201/content", "packs": [{"id": "o/demo", "version": "1.1.0", "manifest_sha256": sha, "into": ".d", "kind": "store"}]}, open(t + "/content.lock.json", "w"))
bad = dict(json.load(open(t + "/content.lock.json"))); bad["packs"] = [dict(bad["packs"][0], manifest_sha256="0" * 64)]
json.dump(bad, open(t + "/bad.lock.json", "w"))
PY
cat > "$T/cdn_server.py" <<'PY'
# fixture CDN: like the real one, it answers Python's default urllib User-Agent with 403
import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    def parse_request(self):
        if not super().parse_request(): return False
        if self.headers.get("User-Agent", "").startswith("Python-urllib"): self.send_error(403); return False
        return True
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 18201), functools.partial(H, directory=sys.argv[1])).serve_forever()
PY
python3 -I "$T/cdn_server.py" "$T/cdn" >/dev/null 2>&1 & PID=$!
sleep 1
V="$HERE/lock_verify.sh"
python3 -I -c 'import urllib.request as u, sys
try: u.urlopen("http://127.0.0.1:18201/content/o/demo/1.1.0/manifest.json", timeout=5); sys.exit(1)
except u.HTTPError as e: sys.exit(0 if e.code == 403 else 2)'; chk "fixture 403s the default Python UA (the test means something)" "[ $? -eq 0 ]"
"$V" --lock "$T/content.lock.json" > "$T/o" 2>&1; chk "good lock exits 0" "[ $? -eq 0 ] && grep -q '^ok .*3 files, 3 objects' $T/o"
chk "missing bundle is a warning, not a failure" "grep -q '^warn o/demo 1.1.0: bundle bundles/absent.zip answered 404' $T/o"
"$V" --lock "$T/content.lock.json" --deep > "$T/o" 2>&1; chk "--deep hashes and passes" "[ $? -eq 0 ] && grep -q hashed $T/o"
"$V" --lock "$T/bad.lock.json" > "$T/o" 2>&1; chk "wrong pin exits 1" "[ $? -eq 1 ] && grep -q 'not the pinned' $T/o"
O=$(ls "$T"/cdn/content/o/demo/1.1.0/objects/*/* | head -1); rm "$O"
"$V" --lock "$T/content.lock.json" > "$T/o" 2>&1; chk "missing object exits 1" "[ $? -eq 1 ] && grep -q '1 object(s) missing' $T/o"
printf XX > "$O"
"$V" --lock "$T/content.lock.json" > "$T/o" 2>&1; chk "wrong size caught by HEAD" "[ $? -eq 1 ] && grep -q 'wrong size' $T/o"
printf '%s' "$(printf XX | wc -c)" >/dev/null
"$V" --lock "$T/content.lock.json" --only demo --diff 1.0.0 > "$T/o" 2>&1
chk "diff lists + - ~" "grep -q '  ~ b.txt' $T/o && grep -q '  + d.txt' $T/o && grep -q '  - c.txt' $T/o && grep -q 'diff 1.0.0 -> 1.1.0: +1 -1 ~1' $T/o"
"$V" --lock "$T/content.lock.json" --only nothing > "$T/o" 2>&1; chk "no match exits non-zero" "[ $? -ne 0 ]"
"$V" --lock "$T/content.lock.json" --diff 1.0.0 > "$T/o" 2>&1; chk "--diff without --only is usage" "[ $? -eq 2 ]"
"$V" --lock "$T/content.lock.json" --cdn http://127.0.0.1:1 > "$T/o" 2>&1; chk "dead base fails" "[ $? -eq 1 ] && grep -q FAIL $T/o"
echo "lock_verify: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
