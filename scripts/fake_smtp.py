#!/usr/bin/env python3
"""Plaintext fake SMTP server that counts deliveries (not a real server).

Usage: fake_smtp.py PORT LOGFILE
Every accepted message appends one line "<Message-ID>\t<recipients>" to LOGFILE, so tests can
assert "exactly one send per scheduled message". Accepts AUTH PLAIN/LOGIN/XOAUTH2 with any credentials.
"""
import re, socketserver, sys, threading

PORT, LOG = int(sys.argv[1]), sys.argv[2]
log_lock = threading.Lock()


class H(socketserver.StreamRequestHandler):
    def w(self, s):
        self.wfile.write(s.encode()); self.wfile.flush()

    def handle(self):
        self.w("220 fake.invalid ESMTP ready\r\n")
        rcpt = []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            cmd = line.decode(errors="replace").rstrip("\r\n")
            up = cmd.upper()
            if up.startswith("EHLO"):
                self.w("250-fake.invalid\r\n250-AUTH PLAIN LOGIN XOAUTH2\r\n250 8BITMIME\r\n")
            elif up.startswith("HELO"):
                self.w("250 fake.invalid\r\n")
            elif up.startswith("AUTH LOGIN"):
                self.w("334 VXNlcm5hbWU6\r\n"); self.rfile.readline()
                self.w("334 UGFzc3dvcmQ6\r\n"); self.rfile.readline()
                self.w("235 ok\r\n")
            elif up.startswith("AUTH XOAUTH2"):
                import base64
                tok = base64.b64decode(cmd.split(" ", 2)[2]).decode(errors="replace")
                if "auth=Bearer bad" in tok:
                    self.w("334 eyJzdGF0dXMiOiI0MDEifQ==\r\n"); self.rfile.readline()
                    self.w("535 5.7.3 Authentication unsuccessful\r\n")
                else:
                    self.w("235 ok\r\n")
            elif up.startswith("AUTH"):
                self.w("235 ok\r\n")
            elif up.startswith("MAIL FROM"):
                rcpt = []; self.w("250 ok\r\n")
            elif up.startswith("RCPT TO"):
                rcpt.append(cmd.split(":", 1)[1].strip()); self.w("250 ok\r\n")
            elif up == "DATA":
                self.w("354 go ahead\r\n")
                data = []
                while True:
                    l = self.rfile.readline()
                    if l in (b".\r\n", b""):
                        break
                    data.append(l)
                raw = b"".join(data)
                m = re.search(rb"^Message-ID:\s*(\S+)", raw, re.I | re.M)
                with log_lock, open(LOG, "a") as f:
                    f.write(f"{m.group(1).decode() if m else '?'}\t{','.join(rcpt)}\n")
                self.w("250 queued\r\n")
            elif up.startswith("RSET"):
                rcpt = []; self.w("250 ok\r\n")
            elif up.startswith("NOOP"):
                self.w("250 ok\r\n")
            elif up.startswith("QUIT"):
                self.w("221 bye\r\n"); return
            else:
                self.w("502 not implemented\r\n")


class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    request_queue_size = 128
    daemon_threads = True


if __name__ == "__main__":
    print(f"fake_smtp on 127.0.0.1:{PORT}, log {LOG}", flush=True)
    S(("127.0.0.1", PORT), H).serve_forever()
