#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_parity_insource_refresh.sh — parity-* INSOURCE blocks must REFRESH, not append-once (issue #62).
#
# The old writers returned early when the OUTSOURCERER:INSOURCE marker was present, so a block
# written by 0.3.1 kept its retired model names (glm-5.2/swe-1.7, `run -m glm`) and its versioned
# plugin-cache script path forever — a path the next upgrade deletes. The template itself still
# advertised those retired ids. Pinned here: (1) the emitted template names no model ids and points
# at `doctor`/`models`, (2) a re-run REPLACES the block between the markers and leaves surrounding
# user content intact, (3) the write is byte-idempotent, (4) a plugin-cache install emits a
# read-time newest-version resolver (numeric sort — GNU sort -V is absent on macOS) with the
# current path as fallback, never a bare pinned path, (5) a dangling start marker is repaired,
# not left to swallow the file on a later splice.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
TMP="$(cd "$(mktemp -d "${TMPDIR%/}/test-parity-insource.XXXXXX")" && pwd)"  # canonicalize: macOS TMPDIR has a trailing slash
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export OSRC_HOME="$TMP/state"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

set --; . "$SRC" >/dev/null 2>&1

# ---- 1. the template is model-agnostic -----------------------------------------------------------
block="$(_insource_block "Cursor")"
grep -qE 'glm|swe-1|hy3|fable|opus|sonnet|haiku' <<<"$block" \
  && bad "template still names model ids" \
  || ok "template names no model ids"
grep -q 'models' <<<"$block" \
  && ok "template points at the live models listing" \
  || bad "template lost the models pointer"
grep -q '^<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: Cursor) -->' <<<"$block" \
  && ok "generic block carries the host-labelled marker" \
  || bad "generic marker missing"

# ---- 2. parity-cursor: fresh write, then a stale block gets REPLACED ----------------------------
wd="$TMP/wd"; mkdir -p "$wd"; ( cd "$wd" && parity_cursor >/dev/null )
[ "$(grep -c '^<!-- OUTSOURCERER:INSOURCE' "$wd/AGENTS.md")" = "1" ] \
  && [ "$(grep -c '^<!-- /OUTSOURCERER:INSOURCE -->' "$wd/AGENTS.md")" = "1" ] \
  && ok "parity-cursor writes exactly one block" \
  || bad "parity-cursor marker count wrong"
# Seed the exact stale state from issue #62: an old-version block between user content.
cat > "$wd/AGENTS.md" <<EOF
user header
<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: Cursor) -->
stale: run -m glm via glm-5.2/swe-1.7 at /cache/outsourcerer/0.3.1/scripts/outsourcerer.sh
<!-- /OUTSOURCERER:INSOURCE -->
user footer
EOF
( cd "$wd" && parity_cursor >/dev/null )
grep -qE 'glm-5\.2|0\.3\.1' "$wd/AGENTS.md" \
  && bad "stale block survived a parity re-run" \
  || ok "parity-cursor replaces the stale block"
{ _t3b_pipe="$(head -1 "$wd/AGENTS.md")" && grep -q '^user header$' <<<"$_t3b_pipe"; } && { _t3b_pipe="$(tail -1 "$wd/AGENTS.md")" && grep -q '^user footer$' <<<"$_t3b_pipe"; } \
  && ok "user content outside the markers is preserved" \
  || bad "user content outside the markers was damaged"
[ "$(grep -c '^<!-- OUTSOURCERER:INSOURCE' "$wd/AGENTS.md")" = "1" ] \
  && ok "still exactly one block after the refresh" \
  || bad "refresh duplicated the block"
cp "$wd/AGENTS.md" "$wd/first"
( cd "$wd" && parity_cursor >/dev/null )
cmp -s "$wd/AGENTS.md" "$wd/first" \
  && ok "parity-cursor is byte-idempotent" \
  || bad "second run changed the file (not idempotent)"

# ---- 3. parity-codex: the issue's repro 2 --------------------------------------------------------
export CODEX_HOME="$TMP/codex"
parity_codex >/dev/null
grep -q 'managed by outsourcerer parity-codex' "$CODEX_HOME/AGENTS.md" \
  && ok "parity-codex writes its own marker" \
  || bad "parity-codex marker missing"
sed -i.bak 's#scripts/outsourcerer\.sh#0.3.1/scripts/outsourcerer.sh#g' "$CODEX_HOME/AGENTS.md"
parity_codex >/dev/null
[ "$(grep -c '0\.3\.1' "$CODEX_HOME/AGENTS.md")" = "0" ] \
  && ok "parity-codex refreshes a stale versioned path (issue repro 2)" \
  || bad "parity-codex kept the stale path"
