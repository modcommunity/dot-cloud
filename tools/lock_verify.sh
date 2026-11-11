#!/bin/bash
# Read side of the CDN flow: check what a content.lock.json pins against what the CDN serves. Reads only; no token, no writes.
#   tools/lock_verify.sh [--lock content.lock.json] [--cdn URL | --from BASE] [--only ID] [--deep] [--diff VERSION]
# Per pack entry: GET <base>/<id>/<version>/manifest.json, its sha256 must equal manifest_sha256; the payload's content_id and
# version must match the entry; every distinct object must answer HEAD 200 with the manifest's size (--deep: GET and hash it).
# --diff VERSION (needs --only): lists files added, removed and changed between the pinned version and VERSION (that one is
# compared by content only, it is not pinned). Base order as fetch_lock.sh: --from, --cdn, the lock's origin, then its mirrors.
# 403, 429, 5xx and no reply are retried with exponential backoff (LOCK_VERIFY_TRIES=5, LOCK_VERIFY_BACKOFF=0.5 s, Retry-After honoured);
# what stays throttled is reported as 'rate limited', never as 'missing'. Exit 0 all good, 1 any mismatch or missing object, 2 usage.
set -euo pipefail
command -v python3 >/dev/null || { echo "lock_verify: python3 is needed" >&2; exit 2; }
LOCK=content.lock.json; BASE=""; ONLY=""; DEEP=0; DIFF=""
while [ $# -gt 0 ]; do
    case $1 in
        --lock) LOCK="${2:?}"; shift 2 ;;
        --from) BASE="${2:?}"; shift 2 ;;
        --cdn) BASE="${2:?}"; BASE="${BASE%/}"; case $BASE in */content) ;; *) BASE="$BASE/content" ;; esac; shift 2 ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        --deep) DEEP=1; shift ;;
        --diff) DIFF="${2:?}"; shift 2 ;;
        *) echo "lock_verify: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -f "$LOCK" ] || { echo "lock_verify: no $LOCK" >&2; exit 2; }
[ -z "$DIFF" ] || [ -n "$ONLY" ] || { echo "lock_verify: --diff needs --only ID" >&2; exit 2; }
exec python3 -I - "$LOCK" "$BASE" "$ONLY" "$DEEP" "$DIFF" <<'PY'
import base64, fnmatch, hashlib, json, sys, urllib.request, urllib.error
lock, base, only, deep, diff = sys.argv[1:6]; deep = deep == "1"
doc = json.load(open(lock))
if doc.get("format") != 1: sys.exit("lock_verify: unsupported lock format")
bases = [base] if base else ([doc["origin"]] if doc.get("origin") else []) + list(doc.get("mirrors", []))
bases = [b.rstrip("/") for b in bases]
if not bases: sys.exit("lock_verify: the lock names no origin; pass --cdn or --from")

import os, time
VER = "2"
UA = {"User-Agent": "dot-cloud-lock-verify/" + VER}  # the CDN answers Python's default urllib UA with 403
TRIES = int(os.environ.get("LOCK_VERIFY_TRIES", "5")); BACKOFF = float(os.environ.get("LOCK_VERIFY_BACKOFF", "0.5"))
def transient(st): return st in (0, 403, 429) or 500 <= st <= 599  # CDN edge throttling or a hiccup; 404 and the rest are real answers
limited = []  # every URL still throttled after all retries: reported apart from missing objects
def req(url, method="GET"):
    for attempt in range(TRIES):
        delay = BACKOFF * (2 ** attempt)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, method=method, headers=UA), timeout=30) as r:
                return r.status, (r.read() if method == "GET" else b""), r.headers.get("Content-Length")
        except urllib.error.HTTPError as e:
            st = e.code
            try: delay = max(delay, min(float(e.headers.get("Retry-After", 0)), 30))
            except ValueError: pass
        except (urllib.error.URLError, OSError): st = 0
        if not transient(st): return st, b"", None
        if attempt + 1 < TRIES: time.sleep(delay)
    limited.append(url); return st, b"", None

