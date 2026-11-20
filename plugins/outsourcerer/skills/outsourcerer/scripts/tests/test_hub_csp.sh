#!/usr/bin/env bash
# sealed-run-requires: none
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_hub_csp.sh -- the CSP 'sha256-…' for hub.html's inline <script> must
# match the bytes actually served on EVERY GET /, not the file as it was when the
# server started. A running hub that upgrades hub.html used to keep the startup
# hash, so the browser blocked the inline script and the page hung on
# 'Loading your projects'. The hash is now computed from the served bytes; other
# routes use a cache keyed by the page's (mtime, size).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIB="$HERE/../lib"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/hub-csp-test.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
SRV=""
cleanup() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$OSRC_HOME/hub" "$TMP/pg"
# The page is served from --page; a copy under scratch means the test may rewrite
# its inline script without touching the real hub.html (the upgrade scenario).
cp "$LIB/hub.html" "$TMP/pg/page.html"
cp -R "$LIB/hub-assets" "$TMP/pg/hub-assets" 2>/dev/null || true

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# sha256 CSP hashes of every bare <script>…</script> block in an HTML file.
hashes_of() {
python3 - "$1" <<'PY'
import sys, re, hashlib, base64
d = open(sys.argv[1], "rb").read()
for m in re.finditer(rb"<script>(.*?)</script>", d, re.S):
    print("sha256-" + base64.b64encode(hashlib.sha256(m.group(1)).digest()).decode())
PY
}

echo "=== CSP script hash tracks the served page, not server start ==="
STK=0123456789abcdef0123456789abcdef
OSRC_HUB_TOKEN=$STK python3 -I "$LIB/hub_server.py" --port 0 --page "$TMP/pg/page.html" \
  --engine "$SRC" --osrc-home "$OSRC_HOME" --no-open >"$TMP/serve.log" 2>&1 &
SRV=$!
URL=""
for _ in $(seq 1 120); do URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*/' "$TMP/serve.log" | head -1)"; [ -n "$URL" ] && break; sleep 0.1; done
[ -n "$URL" ] || { bad "hub serve printed no URL: $(head -3 "$TMP/serve.log")"; echo "RESULT: $pass passed, $fail failed"; exit 1; }

# GET / once: CSP must whitelist exactly the inline script the body carries.
curl -sS --max-time 10 -D "$TMP/h1" -o "$TMP/b1" "$URL" || { bad "GET / failed"; echo "RESULT: $pass passed, $fail failed"; exit 1; }
csp1="$(grep -i '^content-security-policy:' "$TMP/h1" | tr -d '\r')"
missing=""
while read -r h; do [ -n "$h" ] && ! grep -qF "'$h'" <<<"$csp1" && missing="$missing $h"; done < <(hashes_of "$TMP/b1")
[ -z "$missing" ] && [ -n "$(hashes_of "$TMP/b1")" ] \
  && ok "GET / CSP whitelists the inline script actually served" \
  || bad "CSP missing served-script hash(s):$missing | csp: $csp1"

# The upgrade: rewrite the page's inline script under the running server.
python3 - "$TMP/pg/page.html" <<'PY'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
assert b"<script>" in d and b"/*csp-bump*/" not in d
d = d.replace(b"<script>", b"<script>/*csp-bump*/", 1)
open(p, "wb").write(d)
PY
sleep 0.2   # let mtime/size settle past filesystem timestamp granularity

curl -sS --max-time 10 -D "$TMP/h2" -o "$TMP/b2" "$URL" || { bad "second GET / failed"; echo "RESULT: $pass passed, $fail failed"; exit 1; }
grep -q 'csp-bump' "$TMP/b2" || bad "second GET / served the pre-edit page"
csp2="$(grep -i '^content-security-policy:' "$TMP/h2" | tr -d '\r')"
old_h="$(hashes_of "$TMP/b1" | head -1)"; new_h="$(hashes_of "$TMP/b2" | head -1)"
[ -n "$old_h" ] && [ "$old_h" != "$new_h" ] || bad "test setup: bump did not change the script hash ($old_h vs $new_h)"
grep -qF "'$new_h'" <<<"$csp2" && ! grep -qF "'$old_h'" <<<"$csp2" \
  && ok "after hub.html changes, GET / CSP carries the NEW script hash, not the startup one" \
  || bad "stale CSP after page edit: old='$old_h' new='$new_h' csp: $csp2"

# Non-page routes share the header path: their CSP must track the page too
# (mtime+size cache), so an asset fetch after the upgrade is not stale either.
curl -sS --max-time 10 -D "$TMP/h3" -o /dev/null "$URL"assets/hub-home.js
csp3="$(grep -i '^content-security-policy:' "$TMP/h3" | tr -d '\r')"
grep -qF "'$new_h'" <<<"$csp3" \
  && ok "asset route CSP also follows the edited page (mtime+size cache)" \
  || bad "asset route CSP stale: $csp3"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
