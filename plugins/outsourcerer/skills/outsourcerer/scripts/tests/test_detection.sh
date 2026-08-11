#!/usr/bin/env bash
# Golden-log harness for the detectors — locks them against silent rot. Tests the REAL functions
# (_perm_denials, _printmode_needle, _last_marker) on inline fixture logs, each independently.
# The built-in needles stay fragmented in source (self-trip defense); this only READS them.
# Authored directly (the Devin lane kept getting SIGTERM'd on this tests-only item).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; mkdir -p "$OSRC_HOME"
OSRC_SOURCED=1 . "$SCRIPT"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'PASS: %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }

# 1) perm-wall: three genuine denials (two explicit needles + one is_error+generic on one line)
w="$TMP/perm.log"
{
  printf 'delegate requested permis''sions to write /etc/hosts\n'
  printf 'Tool execu''tion was rejected by workspace policy\n'
  printf '{"type":"result","is_error": true,"text":"Permission denied writing file"}\n'
} > "$w"
n="$(_perm_denials "$w")"
[ "$n" -ge 3 ] 2>/dev/null && ok "perm-wall: _perm_denials counts $n genuine denials (>=3)" \
  || no "perm-wall: expected >=3 denials, got '$n'"

# 2) FALSE-POSITIVE GUARD: source-like lines mentioning permission words, but no is_error and
#    no real needle -> must NOT be counted (the historically important case: a delegate that
#    merely READ permission-handling code).
w="$TMP/false.log"
{
  printf 'except PermissionError:  # maps to Permission denied / EACCES\n'
  printf 'if errno in (EACCES,): raise  # read-only file system guard\n'
  printf 'log.info("handled Permission denied gracefully")\n'
} > "$w"
n="$(_perm_denials "$w")"
[ "$n" = "0" ] && ok "false-positive guard: source mentioning perm words -> 0 denials" \
  || no "false-positive guard: expected 0, got '$n' (a healthy run would be wrongly killed)"

# 3) print-mode-hang: the real print-mode needle appears -> counted, and the needle helper matches
w="$TMP/printmode.log"
printf '%s\n' "$(_printmode_needle)" > "$w"
n="$(_perm_denials "$w")"
[ "$n" -ge 1 ] 2>/dev/null && ok "print-mode: _perm_denials counts the print-mode needle ($n)" \
  || no "print-mode: expected >=1, got '$n'"
grep -qF "$(_printmode_needle)" "$w" && ok "print-mode: needle helper string is present in log" \
  || no "print-mode: needle helper did not match its own emitted line"

# 4) needle-outside-tail: a real denial at the TOP, then > OSRC_PERM_TAIL lines of noise after it,
#    so the default tail window (400) must NOT see it -> 0. Proves tail-scoping.
w="$TMP/outside.log"
printf 'Tool execu''tion was rejected at the very top\n' > "$w"
i=0; while [ "$i" -lt 500 ]; do printf 'noise line %d nothing to see here\n' "$i"; i=$((i+1)); done >> "$w"
n="$(_perm_denials "$w")"
[ "$n" = "0" ] && ok "tail-scoping: a denial older than the tail window is not counted" \
  || no "tail-scoping: expected 0 (needle above the tail), got '$n'"

# 5) clean-done: a signed terminal marker is recognised by _last_marker
w="$TMP/done.log"
{ printf 'work happening\n'; printf 'OSRC::DONE#deadbeef final line\n'; } > "$w"
m="$(OSRC_MARK=deadbeef _last_marker "$w")"
[ -n "$m" ] && case "$m" in *OSRC::DONE*) ok "clean-done: signed OSRC::DONE recognised ('$m')" ;;
  *) no "clean-done: got marker '$m', expected OSRC::DONE" ;; esac \
  || no "clean-done: signed terminal marker not recognised"

# 6) forgery cross-check on the STRICT teardown parser: _last_marker deliberately accepts an
#    unsigned anchored marker as a fallback (documented), which is why the kill path uses the
#    stricter _fg_teardown_seen instead. That strict parser must reject a forged unsigned DONE
#    when OSRC_MARK is set, and accept the signed one.
w="$TMP/forge.log"
printf 'OSRC::DONE echoed by a chatty delegate\n' > "$w"
m="$(OSRC_MARK=deadbeef _fg_teardown_seen "$w")"
[ -z "$m" ] && ok "forgery: _fg_teardown_seen rejects an unsigned OSRC::DONE when OSRC_MARK is set" \
  || no "forgery: strict parser wrongly trusted an unsigned marker ('$m')"
w="$TMP/signed.log"; printf '{"text":"line\\nOSRC::DONE#deadbeef done"}\n' > "$w"
m="$(OSRC_MARK=deadbeef _fg_teardown_seen "$w")"
[ -n "$m" ] && ok "forgery: _fg_teardown_seen accepts the signed marker (line-anchored in a JSON stream)" \
  || no "forgery: strict parser missed a genuine signed marker"

# 7) PROSE forgery: even a SIGNED marker mentioned mid-sentence (not at a line/JSON boundary)
#    must NOT be trusted — it is anchored like _last_marker, so it cannot arm the teardown kill.
w="$TMP/prose.log"; printf 'I will print OSRC::DONE#deadbeef when the work is finished.\n' > "$w"
m="$(OSRC_MARK=deadbeef _fg_teardown_seen "$w")"
[ -z "$m" ] && ok "forgery: a signed marker echoed MID-PROSE is not trusted (anchored)" \
  || no "forgery: mid-prose signed marker wrongly trusted ('$m')"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
