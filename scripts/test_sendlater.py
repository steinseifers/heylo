#!/usr/bin/env python3
"""Send-later safety test: fake IMAP + fake SMTP, two racing instances, exactly one delivery per message."""
import collections, os, subprocess, sys, tempfile, time
here = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Caches/inkwell-build/release/Inkwell")
rc = 0
for imap_port, extra, mode in [(14350, [], []), (14351, ["--no-condstore"], ["nocondstore"])]:
    log = tempfile.mktemp()
    imap = subprocess.Popen([sys.executable, os.path.join(here, "fake_imap_multi.py"), str(imap_port)] + extra, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    smtp = subprocess.Popen([sys.executable, os.path.join(here, "fake_smtp.py"), str(imap_port + 10), log], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.6)
    try:
        env = dict(os.environ, INKWELL_INSECURE_LOCAL="1", INKWELL_HOME=os.popen("mktemp -d").read().strip())
        r = subprocess.run([binary, "--sendtest", str(imap_port), str(imap_port + 10)] + mode, env=env, timeout=240); rc |= r.returncode
        if not mode:
            ids = [l.split("\t")[0] for l in open(log).read().splitlines()] if os.path.exists(log) else []
            dup = {k: v for k, v in collections.Counter(ids).items() if v > 1}
            ok = len(ids) == len(set(ids)) and not dup
            print(("✓" if ok else "✗") + f" SMTP log: {len(ids)} deliveries, {len(set(ids))} distinct, duplicates: {dup or 'none'}")
            rc |= 0 if ok else 1
    finally:
        imap.terminate(); smtp.terminate()
# Flow through the real MailStore
log = tempfile.mktemp()
imap = subprocess.Popen([sys.executable, os.path.join(here, "fake_imap_multi.py"), "14360"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
smtp = subprocess.Popen([sys.executable, os.path.join(here, "fake_smtp.py"), "14370", log], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.6)
try:
    env = dict(os.environ, INKWELL_INSECURE_LOCAL="1", INKWELL_HOME=os.popen("mktemp -d").read().strip())
    rc |= subprocess.run([binary, "--sendflow", "14360", "14370", log], env=env, timeout=120).returncode
finally:
    imap.terminate(); smtp.terminate()
sys.exit(rc)
