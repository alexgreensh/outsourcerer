#!/bin/bash
# L3 approver policy table: every row of fixtures/approver-table.tsv must classify exactly as
# expected (approve|hold). Rows are real commands from orchestrator sessions (FINDINGS 2026-11-13)
# plus the dangerous shapes that must HOLD: rm outside the worktree, redirects out, $(...),
# backticks, git push/reset --hard, tmux kill-server, multi-line (continuation) commands, secrets,
# installs, publishing, another worktree. "⏎" in a row stands for a newline in the command.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLS="$HERE/../lib/approver_classify.py"
TABLE="$HERE/fixtures/approver-table.tsv"
TMP="$(mktemp -d "$HERE/.test-approver.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/osrc-home"; mkdir -p "$OSRC_HOME"
ROOT="$TMP/repo"; OTHER="$TMP/other-wt"
mkdir -p "$ROOT/src" "$ROOT/tests" "$OTHER/src"; git -C "$ROOT" init -q; git -C "$OTHER" init -q
NL="$(printf '\nx')"; NL="${NL%x}"
rows=0; approves=0; holds=0
TAB="$(printf '\t')"
while IFS= read -r line; do
  # Split on single tabs by hand: `read` with IFS=tab would collapse the empty path column.
  want="${line%%"$TAB"*}"; line="${line#*"$TAB"}"; kind="${line%%"$TAB"*}"; line="${line#*"$TAB"}"
  path="${line%%"$TAB"*}"; cmd="${line#*"$TAB"}"
  case "$want" in ''|'#'*) continue ;; esac
  rows=$((rows+1))
  cmd="${cmd//\{ROOT\}/$ROOT}"; cmd="${cmd//\{OTHER\}/$OTHER}"; cmd="${cmd//⏎/$NL}"
  path="${path//\{ROOT\}/$ROOT}"; path="${path//\{OTHER\}/$OTHER}"
  got="$(printf '%s' "$cmd" | (cd "$ROOT" && python3 -I "$CLS" --root "$ROOT" --kind "$kind" --path "$path"))"
  case "$want" in approve) approves=$((approves+1)) ;; hold) holds=$((holds+1)) ;; esac
  if [ "${got%% *}" = "$want" ]; then ok; else bad "[$kind] '$cmd' expected $want, got: $got"; fi
done < "$TABLE"
[ "$rows" -ge 40 ] && ok || bad "table has only $rows rows (need >= 40)"
[ "$approves" -ge 15 ] && [ "$holds" -ge 25 ] && ok || bad "table needs both sides (approve=$approves hold=$holds)"

# Deny-by-default under a broken environment: no root -> hold; root == $HOME -> hold.
got="$(printf 'ls' | python3 -I "$CLS" --root "$TMP/does-not-exist")"; [ "${got%% *}" = hold ] && ok || bad "missing root did not hold: $got"
got="$(printf 'ls' | HOME="$TMP" python3 -I "$CLS" --root "$TMP")"; [ "${got%% *}" = hold ] && ok || bad "root==HOME did not hold: $got"
got="$(printf 'ls' | python3 -I "$CLS" --bogus x)"; [ "${got%% *}" = hold ] && ok || bad "usage error did not hold: $got"

echo "rows=$rows approve=$approves hold=$holds"
# review round 4 B: the approved names form never prints a multi-line value; the old cut form did
SECRET_TWO_LINE="$(printf 'first=line\nOSRC_PEM_BODY_7f3a')"; export SECRET_TWO_LINE
out="$(bash -c 'compgen -e' 2>/dev/null)"
case "$out" in *OSRC_PEM_BODY_7f3a*|*first=line*) bad "compgen -e printed a value line" ;; *) ok ;; esac
case "$(env | cut -d= -f1)" in *OSRC_PEM_BODY_7f3a*) ok ;; *) bad "(control) env | cut -d= -f1 was expected to leak the 2nd value line" ;; esac
unset SECRET_TWO_LINE

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
