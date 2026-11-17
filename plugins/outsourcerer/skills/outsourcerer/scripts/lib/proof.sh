# shellcheck shell=bash
# lib/proof.sh -- proof files, the verification stamp and the three-rounds cap (0.17, lane S2).
#
#   proof run [--lane ID] [--dir DIR] [--base REF] [--cmd "<check>"]... [--method none|review --reason R] [--json]
#   proof show <lane> [--json] | stamp <lane> | check <lane> [sha] | sendback <lane> | reset <lane>
#   proof require [on|off]        gate every .DONE hand-in, not only lanes that already ran proof
#
# A lane's proof lives in its lane folder, $OSRC_HOME/proof/<lane>/:
#   proof.json   the last run, written ONLY by `proof run` (never by a model):
#     {schema:1, lane, head, dir, base, dirty, ts, method, reason, source, ok, stamp, round,
#      commands:[{cmd, exit, secs, pass, fail, tail:[<= 30 lines]}], totals:{pass,fail}|null,
#      guards:<S1 `guards run --json` object>|"unavailable", checks_changed:bool}
#     method: verify-run (the repo's .outsourcerer/verify, read from the BASE ref) | tests (--cmd or
#     the done contract's check:) | review | none. review and none carry a required reason.
#   rounds.json  {fails, stopped, counted:[keys], last:{why, lines}}: failed proof rounds. Every
#     failed run and every hand-in sent back for missing/stale proof is one round; a pass resets it.
#     After OSRC_PROOF_MAX_ROUNDS (3) failures the lane is stopped: no more retries or sendbacks,
#     `proof run` refuses, and Mission Control lists it under "needs you" with the last failing lines.
#   SENDBACK.md  the message a sent-back lane gets (delivered by `session send` when the lane is a
#     live managed session, otherwise relayed by the orchestrator: NEXT `proof sendback <lane>`).
#
# Checks come from the BASE ref or the orchestrator, never from the lane's worktree: the verify script
# is `git show <base>:.outsourcerer/verify`, the done contract is $OSRC_HOME/done/<lane>.json. A diff
# that edits .outsourcerer/ is recorded as checks_changed for the reviewer.
# Guards (lane S1): when `guards` is loaded, `proof run` stores `guards run --json` under .guards and a
# failing enforce result fails the proof; otherwise .guards is "unavailable" and the proof continues.

_osrc_proof_root() { printf '%s/proof' "$OSRC_HOME"; }
_osrc_proof_dir() { printf '%s/proof/%s' "$OSRC_HOME" "$1"; }
_osrc_proof_file() { printf '%s/proof/%s/proof.json' "$OSRC_HOME" "$1"; }
_osrc_proof_rounds_file() { printf '%s/proof/%s/rounds.json' "$OSRC_HOME" "$1"; }
_osrc_proof_max() { local n="${OSRC_PROOF_MAX_ROUNDS:-3}"; case "$n" in ''|*[!0-9]*|0) n=3 ;; esac; printf '%s' "$n"; }
_osrc_proof_id_ok() { case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }

# Atomic JSON write (tmp + mv); refuses broken JSON so a half-built record never replaces a good one.
_osrc_proof_put() { # <path> <json>
  local p="$1" tmp="$1.tmp.$$.$RANDOM"
  printf '%s\n' "$2" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$p" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null; return 1
}

_osrc_proof_rounds() { # <lane> -> rounds JSON (defaults when missing)
  local f; f="$(_osrc_proof_rounds_file "$1")"
  jq -c '{fails:(.fails // 0), stopped:(.stopped // false), counted:(.counted // []), last:(.last // null)}' "$f" 2>/dev/null \
    || printf '{"fails":0,"stopped":false,"counted":[],"last":null}'
}

osrc_proof_stopped() { [ "$(_osrc_proof_rounds "$1" | jq -r .stopped)" = true ]; }

# One failed round. <key> dedupes (the same stale hand-in seen twice is one round); empty = always count.
# Prints the new fail count; sets .stopped when it reaches the cap.
_osrc_proof_note_fail() { # <lane> <key> <why> [lines-json-array]
  local lane="$1" key="$2" why="$3" lines="${4:-[]}" r
  mkdir -p "$(_osrc_proof_dir "$lane")" 2>/dev/null || return 1
  printf '%s' "$lines" | jq -e 'type=="array"' >/dev/null 2>&1 || lines='[]'
  r="$(_osrc_proof_rounds "$lane" | jq -c --arg k "$key" --arg why "$why" --argjson lines "$lines" --argjson max "$(_osrc_proof_max)" '
    if $k != "" and (.counted | index($k)) != null then .
    else .fails += 1 | .counted = ((.counted + (if $k == "" then [] else [$k] end))[-20:])
         | .last = {why:$why, lines:$lines} | .stopped = (.fails >= $max) end')"
  _osrc_proof_put "$(_osrc_proof_rounds_file "$lane")" "$r" || return 1
  printf '%s' "$(printf '%s' "$r" | jq -r .fails)"
}

