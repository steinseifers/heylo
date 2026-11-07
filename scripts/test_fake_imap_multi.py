#!/usr/bin/env python3
"""Self-test for fake_imap_multi.py: racing UID MOVEs must have exactly one winner."""
import imaplib, subprocess, sys, threading, time, os, re

PORT = int(os.environ.get("PORT", "14301"))
srv = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "fake_imap_multi.py"), str(PORT)] + sys.argv[1:],
                       stdout=subprocess.DEVNULL)
time.sleep(0.4)
try:
    def conn():
        c = imaplib.IMAP4("127.0.0.1", PORT); c.login("u", "p"); return c
    a = conn()
    a.create("Snooze")
    msg = b"From: a@example.invalid\r\nSubject: t\r\nMessage-ID: <t1@example.invalid>\r\n\r\nbody\r\n"
    a.append("INBOX", "($Snz1)", None, msg)
    a.select("INBOX")
    typ, d = a.uid("SEARCH", None, "ALL"); uid = d[0].split()[0].decode()
    wins, lock = [], threading.Lock()
    def race():
        c = conn(); c.select("INBOX")
        typ, d = c.uid("MOVE", uid, "Snooze")
        won = any(b"COPYUID" in (x or b"") for x in (c.untagged_responses.get("OK") or []))
        with lock: wins.append(won)
    ts = [threading.Thread(target=race) for _ in range(20)]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert sum(wins) == 1, f"expected exactly one MOVE winner, got {sum(wins)}"
    b = conn(); b.select("Snooze"); typ, d = b.uid("FETCH", "1", "(FLAGS)")
    print("flags in target:", d[0])
    print("OK: 20 racing MOVEs, exactly 1 winner")
finally:
    srv.terminate()
