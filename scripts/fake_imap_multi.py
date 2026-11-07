#!/usr/bin/env python3
"""Small multi-folder IMAP server for testing multi-client behaviour (not a real server).

Shared state under one lock, so concurrent clients race like on a real server.
Implements: CAPABILITY LOGIN LIST CREATE DELETE SELECT/EXAMINE APPEND UID SEARCH/FETCH/STORE/COPY/MOVE/EXPUNGE
EXPUNGE NOOP LOGOUT UNSELECT, plus test hook X-DUMP (JSON of all folders).

Usage: fake_imap_multi.py PORT [--no-keywords] [--no-condstore] [--no-move] [--drop-keywords-on-move]
  --no-keywords            PERMANENTFLAGS without \\*; custom keywords are silently dropped
  --no-condstore           no CONDSTORE/MODSEQ, UNCHANGEDSINCE not understood
  --no-move                no MOVE capability (clients fall back to COPY + EXPUNGE)
  --drop-keywords-on-move  MOVE loses custom keywords (some servers do)
UID MOVE/COPY of a UID that no longer exists answers OK without COPYUID (like Dovecot):
the client can tell whether it won a race by the COPYUID response.
"""
import json, re, socketserver, sys, threading

args = sys.argv[1:]
PORT = int(args[0])
KEYWORDS = "--no-keywords" not in args
CONDSTORE = "--no-condstore" not in args
MOVE = "--no-move" not in args
DROP_ON_MOVE = "--drop-keywords-on-move" in args

lock = threading.RLock()
state = {"modseq": 1}
folders = {}  # name -> {"validity": int, "next": int, "msgs": {uid: {"flags": set, "raw": bytes, "modseq": int}}}
SYSTEM = {"\\Seen", "\\Answered", "\\Flagged", "\\Deleted", "\\Draft"}


def new_folder():
    return {"validity": 100 + len(folders), "next": 1, "msgs": {}}


folders["INBOX"] = new_folder()


def bump():
    state["modseq"] += 1
    return state["modseq"]


def add_msg(folder, raw, flags, keep_modseq=None):
    f = folders[folder]
    uid = f["next"]
    f["next"] += 1
    f["msgs"][uid] = {"flags": set(flags), "raw": raw, "modseq": keep_modseq or bump()}
    return uid


def tokens(s):
    """Splits an IMAP argument string into quoted strings, parenthesised groups and atoms."""
    out, i = [], 0
    while i < len(s):
        if s[i] == " ":
            i += 1
        elif s[i] == '"':
            m = re.match(r'"((?:[^"\\]|\\.)*)"', s[i:])
            out.append(re.sub(r"\\(.)", r"\1", m.group(1)))
            i += m.end()
        elif s[i] == "(":
            depth, j = 0, i
            while j < len(s):
                depth += s[j] == "("
                depth -= s[j] == ")"
                j += 1
                if depth == 0:
                    break
            out.append(("group", s[i + 1:j - 1]))
            i = j
        else:
            m = re.match(r"[^ ]+", s[i:])
            out.append(m.group(0))
            i += m.end()
    return out


def seq_set(spec, uids):
    """Sequence-number set -> UIDs (position in UID order, 1-based)."""
    order = sorted(uids)
    return [order[i - 1] for i in uid_set(spec, list(range(1, len(order) + 1)))]


def uid_set(spec, uids):
    top = max(uids) if uids else 0
    sel = set()
    for part in spec.split(","):
        a, _, b = part.partition(":")
        lo = top if a == "*" else int(a)
        hi = top if (b == "*" or (not b and a == "*")) else int(b or a)
        if lo > hi:
            lo, hi = hi, lo
        sel |= {u for u in uids if lo <= u <= hi}
    return sorted(sel)