_osrc_proof_note_pass() { # <lane>
  mkdir -p "$(_osrc_proof_dir "$1")" 2>/dev/null || return 1
  _osrc_proof_put "$(_osrc_proof_rounds_file "$1")" '{"fails":0,"stopped":false,"counted":[],"last":null}'
}

# Pass/fail counts from a check's output, when the output shows them. Prints "<pass> <fail>" with "-"
# for a count it could not see. Understands "139 passed, 2 failed" (pytest/jest/bats/this repo's
# suites), "PASS: 12 FAIL: 0", TAP "ok N" / "not ok N", and per-line "PASS:" / "FAIL:" tallies.
_osrc_proof_counts() { # <logfile>
  python3 - "$1" <<'PY' 2>/dev/null || printf -- '- -'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
num_word = lambda words: re.compile(r"(\d+)\s+(?:tests?\s+)?(?:%s)\b" % words, re.I)
word_num = lambda words: re.compile(r"\b(?:%s)\s*[:=]\s*(\d+)" % words, re.I)
def last(pats):
    best = None
    for p in pats:
        for m in p.finditer(t):
            if best is None or m.start() > best[0]:
                best = (m.start(), m.group(1))
    return best[1] if best else None
p = last([num_word("passed|passing|pass|ok"), word_num("passed|pass")])
f = last([num_word("failed|failing|fail|failures?|errors?"), word_num("failed|fail|failures")])
if p is None and f is None:
    lines = t.splitlines()
    tp = sum(1 for l in lines if re.match(r"\s*(PASS:|ok \d)", l))
    tf = sum(1 for l in lines if re.match(r"\s*(FAIL:|not ok \d)", l))
    if tp or tf:
        p, f = str(tp), str(tf)
print("%s %s" % (p if p is not None else "-", f if f is not None else "-"))
PY
}

# Resolve a base ref that exists in <dir>: the given one, else origin/<it>; empty when neither exists.
_osrc_proof_base() { # <dir> <base>
  local d="$1" b="$2"
  [ -n "$b" ] || return 0
  if git -C "$d" rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1; then printf '%s' "$b"
  elif git -C "$d" rev-parse -q --verify "origin/$b^{commit}" >/dev/null 2>&1; then printf 'origin/%s' "$b"; fi
}

# The done contract's check command for a lane (session contract or remote lane), or nothing.
_osrc_proof_contract_cmd() { # <lane>
  local spec dw
  spec="$(jq -r '.spec // ""' "$OSRC_HOME/done/$1.json" 2>/dev/null)"
  case "$spec" in check:?*) printf '%s' "${spec#check:}"; return 0 ;; esac
  dw="$(jq -r '.done_when // ""' "$OSRC_HOME/remote/$1.json" 2>/dev/null)"
  [ -n "$dw" ] && printf '%s' "${dw#check:}"
  return 0
}

# Run one check in <dir>, bounded, output to <log>; appends one command record to _PR_CMDS.
_osrc_proof_one() { # <dir> <shell-command> <log> <label>
  local d="$1" c="$2" log="$3" label="$4" t0 t1 rc=0 counts pc fc
  t0="$(date +%s)"
  if type _osrc_run_timeout >/dev/null 2>&1; then
    _osrc_run_timeout "${OSRC_PROOF_CMD_SECS:-1800}" "$d" "$c" </dev/null >"$log" 2>&1 || rc=$?
  else
    ( cd "$d" && bash -c "$c" ) </dev/null >"$log" 2>&1 || rc=$?
  fi
  t1="$(date +%s)"
  counts="$(_osrc_proof_counts "$log")"; pc="${counts%% *}"; fc="${counts##* }"
  _PR_CMDS="$(jq -c --arg cmd "$label" --argjson rc "$rc" --argjson secs "$((t1 - t0))" --arg p "$pc" --arg f "$fc" \
    --arg tail "$(tail -n 30 "$log" 2>/dev/null | cut -c1-400)" \
    '. + [{cmd:$cmd, exit:$rc, secs:$secs, pass:(if $p=="-" then null else ($p|tonumber) end),
           fail:(if $f=="-" then null else ($f|tonumber) end), tail:($tail | split("\n"))}]' <<<"$_PR_CMDS")"
  return "$rc"
}

