#!/usr/bin/env bash
# A bg job on a model with no alias-table row (a new gpt-6-* id) runs on its native lane by family
# inference; its meta.json must record that lane (cx), not the OpenRouter cash lane (or).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
E="$(mktemp -d)"; E="$(cd "$E" && pwd -P)"; trap 'rm -rf "$E"' EXIT
export HOME="$E/home" OSRC_HOME="$E/state" GIT_CEILING_DIRECTORIES="$E"; mkdir -p "$HOME" "$E/bin" "$E/work"
pass=0; fail=0; ok() { echo "PASS: $1"; pass=$((pass+1)); }; bad() { echo "FAIL: $1"; fail=$((fail+1)); }
printf '#!/usr/bin/env bash\necho "fine"; echo "OSRC::DONE ok"\n' > "$E/bin/codex"; chmod +x "$E/bin/codex"
jid="$(cd "$E/work" && PATH="$E/bin:$PATH" OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_HEARTBEAT_DISABLED=1 \
  bash "$SRC" bg --spend-ok --provider codex run -m gpt-6-testmodel "say fine" 2>/dev/null | head -1)"
i=0; while [ "$i" -lt 100 ] && [ ! -s "$OSRC_HOME/jobs/$jid/meta.json" ]; do sleep 0.1; i=$((i+1)); done
lane="$(jq -r '.lane // ""' "$OSRC_HOME/jobs/$jid/meta.json" 2>/dev/null)"
[ "$lane" = cx ] && ok "an untabled gpt-6 model is recorded on its native lane (cx)" || bad "meta lane is '$lane' (job '$jid')"
i=0; while [ "$i" -lt 100 ]; do case "$(cat "$OSRC_HOME/jobs/$jid/status" 2>/dev/null)" in running|launching) sleep 0.1; i=$((i+1)) ;; *) break ;; esac; done
# Windows: git prints the common dir as C:/...; it is absolute and must not get the repo path prefixed.
mkdir -p "$E/win" "$E/fakegit"; printf '#!/usr/bin/env bash\necho "C:/repo/.git"\n' > "$E/fakegit/git"; chmod +x "$E/fakegit/git"
( cd "$E/win" && PATH="$E/fakegit:$PATH" bash -c 'OSRC_SOURCED=1 . "$1" >/dev/null 2>&1; _osrc_git_exclude_state /some/repo' _ "$SRC" )
[ -f "$E/win/C:/repo/.git/info/exclude" ] && [ ! -e "$E/win/some" ] && ok "a drive-letter git dir is treated as absolute" || bad "drive-letter common dir mishandled"
echo; echo "job meta lane: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
