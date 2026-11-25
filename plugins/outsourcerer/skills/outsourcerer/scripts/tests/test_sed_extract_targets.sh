#!/usr/bin/env bash
# Tests that load a function with `eval "$(sed -n '/^name() {/,/^}/p' FILE)"` silently get NOTHING
# when the function moves to another file: the test then runs with the function missing and fails
# for a confusing reason, or passes while testing nothing. (0.18.0: _devin_probe_pick moved to
# lib/devin-free.sh and test_devin_free_guard went red in all three release runs.)
# Every such extraction must find the function in the file it names, unless the same test also
# extracts that function from another file where it does exist (an explicit fallback).
cd "$(dirname "$0")/.." || exit 1
d="$(mktemp -d)"; export HOME="$d"; trap 'rm -rf "$d"' EXIT
python3 -I - >"$d/out" <<'EOF'
import glob, os, re
pat = re.compile(r"""sed -n '/\^([A-Za-z0-9_]+)\(\) \{/,/\^\}/p' "([^"]+)\"""")
def resolve(p):
    if p == "$SRC": return "outsourcerer.sh"
    m = re.match(r'\$SCRIPT_DIR/\.\./(.+)$', p)
    return m.group(1) if m else None
def has(f, name):
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            return re.search(r'^%s\(\) \{' % re.escape(name), fh.read(), re.M) is not None
    except OSError:
        return False
bad = 0; checked = 0
for t in sorted(glob.glob("tests/*.sh")):
    with open(t, encoding="utf-8", errors="replace") as fh:
        pairs = pat.findall(fh.read())
    found = {}
    for name, p in pairs:
        f = resolve(p)
        if f is None: continue          # a path the test builds itself ($FACTORY, $ENGINE): not checked here
        checked += 1
        found.setdefault(name, []).append((f, has(f, name)))
    for name, hits in found.items():
        if not any(ok for _, ok in hits):
            bad += 1
            print("MISSING %s: %s() is in none of %s" % (t, name, ", ".join(f for f, _ in hits)))
print("CHECKED %d" % checked)
EOF
out="$(cat "$d/out")"
pass=0; fail=0
if printf '%s\n' "$out" | grep -q '^MISSING'; then
  printf '%s\n' "$out" | grep '^MISSING' | sed 's/^/FAIL: /'; fail=$((fail + 1))
else
  n="$(printf '%s\n' "$out" | sed -n 's/^CHECKED //p')"
  if [ "${n:-0}" -gt 0 ]; then echo "PASS: all $n function extractions find their function"; pass=$((pass + 1))
  else echo "FAIL: found no extractions to check (pattern broken?)"; fail=$((fail + 1)); fi
fi
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
