#!/usr/bin/env python3
"""Fetches a PUBLISHED pack version into the layout a publish dry-run writes (OUT/manifest.json, OUT/objects/<2>/<sha>),
so tools/pack_boot_test.sh can boot what servers and players are actually sent, not what a checkout would publish.

  tools/pack_fetch.py ORIGIN CONTENT_ID OUT [--version V]
    ORIGIN      the content root, e.g. https://content.gamespice.net/content (prod) or https://tmcdevgames.net/content (dev)
    CONTENT_ID  owner/id, e.g. gamemann/game-hungario
    --version   a version; default: the one latest.json names
Prints the version fetched. Exit 0 ok, 1 fetch or hash failure, 2 usage.

The manifest's signature is not checked here (the mounter does that); every object is checked against its sha256.
Objects come from the manifest's bundle when it declares one, the rest one by one from <version>/objects/<2>/<sha>.
"""
import hashlib
import io
import json
import os
import sys
import urllib.request
import zipfile


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "gamespice-pack-boot"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def main(argv):
    args, version = [], None
    i = 0
    while i < len(argv):
        if argv[i] == "--version":
            version = argv[i + 1]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    origin, cid, out = args[0].rstrip("/"), args[1], args[2]
    if version is None:
        version = json.loads(get("%s/%s/latest.json" % (origin, cid)))["version"]
    base = "%s/%s/%s" % (origin, cid, version)
    signed = json.loads(get(base + "/manifest.json"))
    payload = signed.get("payload", signed)
    if isinstance(payload, str):
        import base64
        payload = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(payload, f)

    want = {str(f["sha256"]).lower(): f for f in payload["files"]}
    have = set()

    def put(sha, data):
        if hashlib.sha256(data).hexdigest() != sha:
            return False
        d = os.path.join(out, "objects", sha[:2])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, sha), "wb") as f:
            f.write(data)
        have.add(sha)
        return True

    bundle = payload.get("bundle") or {}
    if bundle.get("url_path"):
        try:
            data = get("%s/%s" % (base, bundle["url_path"].lstrip("/")))
            if hashlib.sha256(data).hexdigest() == str(bundle.get("sha256", "")).lower():
                with zipfile.ZipFile(io.BytesIO(data)) as z:
                    for n in z.namelist():
                        if n.lower() in want:
                            put(n.lower(), z.read(n))
            else:
                print("pack_fetch: %s %s: bundle hash mismatch; fetching objects one by one" % (cid, version), file=sys.stderr)
        except Exception as e:  # the per-object path below is the fallback, as in the client
            print("pack_fetch: %s %s: bundle failed (%s); fetching objects one by one" % (cid, version, e), file=sys.stderr)
    bad = 0
    for sha, f in want.items():
        if sha in have:
            continue
        rel = f.get("url_path") or "objects/%s/%s" % (sha[:2], sha)
        try:
            ok = put(sha, get("%s/%s" % (base, rel.lstrip("/"))))
        except Exception as e:
            ok = False
            print("pack_fetch: %s: %s" % (f.get("path"), e), file=sys.stderr)
        if not ok:
            bad += 1
            print("pack_fetch: %s %s: %s (%s) did not fetch or failed its hash" % (cid, version, f.get("path"), sha), file=sys.stderr)
    print(version)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