# S1's guards, when loaded (contract: lib/guards.sh header, S1 round 3). Sets _PR_GUARDS (JSON).
# rc 0 passed | 1 passed == false (the gate verdict, whatever the mode) | 2 the guards could not run
# (no base to pin, or no JSON): the proof fails, but the round is not charged to the lane.
# --base is always explicit: without it guards would pick a default, which may be the lane's own branch.
_osrc_proof_guards() { # <dir> <base> <lane>
  local d="$1" b="$2" lane="$3" out j
  _PR_GUARDS='"unavailable"'
  declare -F cmd_guards >/dev/null 2>&1 || return 0
  [ -n "$b" ] || { _PR_GUARDS='"error: no base ref to pin --base to"'; return 2; }
  out="$( cd "$d" && cmd_guards run --json --base "$b" --lane "$lane" 2>/dev/null )"
  # The contract is one JSON object; accept it pretty-printed too, else the last one-line object.
  j="$(printf '%s\n' "$out" | python3 -c '
import json, re, sys
t = sys.stdin.buffer.read().decode("utf-8", "replace"); best = ""; end = -1
for m in re.finditer(r"^[ \t]*\{", t, re.M):
    if m.start() < end:
        continue
    i = t.index("{", m.start())
    try:
        o, n = json.JSONDecoder().raw_decode(t, i)
        if isinstance(o, dict): best, end = json.dumps(o), n
    except ValueError:
        pass
print(best)' 2>/dev/null)"
  printf '%s' "$j" | jq -e 'type=="object" and (.passed|type) == "boolean"' >/dev/null 2>&1 \
    || { _PR_GUARDS='"error: guards run gave no JSON verdict"'; return 2; }
  _PR_GUARDS="$j"
  [ "$(jq -r .passed <<<"$j")" = true ] || return 1
  return 0
}

