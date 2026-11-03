"""Mock site for upload_demo. PUT: /ok/* accepts, /fail/* is 500, /expired/* is 403.
POST /api/app/v1/packs/upload (manifest, next, finalize; needs a Bearer token) serves the objects under argv[3] (an out dir): the first `next` hands out expired URLs for half of them, later pages fresh ones.
argv: port, delay seconds, optional out dir."""
import base64, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


OBJS = []
if len(sys.argv) > 3:
    for d, _, fs in os.walk(os.path.join(sys.argv[3], "objects")):
        OBJS += [(f, os.path.getsize(os.path.join(d, f))) for f in fs]
GOT = set()
ROUND = [0]


class H(BaseHTTPRequestHandler):
    def _json(self, code, doc):
        b = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.headers.get("Authorization") != "Bearer testtoken":
            return self._json(401, {"ok": False, "code": "AUTH", "message": "no token"})
        a = body.get("action")
        if a == "manifest":
            return self._json(200, {"ok": True, "data": {"missing": len(OBJS), "present": 0}})
        if a == "next":
            first = ROUND[0] == 0
            ROUND[0] += 1
            todo = [(i, o) for i, o in enumerate(OBJS) if o[0] not in GOT]
            puts = [{"sha256": h, "size": n, "headers": {"x-test": "1"},
                     "url": "http://127.0.0.1:%s/%s/%s" % (sys.argv[1], "expired" if first and i % 2 else "ok", h)}
                    for i, (h, n) in todo]
            return self._json(200, {"ok": True, "data": {"puts": puts, "remaining": len(puts)}})
        if a == "finalize":
            return self._json(200, {"ok": True, "data": {"status": "READY", "manifestUrl": "u", "manifestSha256": "s"}})
        self._json(400, {"ok": False, "code": "BAD", "message": a})

    def do_PUT(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        time.sleep(float(sys.argv[2]))
        kind = self.path.split("/")[1]
        code = {"fail": 500, "expired": 403}.get(kind, 200)
        if code == 200:
            GOT.add(self.path.split("/")[2])
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
