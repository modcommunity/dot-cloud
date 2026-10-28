#!/usr/bin/env python3
"""Local stand-in for the site's pack calls (claim, manifest, next, finalize, versions, fail) and the presigned PUT, for test_publish_pack.sh.
Prints PORT=<n> then serves until killed. State is in memory; every request is appended to the log file given as argv[1]."""
import base64, hashlib, json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1]
S = {"claims": {}, "objects": set(), "versions": [], "next_id": 1}
LOCK = threading.Lock()


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, doc):
        b = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _err(self, status, code, msg):
        self._send(status, {"ok": False, "code": code, "message": msg})  # the site's flat app-API envelope

    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        want = self.path.rsplit("/", 1)[-1]
        if hashlib.sha256(body).hexdigest() != want:
            return self._err(400, "checksum", "bad sha")
        with LOCK:
            S["objects"].add(want)
        log("PUT " + want)
        self._send(200, {})

    def do_POST(self):
        if self.path.startswith("/__approve/"):  # test hook: a reviewer approves a HELD version
            _, _, repo, ver = self.path.split("/")
            with LOCK:
                for v in S["versions"]:
                    if v["contentId"].endswith("/" + repo) and v["version"] == ver and v["status"] == "HELD":
                        v["status"] = "READY"
                        v["manifestUrl"] = "http://cdn.test/%s/%s/manifest.json" % (v["contentId"], ver)
                        return self._send(200, {})
            return self._err(404, "not_found", "nothing held")
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self._err(401, "auth", "bad token")
        n = int(self.headers.get("Content-Length", 0))
        b = json.loads(self.rfile.read(n))
        a = b.get("action")
        log("POST %s %s" % (self.path, a))
        with LOCK:
            if a == "claim":
                for v in S["versions"]:
                    if v["contentId"].endswith("/" + b["repoName"]) and v["version"] == b["version"]:
                        return self._err(409, "version_taken", "taken")
                for i, c in S["claims"].items():  # an unfinished claim keeps its version
                    if c["contentId"].endswith("/" + b["repoName"]) and c["version"] == b["version"] and not c.get("done"):
                        return self._err(409, "version_taken", "claim open")
                cid = "tester/" + b["repoName"]
                i = S["next_id"]; S["next_id"] += 1
                S["claims"][i] = {"contentId": cid, "version": b["version"], "files": []}
                return self._send(200, {"ok": True, "data": {"id": i, "contentId": cid}})
            if a == "versions":
                vs = [v for v in S["versions"] if not b.get("repoName") or v["contentId"].endswith("/" + b["repoName"])]
                vs += [{"id": i, "contentId": c["contentId"], "version": c["version"], "status": "CLAIMED", "fileCount": 0, "byteSize": 0}
                       for i, c in S["claims"].items() if not c.get("done") and (not b.get("repoName") or c["contentId"].endswith("/" + b["repoName"]))]
                return self._send(200, {"ok": True, "data": {"versions": vs[::-1]}})
            c = S["claims"].get(b.get("id"))
            if c is None:
                return self._err(404, "not_found", "no claim")
            if a == "manifest":
                m = json.loads(base64.b64decode(b["manifest"]))
                if "licences" not in m:
                    return self._err(400, "licence", "no licences")
                if m["content_id"] != c["contentId"] or m["version"] != c["version"]:
                    return self._err(400, "mismatch", "claim mismatch")
                c["raw"] = base64.b64decode(b["manifest"])
                c["shas"] = sorted({f["sha256"] for f in m["files"]} | ({m["bundle"]["sha256"]} if isinstance(m.get("bundle"), dict) and "sha256" in m["bundle"] else set()))
                miss = [h for h in c["shas"] if h not in S["objects"]]
                return self._send(200, {"ok": True, "data": {"objects": len(c["shas"]), "present": len(c["shas"]) - len(miss), "missing": len(miss), "missingBytes": 0}})
            if a == "next":
                miss = [h for h in c["shas"] if h not in S["objects"]]
                host = self.headers["Host"]
                puts = [{"sha256": h, "size": 1, "url": "http://%s/put/%s" % (host, h), "headers": {}} for h in miss[: b.get("max", 500)]]
                return self._send(200, {"ok": True, "data": {"puts": puts, "copied": 0, "remaining": max(0, len(miss) - len(puts)), "expiresInSec": 900}})
            if a == "finalize":
                if [h for h in c["shas"] if h not in S["objects"]]:
                    return self._err(409, "missing", "objects missing")
                sha = hashlib.sha256(c["raw"]).hexdigest()
                c["done"] = True
                held = c["contentId"].split("/")[-1].startswith("held")
                S["versions"].append({"contentId": c["contentId"], "version": c["version"], "status": "HELD" if held else "READY", "fileCount": len(c["shas"]), "byteSize": 0, "manifestSha": sha, "manifestUrl": ""})
                if held:
                    return self._send(200, {"ok": True, "data": {"status": "HELD", "message": "licence review"}})
                S["versions"][-1]["manifestUrl"] = "http://cdn.test/%s/%s/manifest.json" % (c["contentId"], c["version"])
                return self._send(200, {"ok": True, "data": {"status": "READY", "manifestUrl": S["versions"][-1]["manifestUrl"], "manifestSha256": sha}})
            if a == "fail":
                return self._send(200, {"ok": True, "data": {}})
        self._err(400, "bad_action", str(a))


TOKEN = sys.argv[2]
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print("PORT=%d" % srv.server_address[1], flush=True)
srv.serve_forever()
