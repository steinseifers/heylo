#!/usr/bin/env python3
"""Runs `Inkwell --smtptest` against fake_smtp.py and checks exactly one delivery was logged."""
import os, subprocess, sys, tempfile, time
here = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Caches/inkwell-build/release/Inkwell")
log = tempfile.mktemp()
srv = subprocess.Popen([sys.executable, os.path.join(here, "fake_smtp.py"), "14330", log], stdout=subprocess.DEVNULL)
time.sleep(0.4)
try:
    r = subprocess.run([binary, "--smtptest", "14330"], env=dict(os.environ, INKWELL_INSECURE_LOCAL="1"), timeout=30)
    lines = open(log).read().splitlines() if os.path.exists(log) else []
    ok = r.returncode == 0 and len(lines) == 1
    print(("✓" if len(lines) == 1 else "✗") + f" fake SMTP logged {len(lines)} delivery")
    sys.exit(0 if ok else 1)
finally:
    srv.terminate()
