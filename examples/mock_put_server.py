"""Mock presigned-PUT target for upload_demo: /ok/* accepts, /fail/* is 500, /expired/* is 403; argv: port, delay seconds."""
import sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def do_PUT(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        time.sleep(float(sys.argv[2]))
        code = {"fail": 500, "expired": 403}.get(self.path.split("/")[1], 200)
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