class H(socketserver.StreamRequestHandler):
    sel = None
    readonly = False

    def w(self, s):
        self.wfile.write(s if isinstance(s, bytes) else s.encode())
        self.wfile.flush()

    def caps(self):
        c = "IMAP4rev1 IDLE UIDPLUS UNSELECT LITERAL+"
        return c + (" MOVE" if MOVE else "") + (" CONDSTORE" if CONDSTORE else "")

    def handle(self):
        self.w(f"* OK [CAPABILITY {self.caps()}] fake multi ready\r\n")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.decode().rstrip("\r\n")
            tag, _, rest = line.partition(" ")
            cmd = rest.split(" ", 1)[0].upper()
            try:
                if self.dispatch(tag, cmd, rest) == "bye":
                    return
            except Exception as e:  # keep the server alive for the other clients
                self.w(f"{tag} BAD {type(e).__name__}: {e}\r\n")

    # --- helpers -----------------------------------------------------------------------
    def box(self):
        return folders[self.sel]["msgs"] if self.sel else {}

    def dispatch(self, tag, cmd, rest):
        a = rest[len(cmd):].strip()
        if cmd == "CAPABILITY":
            self.w(f"* CAPABILITY {self.caps()}\r\n{tag} OK done\r\n")
        elif cmd == "LOGIN":
            self.w(f"{tag} OK [CAPABILITY {self.caps()}] logged in\r\n")
        elif cmd == "LIST":
            with lock:
                for n in folders:
                    self.w(f'* LIST () "/" "{n}"\r\n')
            self.w(f"{tag} OK done\r\n")
        elif cmd == "CREATE":
            name = tokens(a)[0]
            with lock:
                if name in folders:
                    return self.w(f"{tag} NO [ALREADYEXISTS] exists\r\n")
                folders[name] = new_folder()
            self.w(f"{tag} OK done\r\n")
        elif cmd == "DELETE":
            with lock:
                folders.pop(tokens(a)[0], None)
            self.w(f"{tag} OK done\r\n")
        elif cmd in ("SELECT", "EXAMINE"):
            name = tokens(a)[0]
            with lock:
                if name not in folders:
                    return self.w(f"{tag} NO [NONEXISTENT] no such folder\r\n")
                f = folders[name]
                self.sel, self.readonly = name, cmd == "EXAMINE"
                perm = "\\Answered \\Flagged \\Deleted \\Seen \\Draft" + (" \\*" if KEYWORDS else "")
                self.w(f"* {len(f['msgs'])} EXISTS\r\n* 0 RECENT\r\n* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n"
                       f"* OK [PERMANENTFLAGS ({perm})] ok\r\n* OK [UIDVALIDITY {f['validity']}] ok\r\n* OK [UIDNEXT {f['next']}] ok\r\n")
                if CONDSTORE:
                    self.w(f"* OK [HIGHESTMODSEQ {state['modseq']}] ok\r\n")
            self.w(f"{tag} OK [{'READ-ONLY' if self.readonly else 'READ-WRITE'}] selected\r\n")
        elif cmd == "UNSELECT":
            self.sel = None
            self.w(f"{tag} OK done\r\n")
        elif cmd == "APPEND":
            m = re.match(r'(".*?"|\S+)(?: \((.*?)\))?(?: "[^"]*")? \{(\d+)(\+?)\}$', a)
            name, flags, n, plus = tokens(m.group(1))[0], (m.group(2) or "").split(), int(m.group(3)), m.group(4)
            if not plus:
                self.w("+ ready\r\n")
            raw = self.rfile.read(n)
            self.rfile.readline()
            with lock:
                if name not in folders:
                    return self.w(f"{tag} NO [TRYCREATE] no such folder\r\n")
                flags = [x for x in flags if KEYWORDS or x in SYSTEM]
                uid = add_msg(name, raw, flags)
                v = folders[name]["validity"]
            self.w(f"{tag} OK [APPENDUID {v} {uid}] appended\r\n")
        elif cmd == "UID":
            sub, _, rest2 = a.partition(" ")
            self.uid_cmd(tag, sub.upper(), rest2.strip())
        elif cmd in ("FETCH", "STORE", "SEARCH", "COPY", "MOVE"):
            self.uid_cmd(tag, cmd, a, seq=True)
        elif cmd == "EXPUNGE":
            with lock:
                gone = [u for u, m in self.box().items() if "\\Deleted" in m["flags"]]
                self.expunge(gone)
            self.w(f"{tag} OK done\r\n")
        elif cmd in ("NOOP", "CHECK"):
            self.w(f"{tag} OK done\r\n")
        elif cmd == "X-DUMP":
            with lock:
                dump = {n: {str(u): {"flags": sorted(m["flags"]), "id": (re.search(rb"Message-ID: (\S+)", m["raw"]) or [None, b"?"])[1].decode(),
                                     "modseq": m["modseq"]} for u, m in f["msgs"].items()} for n, f in folders.items()}
            self.w(f"* X-DUMP {json.dumps(dump)}\r\n{tag} OK done\r\n")
        elif cmd == "LOGOUT":
            self.w(f"* BYE\r\n{tag} OK done\r\n")
            return "bye"
        else:
            self.w(f"{tag} BAD unknown command {cmd}\r\n")

    def expunge(self, uids):
        box = self.box()
        order = sorted(box)
        for u in sorted(uids, reverse=True):
            self.w(f"* {order.index(u) + 1} EXPUNGE\r\n")
            del box[u]
            order.remove(u)

    def uid_cmd(self, tag, sub, a, seq=False):
        t = tokens(a)
        sel = (lambda spec, uids: seq_set(spec, uids)) if seq else uid_set
        with lock:
            box = self.box()
            if sub == "SEARCH":
                crit = a.upper()
                hits = sorted(box)
                m = re.search(r"KEYWORD (\S+)", a, re.I)
                if m:
                    hits = [u for u in hits if m.group(1) in box[u]["flags"]]
                if "UNSEEN" in crit:
                    hits = [u for u in hits if "\\Seen" not in box[u]["flags"]]
                m = re.search(r"UID (\S+)", a)
                if m:
                    hits = [u for u in hits if u in uid_set(m.group(1), list(box))]
                self.w("* SEARCH " + " ".join(map(str, hits)) + f"\r\n{tag} OK done\r\n")
            elif sub == "FETCH":
                items = t[1][1].upper() if isinstance(t[1], tuple) else t[1].upper()
                since = re.search(r"CHANGEDSINCE (\d+)", a, re.I)
                order = sorted(box)
                for u in sel(t[0], order):
                    m = box[u]
                    if since and m["modseq"] <= int(since.group(1)):
                        continue
                    parts = [f"UID {u}"]
                    if "FLAGS" in items:
                        parts.append("FLAGS (" + " ".join(sorted(m["flags"])) + ")")
                    if CONDSTORE and ("MODSEQ" in items or since):
                        parts.append(f"MODSEQ ({m['modseq']})")
                    out = f"* {order.index(u) + 1} FETCH (" + " ".join(parts)
                    lits = []
                    if "BODY.PEEK[HEADER]" in items or "BODY[HEADER]" in items:
                        lits.append(("BODY[HEADER]", m["raw"].split(b"\r\n\r\n")[0] + b"\r\n\r\n"))
                    if re.search(r"BODY(\.PEEK)?\[\]", items):
                        lits.append(("BODY[]", m["raw"]))
                    self.w(out)
                    for name, data in lits:
                        self.w(f" {name} {{{len(data)}}}\r\n")
                        self.w(data)
                    self.w(")\r\n")
                self.w(f"{tag} OK done\r\n")
            elif sub == "STORE":
                m = re.match(r"(\S+) (?:\(UNCHANGEDSINCE (\d+)\) )?([+-]?)FLAGS(\.SILENT)? \((.*)\)$", a, re.I)
                if self.readonly:
                    return self.w(f"{tag} NO [READ-ONLY] read-only\r\n")
                uids = sel(m.group(1), list(box))
                unchanged, op, silent = m.group(2), m.group(3), m.group(4)
                flags = {x for x in m.group(5).split() if KEYWORDS or x in SYSTEM}
                modified = []
                for u in uids:
                    msg = box[u]
                    if unchanged and CONDSTORE and msg["modseq"] > int(unchanged):
                        modified.append(u)
                        continue
                    msg["flags"] = msg["flags"] | flags if op == "+" else msg["flags"] - flags if op == "-" else flags
                    msg["modseq"] = bump()
                    if not silent:
                        self.w(f"* {sorted(box).index(u) + 1} FETCH (UID {u} FLAGS ({' '.join(sorted(msg['flags']))}) MODSEQ ({msg['modseq']}))\r\n")
                note = f" [MODIFIED {','.join(map(str, modified))}]" if modified else ""
                self.w(f"{tag} OK{note} stored\r\n")
            elif sub in ("COPY", "MOVE"):
                if sub == "MOVE" and not MOVE:
                    return self.w(f"{tag} BAD MOVE not supported\r\n")
                dest = t[1]
                if dest not in folders:
                    return self.w(f"{tag} NO [TRYCREATE] no such folder\r\n")
                uids = sel(t[0], list(box))  # vanished UIDs simply drop out (lost race)
                pairs = []
                for u in uids:
                    msg = box[u]
                    flags = msg["flags"] if not (sub == "MOVE" and DROP_ON_MOVE) else msg["flags"] & SYSTEM
                    pairs.append((u, add_msg(dest, msg["raw"], flags)))
                if pairs:
                    src = ",".join(str(p[0]) for p in pairs)
                    dst = ",".join(str(p[1]) for p in pairs)
                    self.w(f"* OK [COPYUID {folders[dest]['validity']} {src} {dst}] copied\r\n")
                if sub == "MOVE":
                    self.expunge([p[0] for p in pairs])
                self.w(f"{tag} OK {sub} done\r\n")
            elif sub == "EXPUNGE":
                gone = [u for u in uid_set(t[0], list(box)) if "\\Deleted" in box[u]["flags"]]
                self.expunge(gone)
                self.w(f"{tag} OK done\r\n")
            else:
                self.w(f"{tag} BAD unknown UID command {sub}\r\n")


class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    request_queue_size = 128
    daemon_threads = True


if __name__ == "__main__":
    print(f"fake_imap_multi on 127.0.0.1:{PORT}", flush=True)
    S(("127.0.0.1", PORT), H).serve_forever()
