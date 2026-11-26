#!/usr/bin/env bash
# test_spend_lib_failclosed.sh — a missing, unreadable or truncated spend-path lib (an interrupted
# plugin update) must REFUSE launches, never skip the gate (torture-room arch F2, spend part). The
# lib loader proves every spend lib loaded whole (end-of-file sentinels); otherwise each gate entry
# point becomes a refusal. Runs on a private copy of the scripts; a stub devin logs any launch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME" "$T/bin" "$T/osrc/disk-policy"
printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$T/osrc/disk-policy/settings"
cat > "$T/bin/devin" <<EOF
#!/usr/bin/env bash
echo "devin \$*" >> "$T/devin.log"
case "\${1:-}" in auth) echo "Logged in as stub@example.com" ;; esac
exit 0
EOF
chmod +x "$T/bin/devin"

mk() {  # mk <name> -> a private copy of the scripts (no tests) at $T/<name>
  mkdir -p "$T/$1"
  ( cd "$ROOT" && tar cf - --exclude=./tests . ) | ( cd "$T/$1" && tar xf - )
}
# probe <copy> -> what a sourced engine's gates do with a Free id (catalog check off)
probe() {  # sourced, the engine finds lib/ from $PWD, so run inside the copy
  cd "$T/$2" && OSRC_HOME="$T/osrc" OSRC_SOURCED=1 OSRC_FREE_CATALOG_CHECK=0 PATH="$T/bin:$PATH" \
    bash -c '. "$1/outsourcerer.sh" >/dev/null 2>&1; ( _osrc_spend_gate dv swe-2-high devin probe ) >/dev/null 2>&1; echo "gate-rc=$?"
      ( _osrc_session_spend_gate ) >/dev/null 2>&1; echo "session-rc=$?"' _ "$T/$2" 2>&1 | tr '\n' ' '
}

mk intact
case "$(probe x intact)" in "gate-rc=0 "*) ok "intact libs: a Free launch passes the real gate" ;; *) bad "intact: $(probe x intact)" ;; esac
ln -s "$T/intact" "$T/link-intact"
case "$(probe x link-intact)" in "gate-rc=0 "*) ok "intact libs via symlink: the real gate still runs" ;; *) bad "intact via symlink: $(probe x link-intact)" ;; esac

mk nospend; rm -f "$T/nospend/lib/spend.sh"
mk trunc;   head -n 300 "$ROOT/lib/spend.sh" > "$T/trunc/lib/spend.sh"
mk unread;  chmod 000 "$T/unread/lib/spend-paths.sh"
mk syntax;  { head -n 60 "$ROOT/lib/devin-free.sh"; printf '_osrc_broken() { if then; }\n'; tail -n +61 "$ROOT/lib/devin-free.sh"; } > "$T/syntax/lib/devin-free.sh"
mk nocaps;  rm -f "$T/nocaps/lib/caps.sh"
for v in nospend trunc unread syntax nocaps; do
  [ "$v" = unread ] && [ -r "$T/unread/lib/spend-paths.sh" ] && { ok "unread: skipped (running as root, chmod 000 is still readable)"; continue; }
  r="$(probe x "$v")"
  case "$r" in "gate-rc=70 session-rc=70 ") ok "$v: every gate refuses (rc 70)" ;; *) bad "$v: gates did not refuse: $r" ;; esac
  # through a symlinked path (a PATH launcher, or macOS /var -> /private/var) the engine's realpath
  # differs from SCRIPT_DIR, so the second lib loader re-sources lib/*.sh: it must not undo the stubs
  ln -s "$T/$v" "$T/link-$v"; r="$(probe x "link-$v")"
  case "$r" in "gate-rc=70 session-rc=70 ") ok "$v via symlink: every gate still refuses" ;; *) bad "$v via symlink: second loader restored gates: $r" ;; esac
done

# end to end: an interrupted update that lost lib/spend.sh launches nothing
: > "$T/devin.log"
out="$( cd "$T" && OSRC_HOME="$T/osrc" PATH="$T/bin:$PATH" OSRC_PROVIDER=devin OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 \
        OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash "$T/nospend/outsourcerer.sh" run -m swe-2-high "say hi" 2>&1 </dev/null )"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- ' -p' "$T/devin.log" && grep -q 'missing or damaged' <<<"$out"; then
  ok "e2e: run with lib/spend.sh missing refuses and launches nothing (rc=$rc)"
else bad "e2e: rc=$rc launched='$(cat "$T/devin.log")' out=$(printf '%s' "$out" | tail -2)"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