_osrc_proof_stamp_of() { # <proof-json> -> one line for review items and Mission Control
  jq -r '
    if .method == "none" then "unverified: " + (.reason // "no reason")
    elif .method == "review" then "review only: " + (.reason // "no reason")
    elif .ok != true then
      ([.commands[]? | select(.exit != 0)][0]) as $c
      | if $c == null then "failed: " + (.why // "guards failed") else "failed: " + ($c.cmd | .[0:60]) + " exit " + ($c.exit|tostring)
          + (if $c.fail != null then " (" + ($c.fail|tostring) + " fail)" else "" end) end
    elif .totals != null then "proved: " + (.totals.pass|tostring) + " pass, " + (.totals.fail|tostring) + " fail"
    else "proved: " + ((.commands|length)|tostring) + (if (.commands|length) == 1 then " check" else " checks" end) + " passed" end
    + (if .ok == true and .reviewer_required == true then "; reviewer must look (guards " + (if .guards.allowed != null then "allowed: " + .guards.allowed else "changed" end) + ")" else "" end)' <<<"$1"
}

# The engine behind `proof run` and the remote READY runner. Writes proof.json, counts the round.
# rc 0 proved | 1 failed | 2 usage | 4 stopped after the round cap.
# Inputs via _PR_* globals so the remote runner (bash 3.2, no namerefs) can call it too.
_osrc_proof_exec() { # <lane> <dir> <head> <base> <method> <reason> <source> <cmd>...
  local lane="$1" dir="$2" head="$3" base="$4" method="$5" reason="$6" source="$7" pdir log i=0 c ok=true rc dirty=false
  local changed=false totals vtmp="" why="" rec stamp n r
  shift 7
  pdir="$(_osrc_proof_dir "$lane")"; mkdir -p "$pdir" 2>/dev/null || { echo "proof: cannot create $pdir" >&2; return 2; }
  if osrc_proof_stopped "$lane"; then
    echo "proof: lane $lane is stopped after $(_osrc_proof_max) failed proof rounds; a person must look ($(_osrc_self) proof show $lane), then $(_osrc_self) proof reset $lane" >&2
    return 4
  fi
  if [ -n "$dir" ]; then
    [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ] && dirty=true
    if [ -n "$base" ] && [ -n "$(git -C "$dir" diff --name-only "$base...$head" -- .outsourcerer 2>/dev/null)" ]; then changed=true; fi
  fi
  _PR_CMDS='[]'; _PR_GUARDS='"unavailable"'
  for c in "$@"; do
    i=$((i + 1)); log="$pdir/run.$$.$i.log"
    case "$c" in
      verify@*) vtmp="$pdir/verify.$$"
        git -C "$dir" show "${c#verify@}:.outsourcerer/verify" > "$vtmp" 2>/dev/null && chmod 700 "$vtmp" \
          && _osrc_proof_one "$dir" "$(printf '%q' "$vtmp")" "$log" ".outsourcerer/verify (from ${c#verify@})" \
          || { ok=false; [ -s "$vtmp" ] || why="could not read .outsourcerer/verify from ${c#verify@}"; }
        rm -f "$vtmp" ;;
      *) _osrc_proof_one "$dir" "$c" "$log" "$c" || ok=false ;;
    esac
  done
  local grc=0 nocount=""
  case "$method" in none|review) ;; *) _osrc_proof_guards "$dir" "$base" "$lane" || grc=$? ;; esac
  case "$grc" in
    1) ok=false; why="guards blocked the change: $(jq -r '[.failed[]? | .guard] | join(", ")' <<<"$_PR_GUARDS")" ;;
    2) ok=false; nocount=1; why="guards could not run ($(jq -r . <<<"$_PR_GUARDS")); not counted against the lane" ;;
  esac
  [ "$dirty" = false ] || { ok=false; why="tracked files have uncommitted changes, so the run did not test $head"; }
  totals="$(jq -c 'if any(.[]; .pass != null or .fail != null)
                   then {pass:([.[].pass // 0]|add), fail:([.[].fail // 0]|add)} else null end' <<<"$_PR_CMDS")"
  rec="$(jq -cn --arg lane "$lane" --arg head "$head" --arg dir "$dir" --arg base "$base" --argjson dirty "$dirty" \
    --argjson ts "$(date +%s)" --arg method "$method" --arg reason "$reason" --arg source "$source" --argjson ok "$ok" \
    --argjson cmds "$_PR_CMDS" --argjson totals "$totals" --argjson guards "$_PR_GUARDS" --argjson changed "$changed" --arg why "$why" '
    {schema:1, lane:$lane, head:$head, dir:$dir, base:$base, dirty:$dirty, ts:$ts, method:$method, reason:$reason,
     source:$source, ok:$ok, commands:$cmds, totals:$totals, guards:$guards, checks_changed:$changed}
    + (if $why == "" then {} else {why:$why} end)
    + {reviewer_required:((($guards|type) == "object") and ($guards.reviewer_required == true))}')"
  stamp="$(_osrc_proof_stamp_of "$rec")"
  if [ "$ok" = true ]; then _osrc_proof_note_pass "$lane"; n=0
  elif [ -n "$nocount" ]; then n="$(_osrc_proof_rounds "$lane" | jq -r .fails)"
  else
    n="$(_osrc_proof_note_fail "$lane" "" "$stamp" "$(jq -c '[.commands[] | select(.exit != 0) | .tail[]] | .[-30:]' <<<"$rec")")"
  fi
  rec="$(jq -c --arg s "$stamp" --argjson n "${n:-0}" '. + {stamp:$s, round:$n}' <<<"$rec")"
  _osrc_proof_put "$(_osrc_proof_file "$lane")" "$rec" || { echo "proof: could not write $(_osrc_proof_file "$lane")" >&2; return 2; }
  rm -f "$pdir"/run.$$.*.log 2>/dev/null
  _PR_RECORD="$rec"
  [ "$ok" = true ] && return 0
  r="$(_osrc_proof_rounds "$lane")"
  [ "$(jq -r .stopped <<<"$r")" = true ] && _osrc_proof_needs_you "$lane"
  return 1
}

# Lane stopped: one "needs you" record for Mission Control (hub reads it) with the last failing lines.
_osrc_proof_needs_you() { # <lane>
  local r; r="$(_osrc_proof_rounds "$1")"
  _osrc_proof_put "$(_osrc_proof_dir "$1")/needs-you.json" \
    "$(jq -c --arg lane "$1" --argjson ts "$(date +%s)" '{lane:$lane, ts:$ts, rounds:.fails, why:(.last.why // ""), lines:((.last.lines // [])[-12:])}' <<<"$r")"
}

cmd_proof() {
  local sub="${1:-}"; shift || true
  have jq || die "proof needs jq"
  case "$sub" in
    run) _osrc_proof_run "$@" ;;
    show) _osrc_proof_show "$@" ;;
    stamp) _osrc_proof_id_ok "${1:-}" || die "proof stamp <lane>"; osrc_proof_stamp "$1"; echo ;;
    check) _osrc_proof_id_ok "${1:-}" || die "proof check <lane> [sha]"; osrc_proof_gate "$1" "${2:-}" ;;
    sendback) _osrc_proof_id_ok "${1:-}" || die "proof sendback <lane>"
      [ -f "$(_osrc_proof_dir "$1")/SENDBACK.md" ] || die "no sendback recorded for $1"
      echo "--- relay this to lane '$1' ---"; cat "$(_osrc_proof_dir "$1")/SENDBACK.md" ;;
    reset) _osrc_proof_id_ok "${1:-}" || die "proof reset <lane>"
      _osrc_proof_note_pass "$1" && rm -f "$(_osrc_proof_dir "$1")/needs-you.json" && echo "proof rounds reset for $1" ;;
    require) mkdir -p "$(_osrc_proof_root)"
      case "${1:-}" in on) : > "$(_osrc_proof_root)/require"; echo "proof required on every .DONE hand-in" ;;
        off) rm -f "$(_osrc_proof_root)/require"; echo "proof required only for lanes that have run proof" ;;
        '') [ -f "$(_osrc_proof_root)/require" ] && echo on || echo off ;;
        *) die "proof require [on|off]" ;; esac ;;
    *) die "proof: run [--lane ID] [--dir DIR] [--base REF] [--cmd \"<check>\"]... [--method none|review --reason R] [--json] | show <lane> [--json] | stamp <lane> | check <lane> [sha] | sendback <lane> | reset <lane> | require [on|off]" ;;
  esac
}