[ "$(grep -c '^<!-- OUTSOURCERER:INSOURCE' "$CODEX_HOME/AGENTS.md")" = "1" ] \
  && ok "parity-codex refresh stays single-block" \
  || bad "parity-codex duplicated the block"

# ---- 4. parity-droid honours FACTORY_HOME and refreshes -----------------------------------------
export FACTORY_HOME="$TMP/factory"
parity_droid >/dev/null 2>&1
grep -q 'host: Factory droid' "$FACTORY_HOME/AGENTS.md" \
  && ok "parity-droid writes the droid-labelled block" \
  || bad "parity-droid block missing"
printf '<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: Factory droid) -->\nstale glm-5.2\n<!-- /OUTSOURCERER:INSOURCE -->\n' > "$FACTORY_HOME/AGENTS.md"
parity_droid >/dev/null 2>&1
grep -q 'glm-5\.2' "$FACTORY_HOME/AGENTS.md" \
  && bad "parity-droid kept the stale block" \
  || ok "parity-droid refreshes the stale block"

# ---- 5. plugin-cache install: read-time newest-version resolver ---------------------------------
C="$HOME/.claude/plugins/cache/mp/outsourcerer"
for v in 0.9.0 0.15.3 10.0.0 unknown; do mkdir -p "$C/$v/skills/outsourcerer/scripts"; done
for v in 0.9.0 0.15.3 10.0.0; do : > "$C/$v/skills/outsourcerer/scripts/outsourcerer.sh"; done
SCRIPT_PATH="$C/0.15.3/skills/outsourcerer/scripts/outsourcerer.sh"
block="$(_insource_block "Cursor")"
[ "$(printf '%s' "$block" | grep -c '0\.15\.3')" = "1" ] \
  && grep -q '|| O="[^"]*0\.15\.3' <<<"$block" \
  && ok "cache install: pinned path survives only as the resolver's fallback" \
  || bad "cache install: pinned path outside the fallback (or missing)"
oline="$(printf '%s\n' "$block" | grep '^  O=')"
[ -n "$oline" ] && ok "cache install: block carries the resolver assignment" \
  || bad "cache install: resolver assignment missing"
