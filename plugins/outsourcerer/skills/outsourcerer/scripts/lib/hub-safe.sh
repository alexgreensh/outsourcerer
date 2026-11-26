# shellcheck shell=bash
# lib/hub-safe.sh: Mission Control never drops a project without saying so (release review F46). Sourced by
# outsourcerer.sh (and by hub.sh for suites that source it alone); function definitions only.

# _osrc_hub_stub_project <slug> <now-epoch> <updated-stamp> <why> -> a minimal project doc for a project
# whose build failed (a card the export cannot read, a jq error): it stays listed with exportError, so
# the page says the data is missing instead of the project vanishing.
_osrc_hub_stub_project() {
  local name=""
  [ -f "$OSRC_HOME/hub/projects/$1.json" ] && name="$(jq -r '.name // "" | strings' "$OSRC_HOME/hub/projects/$1.json" 2>/dev/null)"
  [ -n "$name" ] || ! type _osrc_hub_derived_name >/dev/null 2>&1 || name="$(_osrc_hub_derived_name "$1" 2>/dev/null)"
  jq -cn --arg id "$1" --arg name "${name:-$1}" --argjson now "$2" --arg upd "$3" --arg why "$4" \
    '{id:$id, name:$name, order:99, updated:$upd, exported_at:$now, lanes:[], decisions:[], liveLanes:0, exportError:$why}'
}

# _osrc_hub_truth_safe <project-json> <now-epoch> -> _osrc_hub_truth's doc, else the project as built,
# marked exportError: one bad pass must not empty the projects list for everyone.
_osrc_hub_truth_safe() {
  local out; out="$(_osrc_hub_truth "$1" "$2" 2>/dev/null)"
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then printf '%s\n' "$out"
  else jq -c '. + {exportError: "Mission Control could not check this project against its lanes in this export; showing it as built"}' <<<"$1"; fi
}

# _osrc_hub_mc_find <token> -> the port of this OSRC_HOME's live hub, rc 1 when none answers. Ports: the
# one serve.json recorded, OSRC_HUB_PORT, then 8788-8798. Each candidate is asked GET /hello?n=<nonce>
# and must answer HMAC-SHA256(token, "osrc-hub-hello:<nonce>"); the token itself is never sent (any local
# process can bind one of these ports) and goes to python on stdin, never in argv where `ps` shows it.
_osrc_hub_mc_find() {
  local tok="$1" plist="" sp p n got want
  command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 1
  sp="$(jq -r '.port // empty' "$OSRC_HOME/hub/serve.json" 2>/dev/null)"
  case "$sp" in ''|*[!0-9]*) ;; *) plist="$sp" ;; esac
  case "${OSRC_HUB_PORT:-}" in ''|*[!0-9]*) ;; *) plist="${plist:+$plist }${OSRC_HUB_PORT}" ;; esac
  for p in 8788 8789 8790 8791 8792 8793 8794 8795 8796 8797 8798; do
    case " $plist " in *" $p "*) ;; *) plist="$plist $p" ;; esac
  done
  for p in $plist; do
    n="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; [ "${#n}" -eq 32 ] || return 1
    got="$(curl -s -m 3 "http://127.0.0.1:$p/hello?n=$n" 2>/dev/null | jq -r '.proof // empty | strings' 2>/dev/null)"
    [ -n "$got" ] || continue
    want="$(printf '%s\n' "$tok" | python3 -I -c 'import hashlib, hmac, sys
print(hmac.new(sys.stdin.buffer.readline().strip(), ("osrc-hub-hello:" + sys.argv[1]).encode(), hashlib.sha256).hexdigest())' "$n" 2>/dev/null)"
    [ -n "$want" ] && [ "$got" = "$want" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