_osrc_proof_run() {
  local lane="" dir="" base="" method="" reason="" json="" head src vb cc rc=0
  _PR_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane) lane="${2:-}"; shift 2 ;;
      --dir) dir="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --cmd) [ -n "${2:-}" ] || die "--cmd needs a command"; _PR_ARGS+=("$2"); shift 2 ;;
      --method) method="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      --json) json=1; shift ;;
      *) die "proof run: unknown option '$1'" ;;
    esac
  done
  dir="${dir:-$PWD}"; dir="$(cd "$dir" 2>/dev/null && pwd -P)" || die "proof run: no such directory"
  head="$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" || die "proof run: $dir is not a git checkout with a commit"
  if [ -z "$lane" ]; then lane="${OUTSOURCERER_TMUX:-}"; fi
  if [ -z "$lane" ]; then lane="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"; fi
  _osrc_proof_id_ok "$lane" || die "proof run: bad lane id '$lane' (pass --lane, letters/digits/._- only)"
  [ -n "$base" ] || base="$(jq -r '.base // ""' "$OSRC_HOME/remote/$lane.json" 2>/dev/null)"
  [ -n "$base" ] || base=main
  base="$(_osrc_proof_base "$dir" "$base")"
  case "$method" in
    none|review) [ -n "${reason//[[:space:]]/}" ] || die "proof run --method $method needs --reason \"<why this lane is not proved by a run>\""
      [ "${#_PR_ARGS[@]}" -eq 0 ] || die "proof run: --method $method takes no --cmd"
      src=manual ;;
    ''|tests|verify-run)
      if [ "${#_PR_ARGS[@]}" -gt 0 ]; then method=tests; src=cmd
      else
        src=""
        if [ -n "$base" ] && git -C "$dir" cat-file -e "$base:.outsourcerer/verify" 2>/dev/null; then
          _PR_ARGS+=("verify@$base"); method=verify-run; src=verify
        fi
        cc="$(_osrc_proof_contract_cmd "$lane")"
        if [ -n "$cc" ]; then _PR_ARGS+=("$cc"); [ -n "$method" ] || method=tests; src="${src:+$src+}done-contract"; fi
        [ "${#_PR_ARGS[@]}" -gt 0 ] || die "proof run: no checks for $lane. Pass --cmd \"<test command>\", commit .outsourcerer/verify on the base branch, set a done contract (check:...), or say why not: --method none --reason \"...\""
      fi ;;
    *) die "proof run: --method is none or review (verify-run and tests are set by what ran)" ;;
  esac
  if [ "${#_PR_ARGS[@]}" -gt 0 ]; then _osrc_proof_exec "$lane" "$dir" "$head" "$base" "$method" "$reason" "$src" "${_PR_ARGS[@]}" || rc=$?
  else _osrc_proof_exec "$lane" "$dir" "$head" "$base" "$method" "$reason" "$src" || rc=$?; fi
  case "$rc" in 2|4) return "$rc" ;; esac
  if [ -n "$json" ]; then cat "$(_osrc_proof_file "$lane")"; return "$rc"; fi
  printf '%s @ %s: %s\n' "$lane" "${head:0:7}" "$(jq -r .stamp <<<"$_PR_RECORD")"
  printf 'proof: %s\n' "$(_osrc_proof_file "$lane")"
  if [ "$rc" != 0 ]; then
    jq -r '.commands[] | select(.exit != 0) | "--- " + .cmd + " (exit " + (.exit|tostring) + "), last lines:", (.tail[-15:][])' <<<"$_PR_RECORD"
    jq -r 'if (.guards|type) == "object" and .guards.passed == false then (.guards.failed[]? | "--- guard " + .guard + ":", ((.what // [])[] | "  WHAT: " + .), "  FIX: " + (.fix // "")) else empty end' <<<"$_PR_RECORD"
    if osrc_proof_stopped "$lane"; then echo "STOPPED: $(_osrc_proof_max) failed rounds. Do not retry; a person looks next."
    else echo "round $(jq -r .round <<<"$_PR_RECORD") of $(_osrc_proof_max) failed: fix the failures above, commit, run proof again."; fi
  fi
  return "$rc"
}