def manifest(b, pid, ver):
    st, data, _ = req("%s/%s/%s/manifest.json" % (b, pid, ver))
    if st != 200: return None, data, "manifest.json answered %s%s" % (st or "no reply", " (rate limited or blocked, still after %d tries)" % TRIES if transient(st) else "")
    try:
        env = json.loads(data); p = env["payload"]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))), data, ""
    except Exception as e: return None, data, "manifest is not a signed envelope (%s)" % type(e).__name__

def files(m): return {f["path"]: f for f in m.get("files", [])}

bad = 0; seen = 0
for p in doc["packs"]:
    pid, ver = p["id"], p["version"]
    if only and not any(fnmatch.fnmatchcase(n, only) for n in (pid, pid.split("/")[-1], p.get("into", ""))): continue
    seen += 1; errs = []; m = None
    for b in bases:
        m, raw, why = manifest(b, pid, ver)
        if m is not None and hashlib.sha256(raw).hexdigest() != p.get("manifest_sha256"):
            why = "manifest sha256 %s... is not the pinned %s..." % (hashlib.sha256(raw).hexdigest()[:12], str(p.get("manifest_sha256"))[:12]); m = None
        if m is not None: break
        errs.append("%s: %s" % (b, why))
    if m is None:
        bad += 1; print("FAIL %s %s: %s" % (pid, ver, "; ".join(errs))); continue
    for k, want in (("content_id", pid), ("version", ver)):
        if k in m and m[k] != want: errs.append("payload %s is %s" % (k, m[k]))
    objs = {}
    for f in m.get("files", []): objs[f["sha256"]] = f["size"]
    gone = wrong = lim = 0
    for sha, size in sorted(objs.items()):
        url = "%s/%s/%s/objects/%s/%s" % (b, pid, ver, sha[:2], sha)
        if deep:
            st, data, _ = req(url)
            if transient(st): lim += 1
            elif st != 200: gone += 1
            elif hashlib.sha256(data).hexdigest() != sha or len(data) != size: wrong += 1
        else:
            st, _, ln = req(url, "HEAD")
            if transient(st): lim += 1
            elif st != 200: gone += 1
            elif ln is not None and int(ln) != size: wrong += 1
    bun = (m.get("bundle") or {}).get("url_path")
    if bun:  # a warning, not a failure: a client whose bundle is missing downloads the objects one by one (docs/sources.md)
        st, _, _ = req("%s/%s/%s/%s" % (b, pid, ver, bun), "HEAD")
        if st != 200: print("warn %s %s: bundle %s answered %s (clients fall back to per-file objects)" % (pid, ver, bun, st or "no reply"))
    if lim: errs.append("%d object(s) could not be checked: rate limited or blocked (403/429/5xx) after %d tries, not known missing" % (lim, TRIES))
    if gone: errs.append("%d object(s) missing" % gone)
    if wrong: errs.append("%d object(s) with the wrong %s" % (wrong, "bytes" if deep else "size"))
    if errs: bad += 1; print("FAIL %s %s: %s" % (pid, ver, "; ".join(errs)))
    else: print("ok   %s %s: %d files, %d objects%s" % (pid, ver, len(m.get("files", [])), len(objs), " (hashed)" if deep else ""))
    if diff:
        o, _, why = manifest(b, pid, diff)
        if o is None: bad += 1; print("FAIL diff %s: %s" % (diff, why)); continue
        a, c = files(o), files(m)
        for path in sorted(set(a) | set(c)):
            if path not in a: print("  + %s" % path)
            elif path not in c: print("  - %s" % path)
            elif a[path]["sha256"] != c[path]["sha256"]: print("  ~ %s" % path)
        print("diff %s -> %s: +%d -%d ~%d" % (diff, ver, len(set(c) - set(a)), len(set(a) - set(c)), sum(1 for x in set(a) & set(c) if a[x]["sha256"] != c[x]["sha256"])))
if not seen: sys.exit("lock_verify: no lock entry matches")
if limited: print("lock_verify: %d request(s) stayed throttled after %d tries; run fewer verifies at once or raise LOCK_VERIFY_TRIES/LOCK_VERIFY_BACKOFF" % (len(limited), TRIES), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
