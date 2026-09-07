# Webhook の受け手。X-Cms-Signature を secret で照合し、結果を 1 行 JSON でログに書く
import hmac, hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET_FILE = sys.argv[1]
LOG = sys.argv[2]
STATUS = int(sys.argv[3]) if len(sys.argv) > 3 else 200

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        secret = open(SECRET_FILE).read().strip()
        ts = self.headers.get("X-Cms-Timestamp", "")
        expected = "sha256=" + hmac.new(secret.encode(), f"{ts}.{body}".encode(), hashlib.sha256).hexdigest()
        record = {
            "path": self.path,
            "event": self.headers.get("X-Cms-Event"),
            "delivery": self.headers.get("X-Cms-Delivery"),
            "contentType": self.headers.get("Content-Type"),
            "signatureOk": hmac.compare_digest(expected, self.headers.get("X-Cms-Signature", "")),
            "body": json.loads(body),
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.send_response(STATUS)
        self.end_headers()
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 9999), H).serve_forever()
