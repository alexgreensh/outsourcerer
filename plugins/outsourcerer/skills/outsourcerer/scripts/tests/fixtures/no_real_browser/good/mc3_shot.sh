#!/usr/bin/env bash
# MC3 screenshot rehearsal: seed a sandbox (tests/lib_mc3_seed.sh), serve the hub on 8790, capture
# light + dark with headless Chrome. Usage: shot.sh <scripts-dir> <label> [extra-seed-cmd]
set -u
S="$1"; L="$2"; EXTRA="${3:-}"
OUT="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "$S/tests/.mc3-shot.XXXXXX")"; SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; mc3_unseed 2>/dev/null; rm -rf "$T"' EXIT
export MC3_T="$T" HOME="$T/home" OSRC_HOME="$T/osrc" MC3_ENGINE="$S/outsourcerer.sh"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$OSRC_HOME"; printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
. "$S/tests/lib_mc3_seed.sh"; export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
mc3_seed
[ -n "$EXTRA" ] && eval "$EXTRA"
bash "$S/outsourcerer.sh" hub export > "$OUT/$L.export.json" 2>"$OUT/$L.export.err"
nice -n 19 bash "$S/outsourcerer.sh" hub serve --no-open --port 8790 > "$T/serve.log" 2>&1 & SRV=$!
for i in $(seq 1 40); do grep -q 'http' "$T/serve.log" 2>/dev/null && break; sleep 0.5; done
TOK="$(cat "$OSRC_HOME/hub/token")"
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for th in light dark; do
  nice -n 19 "$C" --headless=new --use-mock-keychain --disable-gpu --hide-scrollbars --user-data-dir="$T/chrome" \
    --window-size=1440,1500 --virtual-time-budget=8000 --screenshot="$OUT/$L-$th.png" \
    "http://127.0.0.1:8790/?t=$TOK&theme=$th" >/dev/null 2>&1
done
# Headless Chrome will not size a window under ~500px, so the phone view is a real 390px iframe.
printf '<!doctype html><body style="margin:0;background:#888"><iframe src="http://127.0.0.1:8790/?t=%s&theme=light" style="width:390px;height:1600px;border:0;display:block"></iframe>' "$TOK" > "$T/phone.html"
nice -n 19 "$C" --headless=new --use-mock-keychain --disable-gpu --hide-scrollbars --user-data-dir="$T/chrome" \
  --window-size=390,1600 --virtual-time-budget=8000 --screenshot="$OUT/$L-phone.png" "file://$T/phone.html" >/dev/null 2>&1
echo "export: $(jq -c '[.projects[] | {name, status, lanes: (.lanes|length)}]' "$OUT/$L.export.json")"
echo "limits: $(jq -c '[.limits[] | {name, renews}]' "$OUT/$L.export.json")"
