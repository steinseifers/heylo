#!/usr/bin/env python3
"""Keeps Resources/Localizable.xcstrings in sync with the UI strings found in Sources/ (literals passed to
SwiftUI views and toasts). New keys are added without a German value; run with --missing to list untranslated keys.
Interpolations `\\(x)` become %@ (or %lld when the expression looks like a number), matching SwiftUI's keys."""
import glob, json, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cat_path = os.path.join(root, "Resources", "Localizable.xcstrings")
pats = [(re.compile(r'\b(?:Text|Button|Toggle|Section|Label|TextField|SecureField|Picker|Menu|Link|DisclosureGroup|GroupBox|Stepper|ContentUnavailableView|LabeledContent)\(\s*"((?:[^"\\]|\\.)*)"'), 1),
        (re.compile(r'\.(?:help|navigationTitle|navigationSubtitle|accessibilityLabel|accessibilityHint|badge)\(\s*"((?:[^"\\]|\\.)*)"'), 1),
        (re.compile(r'(?:prompt|description|message):\s*(?:Text\()?"((?:[^"\\]|\\.)*)"'), 1),
        (re.compile(r'\bshowToast\(\s*"((?:[^"\\]|\\.)*)"'), 1)]

# Helpers whose parameters are LocalizedStringKey (literals passed to them are catalog keys).
S = r'"((?:[^"\\]|\\.)*)"'
pats += [(re.compile(r'\b(?:legend|sectionLabel|link|pill|action|chip|sectionHeader)\(\s*' + S), 1),
         (re.compile(r'\bradio\([^"]*' + S + r',\s*' + S), 1),
         (re.compile(r'\bradio\([^"]*"(?:[^"\\]|\\.)*",\s*' + S), 1),
         (re.compile(r'\bmailboxRow\([^"]*"(?:[^"\\]|\\.)*",\s*' + S), 1),
         (re.compile(r'DatePickerSheet\(title:\s*' + S), 1),
         (re.compile(r'DatePickerSheet\(title:\s*' + S + r',\s*action:\s*' + S), 2)]
NUM = re.compile(r"(count|seconds|minutes|hours|days|months|total|number|emails|downloaded|\.n\b|Int\()", re.I)

def interp(s):
    out, i = "", 0
    while i < len(s):
        if s.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(s) and depth:
                depth += s[j] == "("; depth -= s[j] == ")"; j += 1
            expr = s[i + 2:j - 1]
            out += "%lld" if NUM.search(expr) else "%@"; i = j
        else:
            out += s[i]; i += 1
    return out.replace('\\"', '"').replace("\\n", "\n")

found = {}
for f in sorted(glob.glob(os.path.join(root, "Sources/**/*.swift"), recursive=True)):
    s = open(f).read()
    for rx, g in pats:
        for m in rx.finditer(s):
            t = interp(m.group(g))
            if re.search(r"[A-Za-z]{2}", re.sub(r"%(lld|@)", "", t)): found.setdefault(t, os.path.relpath(f, root))

cat = json.load(open(cat_path)) if os.path.exists(cat_path) else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
for k in found:
    cat["strings"].setdefault(k, {"extractionState": "manual", "localizations": {}})
def de(k):
    d = cat["strings"][k].get("localizations", {}).get("de", {})
    return d.get("stringUnit", {}).get("value") or ("plural" if d.get("variations") else None)
if "--missing" in sys.argv:
    for k in sorted(found):
        if not de(k): print(json.dumps(k, ensure_ascii=False))
    print(f"# {sum(1 for k in found if not de(k))} of {len(found)} untranslated", file=sys.stderr)
else:
    json.dump(cat, open(cat_path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
    print(f"{len(found)} strings, {sum(1 for k in found if de(k))} translated")
