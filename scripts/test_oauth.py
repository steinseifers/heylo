#!/usr/bin/env python3
"""Runs `Inkwell --oauthtest` against fake_oauth.py (long-lived, then short-lived tokens)."""
import json, os, subprocess, sys, time, urllib.request
here = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Caches/inkwell-build/release/Inkwell")
rc = 0
for port, expires, mode in [(14340, 3600, "long"), (14341, 1, "short")]:
    srv = subprocess.Popen([sys.executable, os.path.join(here, "fake_oauth.py"), str(port), str(expires)], stdout=subprocess.DEVNULL)
    time.sleep(0.5)
    try:
        env = dict(os.environ, INKWELL_OAUTH_BASE=f"http://127.0.0.1:{port}", INKWELL_OAUTH_CLIENT_ID="test-client", INKWELL_HOME=os.popen("mktemp -d").read().strip())
        r = subprocess.run([binary, "--oauthtest", str(port), mode], env=env, timeout=60); rc |= r.returncode
        print("server saw:", json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/stats")))
    finally:
        srv.terminate()
sys.exit(rc)