_osrc_proof_show() {
  local lane="${1:-}" f
  _osrc_proof_id_ok "$lane" || die "proof show <lane> [--json]"
  f="$(_osrc_proof_file "$lane")"
  if [ "${2:-}" = --json ]; then
    jq -cn --slurpfile p <(cat "$f" 2>/dev/null || echo null) --argjson r "$(_osrc_proof_rounds "$lane")" '{proof:($p[0] // null), rounds:$r}'
    return 0
  fi
  if [ -f "$f" ]; then
    jq -r '"lane " + .lane + " @ " + .head[0:7] + "  method " + .method + "  " + .stamp,
      (.commands[] | "  " + (if .exit == 0 then "ok  " else "FAIL" end) + " " + .cmd + "  (" + (.secs|tostring) + "s)"),
      "  guards: " + (if (.guards|type) == "object" then ((.guards.mode // "?") + (if .guards.passed then ", passed" else ", failed" end)) else (.guards|tostring) end)
      + (if .checks_changed then "  [the diff edits .outsourcerer/: reviewer, look]" else "" end)' "$f"
  else echo "no proof for $lane yet"; fi
  _osrc_proof_rounds "$lane" | jq -r '"rounds failed: " + (.fails|tostring) + " of " + "'"$(_osrc_proof_max)"'" + (if .stopped then "  STOPPED, needs a person" else "" end),
    (if .last != null and .stopped then ("last failure: " + .last.why), (.last.lines[-12:][] | "  " + .) else empty end)'
}

osrc_proof_stamp() { # <lane> -> stamp line, or "no proof"
  local f; f="$(_osrc_proof_file "$1")"
  if [ -f "$f" ]; then jq -r '.stamp // ""' "$f"; else printf 'no proof'; fi
}

# The READY / done gate. rc 0 prints the stamp; rc 1 prints why the hand-in goes back; rc 2 = stopped.
# <head> defaults to the current HEAD of the checkout the proof ran in.
osrc_proof_gate() { # <lane> [head]
  local lane="$1" head="${2:-}" f p
  if osrc_proof_stopped "$lane"; then printf 'stopped after %s failed proof rounds; needs a person' "$(_osrc_proof_max)"; return 2; fi
  f="$(_osrc_proof_file "$lane")"
  [ -f "$f" ] || { printf 'no proof.json for %s: run `%s proof run --lane %s` in the lane worktree' "$lane" "$(_osrc_self)" "$lane"; return 1; }
  p="$(cat "$f")"
  if [ -z "$head" ]; then
    head="$(git -C "$(jq -r '.dir // ""' <<<"$p")" rev-parse -q --verify HEAD 2>/dev/null)" \
      || { printf 'the proof checkout %s is gone; rerun proof' "$(jq -r .dir <<<"$p")"; return 1; }
  fi
  [ "$(jq -r .head <<<"$p")" = "$head" ] || { printf 'proof is for %s but the head is %s; rerun proof on the new head' "$(jq -r '.head[0:7]' <<<"$p")" "${head:0:7}"; return 1; }
  [ "$(jq -r .ok <<<"$p")" = true ] || { printf 'proof failed: %s' "$(jq -r .stamp <<<"$p")"; return 1; }
  printf '%s' "$(jq -r .stamp <<<"$p")"
}

# Hand-in without valid proof: count the round (once per <key>), write SENDBACK.md, deliver it to a
# live managed session when there is one. Sets _PR_SB_HOW: sent | relay | stopped. Never pings the user;
# only a lane that hit the round cap surfaces, and it surfaces on Mission Control.
osrc_proof_sendback() { # <lane> <why> <key> [counted: the failed proof run already counted this round]
  local lane="$1" why="$2" key="$3" n sb msg
  _PR_SB_HOW=relay
  if [ "${4:-}" = counted ]; then
    if osrc_proof_stopped "$lane"; then _PR_SB_HOW=stopped; return 0; fi
    n="$(_osrc_proof_rounds "$lane" | jq -r .fails)"
  else
    if osrc_proof_stopped "$lane"; then _PR_SB_HOW=stopped; return 0; fi
    n="$(_osrc_proof_note_fail "$lane" "$key" "hand-in sent back: $why")" || n=0
  fi
  if osrc_proof_stopped "$lane"; then _osrc_proof_needs_you "$lane"; _PR_SB_HOW=stopped; return 0; fi
  sb="$(_osrc_proof_dir "$lane")/SENDBACK.md"
  { printf '# Hand-in not accepted (round %s of %s)\n\n%s\n\n' "$n" "$(_osrc_proof_max)" "$why"
    printf 'Run your checks with `%s proof run --lane %s` in your worktree (it writes proof.json; never write it by hand), fix what fails, commit, then hand in again.\n' "$(_osrc_self)" "$lane"
    printf 'After %s failed rounds the lane stops and a person takes over.\n' "$(_osrc_proof_max)"
  } > "$sb.tmp.$$" && mv -f "$sb.tmp.$$" "$sb"
  msg="Hand-in not accepted (proof round $n of $(_osrc_proof_max)): $why. Details: $sb"
  if [ "${OSRC_PROOF_NO_SEND:-0}" != 1 ] && type _managed_endpoint_live >/dev/null 2>&1 && _managed_endpoint_live "$lane" "$lane" 2>/dev/null; then
    _managed_session_send "$lane" "$msg" >/dev/null 2>&1 && _PR_SB_HOW=sent
  fi
  return 0
}

# Does a .DONE hand-in for <lane> need proof? Yes when `proof require on`, or the lane is proof-aware
# (it has a lane folder: it ran proof before, or was sent back).
osrc_proof_required() { # <lane>
  [ -f "$(_osrc_proof_root)/require" ] || [ "${OSRC_PROOF_REQUIRE:-}" = 1 ] || [ -d "$(_osrc_proof_dir "$1")" ]
}

# supervise --watch hook: <lane>.DONE written. rc 0 = accept (event unchanged). rc 1 = replace the
# event with _PR_EV_KIND/_PR_EV_DETAIL/_PR_EV_NEXT: sent back, stopped, or proved but guards say a
# reviewer must look (an --allow or released-after-blocks pass, or edited checks).
osrc_proof_handin() { # <lane> <fingerprint>
  local lane="$1" fp="$2" why rc=0 d hit=""
  _osrc_proof_id_ok "$lane" || return 0
  # L1.DONE belongs to the session osrc-auto-L1 when that is the only proof folder ending in -L1.
  if [ ! -d "$(_osrc_proof_dir "$lane")" ]; then
    for d in "$(_osrc_proof_root)"/*-"$lane"; do [ -d "$d" ] || continue; [ -z "$hit" ] || { hit=""; break; }; hit="${d##*/}"; done
    [ -z "$hit" ] || lane="$hit"
  fi
  osrc_proof_required "$lane" || return 0
  why="$(osrc_proof_gate "$lane")" || rc=$?
  if [ "$rc" = 0 ]; then
    osrc_proof_reviewer_required "$lane" || return 0
    _PR_EV_KIND=done
    _PR_EV_DETAIL="$lane hand-in proved, but guards require a reviewer: $(osrc_proof_review_note "$lane" | tr '\n' ' ')"
    _PR_EV_NEXT="$(_osrc_self) review queue add $(printf '%q' "$(git -C "$(jq -r .dir "$(_osrc_proof_file "$lane")")" rev-parse --abbrev-ref HEAD 2>/dev/null)") --repo $(printf '%q' "$(jq -r .dir "$(_osrc_proof_file "$lane")")")"
    return 1
  fi
  osrc_proof_sendback "$lane" "$why" "handin:$fp"
  _PR_EV_KIND=failed
  case "$_PR_SB_HOW" in
    stopped) _PR_EV_DETAIL="$lane stopped after $(_osrc_proof_max) failed proof rounds; needs a person: $why"
             _PR_EV_NEXT="$(_osrc_self) proof show $lane" ;;
    sent)    _PR_EV_DETAIL="$lane hand-in sent back automatically ($why)"
             _PR_EV_NEXT="$(_osrc_self) proof show $lane" ;;
    *)       _PR_EV_DETAIL="$lane hand-in not accepted ($why); relay the sendback"
             _PR_EV_NEXT="$(_osrc_self) proof sendback $lane" ;;
  esac
  return 1
}

