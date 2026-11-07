#!/usr/bin/env python3
"""Runs `Inkwell --snoozetest` against fake_imap_multi.py (keywords on, then off). Usage: test_snooze.py [path-to-Inkwell-binary]"""
import os, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Caches/inkwell-build/release/Inkwell")
env = dict(os.environ, INKWELL_INSECURE_LOCAL="1", INKWELL_HOME=os.popen("mktemp -d").read().strip())
rc = 0
for port, srv_args, mode, flag in [(14310, [], [], "--snoozetest"), (14311, ["--no-keywords"], ["nokeywords"], "--snoozetest"), (14312, [], [], "--snoozeflow")]:
    srv = subprocess.Popen([sys.executable, os.path.join(here, "fake_imap_multi.py"), str(port)] + srv_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.4)
    try:
        r = subprocess.run([binary, flag, str(port)] + mode, env=dict(env, INKWELL_HOME=os.popen("mktemp -d").read().strip()), timeout=90)
        rc |= r.returncode
    finally:
        srv.terminate()
sys.exit(rc)