resolved="$(eval "${oline#  }"; printf '%s' "$O")"
[ "$resolved" = "$C/10.0.0/skills/outsourcerer/scripts/outsourcerer.sh" ] \
  && ok "resolver picks the numerically newest version (10.0.0 > 0.15.3 > 0.9.0; 'unknown' ignored)" \
  || bad "resolver picked: $resolved"
rm -rf "$C/10.0.0"   # upgrade prunes: resolver must fall back to a still-existing path
resolved="$(eval "${oline#  }"; printf '%s' "$O")"
[ "$resolved" = "$C/0.15.3/skills/outsourcerer/scripts/outsourcerer.sh" ] \
  && ok "after the newest version is pruned, the resolver lands on the surviving install" \
  || bad "after pruning, resolver picked: $resolved"

# ---- 6. non-cache install: plain pinned path, no resolver ---------------------------------------
SCRIPT_PATH="$TMP/plain/outsourcerer.sh"
block="$(_insource_block "Cursor")"
grep -q "O=\"$TMP/plain/outsourcerer.sh\"" <<<"$block" \
  && ok "non-cache install pins the script path" \
  || bad "non-cache install lost the pinned path"
grep -q 'sort -t\.' <<<"$block" \
  && bad "non-cache install emitted a pointless resolver" \
  || ok "non-cache install emits no resolver"

# ---- 7. hostile install path: resolver refused, pinned path kept ---------------------------------
W="$HOME/.claude/plugins/cache/mp/we\$ird"
mkdir -p "$W/1.0.0/skills/outsourcerer/scripts"
SCRIPT_PATH="$W/1.0.0/skills/outsourcerer/scripts/outsourcerer.sh"
block="$(_insource_block "Cursor")"
grep -qF "O=\"$W/1.0.0/skills/outsourcerer/scripts/outsourcerer.sh\"" <<<"$block" \
  && ok 'a $ in the install path keeps the pinned path (no embedded-eval risk)' \
  || bad 'hostile path: pinned path not kept'

# ---- 8. dangling start marker: repaired, user text kept ------------------------------------------
d="$TMP/dangle"; mkdir -p "$d"
cat > "$d/AGENTS.md" <<'EOF'
user notes
<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: Cursor)
truncated stale instructions
EOF
SCRIPT_PATH="$TMP/plain/outsourcerer.sh"
( cd "$d" && parity_cursor >/dev/null )
grep -q '^truncated stale instructions$' "$d/AGENTS.md" \
  && ok "dangling marker: user text below it survives" \
  || bad "dangling marker: user text lost"
[ "$(grep -c '^<!-- OUTSOURCERER:INSOURCE' "$d/AGENTS.md")" = "1" ] \
  && [ "$(grep -c '^<!-- /OUTSOURCERER:INSOURCE -->' "$d/AGENTS.md")" = "1" ] \
  && ok "dangling marker: file ends with exactly one well-formed block" \
  || bad "dangling marker: marker counts wrong after repair"
( cd "$d" && parity_cursor >/dev/null )
grep -q '^user notes$' "$d/AGENTS.md" && grep -q '^truncated stale instructions$' "$d/AGENTS.md" \
  && ok "dangling repair is stable across a second run (no splice-eating)" \
  || bad "second run after dangling repair ate content"

# ---- 9. empty target file: block starts at line 1 -------------------------------------------------
e="$TMP/empty"; mkdir -p "$e"; : > "$e/AGENTS.md"
( cd "$e" && parity_cursor >/dev/null )
[ "$(head -1 "$e/AGENTS.md")" = '<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: Cursor) -->' \
  ] && ok "empty file: block starts at line 1 (no leading blank)" \
  || bad "empty file: unexpected first line"

# ---- 10. the target belongs to the user: write IN PLACE, never rename over it -------------------------
# (review of #63: an mv-based writer turned a symlinked AGENTS.md, the dotfiles layout, into a regular
#  file on the second run, reset a 640 mode to the umask default, and silently replaced a read-only file.)
_mode() { ls -l "$1" | cut -c1-10; }
d="$TMP/dots"; mkdir -p "$d" "$TMP/ch"; printf 'my own header\n' > "$d/AGENTS.md"
ln -s "$d/AGENTS.md" "$TMP/ch/AGENTS.md"
CODEX_HOME="$TMP/ch" parity_codex >/dev/null; CODEX_HOME="$TMP/ch" parity_codex >/dev/null   # append, then rewrite
[ -L "$TMP/ch/AGENTS.md" ] && ok "symlinked target stays a symlink after two runs (append then rewrite)" \
  || bad "symlinked target was replaced by a regular file"
[ "$(grep -c '^<!-- OUTSOURCERER:INSOURCE' "$d/AGENTS.md")" = "1" ] && grep -q 'my own header' "$d/AGENTS.md" \
  && ok "the real file behind the link carries exactly one block and the user's text" \
  || bad "real file behind the link: unexpected content"
m="$TMP/modes"; mkdir -p "$m"; printf 'x\n' > "$m/AGENTS.md"; chmod 640 "$m/AGENTS.md"
( cd "$m" && parity_cursor >/dev/null ); ( cd "$m" && parity_cursor >/dev/null )
[ "$(_mode "$m/AGENTS.md")" = "-rw-r-----" ] && ok "file mode (640) survives append and rewrite" \
  || bad "file mode changed to $(_mode "$m/AGENTS.md")"
ro="$TMP/ro"; mkdir -p "$ro"; printf 'x\n' > "$ro/AGENTS.md"; ( cd "$ro" && parity_cursor >/dev/null )
cp "$ro/AGENTS.md" "$TMP/ro.before"; chmod 444 "$ro/AGENTS.md"
( cd "$ro" && parity_cursor ) >"$TMP/ro.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'read-only\|cannot write' "$TMP/ro.out" \
  && cmp -s "$ro/AGENTS.md" "$TMP/ro.before" && [ "$(_mode "$ro/AGENTS.md")" = "-r--r--r--" ] \
  && ok "read-only target fails loudly and is left untouched" \
  || bad "read-only target: rc=$rc, out=$(head -c 160 "$TMP/ro.out")"
chmod 644 "$ro/AGENTS.md"

# ---- 11. a version folder with a space must not break the resolver -----------------------------
SCRIPT_PATH="$C/0.15.3/skills/outsourcerer/scripts/outsourcerer.sh"
mkdir -p "$C/20.0.0 beta/skills/outsourcerer/scripts"; : > "$C/20.0.0 beta/skills/outsourcerer/scripts/outsourcerer.sh"
oline="$(_insource_block "Cursor" | grep '^  O=')"
resolved="$(eval "${oline#  }"; printf '%s' "$O")"
[ "$resolved" = "$C/20.0.0 beta/skills/outsourcerer/scripts/outsourcerer.sh" ] \
  && ok "version folder with a space resolves to its full path (no split on the space)" \
  || bad "space in version folder: resolver picked: $resolved"
rm -rf "$C/20.0.0 beta"

echo
echo "parity-insource-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