# ---- remote lanes (lib/remote.sh): the orchestrator proves a cloud lane's READY sha itself --------------
# A cloud lane cannot write this machine's proof folder, so READY runs the proof here, in the throwaway
# worktree remote.sh already makes for --done-when. The base branch is fetched into the lane cache as
# refs/heads/osrc-base so .outsourcerer/verify is read from the base, never from the lane's branch.
_osrc_proof_remote_base() { # <id> <lane-json> <cache> -> rc0 when refs/heads/osrc-base is fresh
  local b url
  b="$(jq -r '.base // "main"' "$2" 2>/dev/null)"; url="$(_osrc_lane_fetch_url "$2" 2>/dev/null)"
  [ -n "$b" ] && [ -n "$url" ] || return 1
  _osrc_net git --git-dir="$3" fetch -q --no-tags "$url" "+refs/heads/$b:refs/heads/osrc-base" >/dev/null 2>&1
}

# No --done-when on the lane: with a verify script on base, run it (rc0, _PR_REMOTE_CHECK set); with
# nothing to run, record an honest method-none proof so the lane is reviewed and stamped unverified.
osrc_proof_remote_ready() { # <id> <lane-json> <head>
  local id="$1" f="$2" head="$3" cache
  _PR_REMOTE_CHECK=""
  _osrc_proof_id_ok "$id" || return 1
  # Proved by hand on this sha already: keep that proof. A failing one sends the READY back (rc 2).
  if [ "$(jq -r '.head // ""' "$(_osrc_proof_file "$id")" 2>/dev/null)" = "$head" ]; then
    osrc_proof_gate "$id" "$head" >/dev/null && return 1
    OSRC_PROOF_NO_SEND=1 osrc_proof_sendback "$id" "READY ${head:0:7}: $(osrc_proof_gate "$id" "$head")" "remote:$head"
    return 2
  fi
  if osrc_proof_stopped "$id"; then return 2; fi
  if cache="$(_osrc_lane_cache "$id" "$f" 2>/dev/null)" && _osrc_proof_remote_base "$id" "$f" "$cache" \
     && git --git-dir="$cache" cat-file -e "osrc-base:.outsourcerer/verify" 2>/dev/null; then
    _PR_REMOTE_CHECK=__osrc_verify__; return 0
  fi
  _osrc_proof_exec "$id" "" "$head" "" none "no check configured: add --done-when to the lane or commit .outsourcerer/verify on the base branch" remote >/dev/null 2>&1
  return 1
}

