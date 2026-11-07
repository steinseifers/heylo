#!/usr/bin/env python3
"""Fake Microsoft token endpoint for tests. Usage: fake_oauth.py PORT [EXPIRES_IN]
POST /<tenant>/oauth2/v2.0/token: authorization_code -> tokens; refresh_token -> new tokens with a ROTATED refresh token
(the old one stops working, like real refresh-token rotation); refresh_token=bad -> invalid_grant. GET /stats -> request counts."""
import base64, json, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]); EXPIRES = int(sys.argv[2]) if len(sys.argv) > 2 else 3600
stats = {"code": 0, "refresh": 0, "failed": 0}; valid = set(); n = [0]; lock = threading.Lock()

def jwt(claims):
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
    return f"{b({'alg':'none'})}.{b(claims)}.sig"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        d = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self): self.reply(200, stats)
    def do_POST(self):
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        g = lambda k: form.get(k, [""])[0]
        time.sleep(0.1)  # widen the window for concurrent refreshes
        with lock:
            if g("grant_type") == "authorization_code":
                if not g("code_verifier") or g("code") != "good-code": stats["failed"] += 1; return self.reply(400, {"error": "invalid_grant", "error_description": "bad code"})
                stats["code"] += 1
            elif g("grant_type") == "refresh_token":
                if g("refresh_token") not in valid: stats["failed"] += 1; return self.reply(400, {"error": "invalid_grant", "error_description": "refresh token invalid"})
                valid.discard(g("refresh_token")); stats["refresh"] += 1
            else: return self.reply(400, {"error": "unsupported_grant_type"})
            n[0] += 1; rt = f"refresh-{n[0]}"; valid.add(rt)
            self.reply(200, {"access_token": f"access-{n[0]}", "refresh_token": rt, "expires_in": EXPIRES,
                             "id_token": jwt({"preferred_username": "me@example.invalid", "name": "Me", "tid": "tenant-123"})})

print("fake_oauth on", PORT, flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
