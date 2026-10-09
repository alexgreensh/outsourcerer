#!/usr/bin/env bash
# atk5_reject: _supervise non-interactive reject mapping under hostile log/meta inputs.
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"; export HOME; HOME="$(mktemp -d)"
mkdir -p "$OSRC_HOME/jobs"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1

NEEDLE="warning: rejected a tool call that requires confirmation. Running in non-interactive mode"

mkjob() { # <id> <meta-provider|"-"|malformed> <log-content-via-stdin>
  local jd="$OSRC_HOME/jobs/$1"; mkdir -p "$jd"
  case "$2" in
    -) rm -f "$jd/meta.json" ;;
    malformed) printf '{broken json' > "$jd/meta.json" ;;
    *) printf '{"id":"%s","provider":"%s","verb":"edit","model":"m"}' "$1" "$2" > "$jd/meta.json" ;;
  esac
  cat > "$jd/out.log"
  echo "$jd"
}

# drive the same block _supervise uses, extracted: status write + verdict
verdict() { # <jobdir> <rc> [envlane] -> prints resulting status
  local jd="$1" rc="$2" _jlane=""
  [ -f "$jd/meta.json" ] && have jq && _jlane="$(jq -r '(.lane // .provider // "")' "$jd/meta.json" 2>/dev/null)"
  _jlane="${_jlane:-${OUTSOURCERER_PROVIDER:-${3:-}}}"
  local last; last="$(tail -1 "$jd/out.log" 2>/dev/null | grep -o 'OSRC::[A-Z_]*' | tail -1)"
  if [ "$rc" -eq 0 ] && [ "$last" != "OSRC::DONE" ] && [ "${OSRC_NO_PRINTMODE_ABORT:-0}" != "1" ] \
     && { [ "$_jlane" = "dv" ] || [ "$_jlane" = "devin" ]; } \
     && tail -n "${OSRC_PRINTMODE_TAIL:-25}" "$jd/out.log" 2>/dev/null | grep -aqF "warning: rejected a tool call that requires confirmation. Running in non-interactive mode"; then
    echo "permission-blocked"
  else
    echo "not-mapped (lane=$_jlane)"
  fi
}

echo "== ANSI inside needle (colored 'warning:' prefix, common pattern) =="
jd="$OSRC_HOME/jobs/j_ansi"; mkdir -p "$jd"
printf '{"id":"j_ansi","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
printf 'some work\n\033[33mwarning:\033[0m rejected a tool call that requires confirmation. Running in non-interactive mode\n' > "$jd/out.log"
echo "verdict=$(verdict "$jd" 0)"

echo "== ANSI around whole line (needle bytes contiguous) =="
jd="$OSRC_HOME/jobs/j_ansi2"; mkdir -p "$jd"
printf '{"id":"j_ansi2","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
printf 'some work\n\033[33m%s\033[0m\n' "$NEEDLE" > "$jd/out.log"
echo "verdict=$(verdict "$jd" 0)"

echo "== needle inside a longer line =="
jd="$OSRC_HOME/jobs/j_long"; mkdir -p "$jd"
printf '{"id":"j_long","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
printf 'prefix-stuff %s trailing-stuff\n' "$NEEDLE" > "$jd/out.log"
echo "verdict=$(verdict "$jd" 0)"

echo "== needle with CRLF endings =="
jd="$OSRC_HOME/jobs/j_crlf"; mkdir -p "$jd"
printf '{"id":"j_crlf","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
printf 'work\r\n%s\r\n' "$NEEDLE" > "$jd/out.log"
echo "verdict=$(verdict "$jd" 0)"

echo "== 200MB out.log timing =="
jd="$OSRC_HOME/jobs/j_big"; mkdir -p "$jd"
printf '{"id":"j_big","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
{ yes 'padding line padding line padding line padding line padding' | head -n 3000000; printf '%s\n' "$NEEDLE"; } > "$jd/out.log"
ls -lh "$jd/out.log" | awk '{print "size="$5}'
SECONDS=0; v="$(verdict "$jd" 0)"; echo "verdict=$v in ${SECONDS}s"

echo "== malformed meta.json + provider env =="
jd="$(printf 'work\n%s\n' "$NEEDLE" | mkjob j_badmeta malformed)"
OUTSOURCERER_PROVIDER=devin; echo "verdict=$(verdict "$jd" 0)"; unset OUTSOURCERER_PROVIDER

echo "== provider env variants: DEVIN / Devin / 'dv ' =="
jd="$(printf 'work\n%s\n' "$NEEDLE" | mkjob j_pvar -)"
for p in DEVIN Devin "dv " dv; do OUTSOURCERER_PROVIDER="$p"; echo "  provider='$p' -> $(verdict "$jd" 0)"; done; unset OUTSOURCERER_PROVIDER

echo "== hostile OSRC_PRINTMODE_TAIL: non-numeric =="
jd="$OSRC_HOME/jobs/j_tail"; mkdir -p "$jd"
printf '{"id":"j_tail","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
printf 'work\n%s\n' "$NEEDLE" > "$jd/out.log"
OSRC_PRINTMODE_TAIL=abc; echo "verdict=$(verdict "$jd" 0)"; unset OSRC_PRINTMODE_TAIL

echo "== out.log missing =="
jd="$OSRC_HOME/jobs/j_nolog"; mkdir -p "$jd"
printf '{"id":"j_nolog","provider":"devin","verb":"edit","model":"m"}' > "$jd/meta.json"
echo "verdict=$(verdict "$jd" 0)"

echo DONE