osrc_proof_remote_run() { # <id> <worktree> <head> <check|__osrc_verify__> <log> <cache>   (background)
  local id="$1" wt="$2" head="$3" check="$4" log="$5" cache="$6" base="" method=tests rc=0
  _PR_ARGS=()
  _osrc_proof_remote_base "$id" "$(_osrc_lane_json "$id")" "$cache" && base=osrc-base
  if [ -n "$base" ] && git -C "$wt" cat-file -e "$base:.outsourcerer/verify" 2>/dev/null; then _PR_ARGS+=("verify@$base"); method=verify-run; fi
  [ "$check" = __osrc_verify__ ] || _PR_ARGS+=("$check")
  [ "${#_PR_ARGS[@]}" -gt 0 ] || { echo "proof: nothing to run" >>"$log"; return 125; }
  OSRC_PROOF_CMD_SECS="${OSRC_CHECK_TIMEOUT:-900}" _osrc_proof_exec "$id" "$wt" "$head" "$base" "$method" "" remote-check "${_PR_ARGS[@]}" >>"$log" 2>&1 || rc=$?
  jq -r '.stamp, (.commands[] | "--- " + .cmd + " (exit " + (.exit|tostring) + ")", .tail[])' "$(_osrc_proof_file "$id")" >>"$log" 2>/dev/null
  return "$rc"
}

osrc_proof_remote_next() { # <id> -> the NEXT for a remote lane whose proof failed (empty: no proof state)
  if osrc_proof_stopped "$1"; then printf '%s proof show %s' "$(_osrc_self)" "$1"
  elif [ -f "$(_osrc_proof_dir "$1")/SENDBACK.md" ]; then printf '%s proof sendback %s' "$(_osrc_self)" "$1"; fi
}

osrc_proof_remote_note() { # <id> -> "; proof round 2 of 3" or "; STOPPED ..." (empty when no rounds)
  local r; r="$(_osrc_proof_rounds "$1")"
  if [ "$(jq -r .stopped <<<"$r")" = true ]; then printf '; STOPPED after %s failed proof rounds, needs a person (%s proof show %s)' "$(_osrc_proof_max)" "$(_osrc_self)" "$1"
  elif [ "$(jq -r .fails <<<"$r")" -gt 0 ]; then printf '; proof round %s of %s' "$(jq -r .fails <<<"$r")" "$(_osrc_proof_max)"; fi
}

# Guards passed only because of --allow / the 2-block release, or the diff edits the checks: the proof
# counts, but the lane must go through the reviewer. rc 0 when that is the case for the stored proof.
osrc_proof_reviewer_required() { # <lane>
  [ "$(jq -r '.ok == true and .reviewer_required == true' "$(_osrc_proof_file "$1")" 2>/dev/null)" = true ]
}

# Lines for the review brief: why the reviewer must look (empty when not required or not this head).
osrc_proof_review_note() { # <lane> [head]
  local f; f="$(_osrc_proof_file "$1")"
  osrc_proof_reviewer_required "$1" || return 0
  [ -z "${2:-}" ] || [ "$(jq -r .head "$f")" = "$2" ] || return 0
  jq -r '(if .guards.allowed != null then "guards were allowed through: " + .guards.allowed else empty end),
    (if (.guards.guards_changed_paths // []) | length > 0 then "the diff edits the checks: " + (.guards.guards_changed_paths | join(", ")) else empty end),
    (.guards.failed[]? | "guard " + .guard + ": " + ((.what // [])[:3] | join(" | ")))' "$f"
}

# Mission Control: per-lane proof fields and the project's unverified count (lib/hub.sh calls these).
osrc_proof_hub_lane() { # <lane-json> -> lane json + {proof:{stamp,method,ok,stopped,lines}}
  local l="$1" id f r
  id="$(jq -r '.id // ""' <<<"$l" 2>/dev/null)"; _osrc_proof_id_ok "$id" || { printf '%s' "$l"; return 0; }
  f="$(_osrc_proof_file "$id")"
  [ -f "$f" ] || [ -d "$(_osrc_proof_dir "$id")" ] || { printf '%s' "$l"; return 0; }
  r="$(_osrc_proof_rounds "$id")"
  jq -c --slurpfile p <(cat "$f" 2>/dev/null || echo null) --argjson r "$r" '
    ($p[0]) as $p | . + {proof:({stopped:$r.stopped, rounds:$r.fails}
      + (if $p == null then {stamp:"no proof"} else {stamp:$p.stamp, method:$p.method, ok:$p.ok, head:($p.head[0:7])} end)
      + (if $r.stopped then {why:($r.last.why // ""), lines:(($r.last.lines // [])[-12:])} else {} end))}' <<<"$l" 2>/dev/null || printf '%s' "$l"
}

osrc_proof_hub_counts() { # <lanes-json-array> -> {unverifiedLanes, needsYouLanes}
  jq -c '{unverifiedLanes:([.[] | select(.proof.method? == "none" and ((.status // "") | test("^(Merged|Done|Shipped)$")))] | length),
          needsYouLanes:([.[] | select(.proof.stopped? == true)] | length)}' <<<"$1" 2>/dev/null || printf '{}'
}
