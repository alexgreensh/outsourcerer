#!/usr/bin/env bash
# test_delegate_attribution.sh — delegated-commit attribution (GH007). Two real seams:
#  1) ENV: every delegate_* harness is a child of this process, so route_delegate exports a noreply
#     GIT_AUTHOR_*/GIT_COMMITTER_* identity — a delegate commit can never carry the operator's
#     private email into a push. All-or-nothing: any operator-set GIT_* env wins; the
#     OSRC_DELEGATE_GIT_IDENTITY=0 opt-out disables it. Verified by a fake `droid` that dumps env.
#  2) CREW SQUASH: the integration commit uses a noreply identity and _crew_co_trailers harvests
#     deduped Co-Authored-By trailers off the worker branch so human attribution survives the squash.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-attrib.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/fakehome"
mkdir -p "$HOME"
export OSRC_HOME="$TMP/home"; mkdir -p "$OSRC_HOME"
SRC_ONLY="$TMP/src.sh"; sed '/^\[ "${OSRC_SOURCED:-}" = "1" \] || main "\$@"$/d' "$SRC" > "$SRC_ONLY"
# shellcheck disable=SC1090
. "$SRC_ONLY" >/dev/null 2>&1

# Fake droid that records the environment it was dispatched with. NOTE: outsourcerer.sh prepends
# $HOME/.local/bin to PATH at startup (line ~147), so the fake MUST live under a fake HOME's
# .local/bin or a real droid on PATH would shadow it and actually run.
FAKEHOME="$TMP/fakehome"; FAKEBIN="$FAKEHOME/.local/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/droid" <<'EOF'
#!/usr/bin/env bash
env > "$OSRC_ENV_DUMP" 2>/dev/null || env > /tmp/osrc-env-dump.$$
exit 0
EOF
chmod +x "$FAKEBIN/droid"

run_droid() {  # <home> <dumpfile> [extra env via leading VAR=x args] -- real fg dispatch, no preflight
  local h="$1" dump="$2"; shift 2
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$FAKEHOME" PATH="$FAKEBIN:$PATH" OSRC_HOME="$h" OSRC_SOURCED= OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 \
    OSRC_NO_ADVISE=1 OSRC_ENV_DUMP="$dump" OUTSOURCERER_DEPTH=0 "$@" \
    bash "$SRC" run --spend-ok --provider droid -m kimi-k3 "hi" >/dev/null 2>&1
}

# 1) Default: delegate child sees the noreply identity.
H1="$TMP/h1"; mkdir -p "$H1"; D1="$TMP/d1.env"
run_droid "$H1" "$D1"
if [ -f "$D1" ] && grep -q '^GIT_AUTHOR_EMAIL=outsourcerer-delegate@users\.noreply\.github\.com$' "$D1" \
   && grep -q '^GIT_COMMITTER_EMAIL=outsourcerer-delegate@users\.noreply\.github\.com$' "$D1"; then
  ok "env: delegate child carries the noreply author+committer identity"
else
  bad "env: noreply identity did not reach the delegate child"
fi

# 2) Operator-set GIT_* env is never overridden (all-or-nothing).
H2="$TMP/h2"; mkdir -p "$H2"; D2="$TMP/d2.env"
env -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  HOME="$FAKEHOME" PATH="$FAKEBIN:$PATH" OSRC_HOME="$H2" OSRC_SOURCED= OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 \
  OSRC_NO_ADVISE=1 OSRC_ENV_DUMP="$D2" OUTSOURCERER_DEPTH=0 GIT_AUTHOR_NAME="Operator Name" \
  bash "$SRC" run --spend-ok --provider droid -m kimi-k3 "hi" >/dev/null 2>&1
if [ -f "$D2" ] && grep -q '^GIT_AUTHOR_NAME=Operator Name$' "$D2" && ! grep -q '^GIT_COMMITTER_EMAIL=' "$D2"; then
  ok "env: operator-set GIT_* is respected (no override)"
else
  bad "env: operator identity was overridden"
fi

# 3) Opt-out: OSRC_DELEGATE_GIT_IDENTITY=0 -> no identity injection.
H3="$TMP/h3"; mkdir -p "$H3"; D3="$TMP/d3.env"
env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  HOME="$FAKEHOME" PATH="$FAKEBIN:$PATH" OSRC_HOME="$H3" OSRC_SOURCED= OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 \
  OSRC_NO_ADVISE=1 OSRC_ENV_DUMP="$D3" OUTSOURCERER_DEPTH=0 OSRC_DELEGATE_GIT_IDENTITY=0 \
  bash "$SRC" run --spend-ok --provider droid -m kimi-k3 "hi" >/dev/null 2>&1
if [ -f "$D3" ] && ! grep -q '^GIT_AUTHOR_EMAIL=' "$D3" && ! grep -q '^GIT_COMMITTER_EMAIL=' "$D3"; then
  ok "env: OSRC_DELEGATE_GIT_IDENTITY=0 injects nothing"
else
  bad "env: opt-out still injected an identity"
fi

# 4) _crew_co_trailers: harvest + dedupe Co-Authored-By from a worker branch.
if command -v git >/dev/null 2>&1; then
  R="$TMP/repo"; mkdir -p "$R"
  git -C "$R" init -q; git -C "$R" -c user.name=t -c user.email=t@t commit -qm init --allow-empty
  base="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -qb worker
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm "w1" --allow-empty \
      -m "Co-Authored-By: Human One <h1@example.com>"
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm "w2" --allow-empty \
      -m "Co-Authored-By: Human One <h1@example.com>" -m "Co-Authored-By: Human Two <h2@example.com>"
  got="$(_crew_co_trailers "$R" "$base" worker)"
  want=$'Co-Authored-By: Human One <h1@example.com>\nCo-Authored-By: Human Two <h2@example.com>'
  [ "$got" = "$want" ] && ok "crew: deduped Co-Authored-By trailers harvested from worker branch" \
                      || bad "crew: trailer harvest wrong: $(printf '%s' "$got" | tr '\n' '|')"
  # No trailers -> empty output (message stays a bare "crew: <label>").
  git -C "$R" checkout -qb plain "$base"
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm "no trailers" --allow-empty
  [ -z "$(_crew_co_trailers "$R" "$base" plain)" ] && ok "crew: no trailers -> empty (bare squash msg)" \
                      || bad "crew: phantom trailer on a trailer-free branch"
else
  echo "SKIP: _crew_co_trailers (git absent)"
fi

# 5) Source cross-checks: noreply identity on the crew squash; the env seam sits inside
#    route_delegate before any dispatch.
grep -qF 'user.email=outsourcerer-crew@users.noreply.github.com' "$SRC" \
  && ok "source: crew squash identity is noreply" || bad "source: crew squash identity not noreply"
grep -qF 'GIT_AUTHOR_EMAIL="outsourcerer-delegate@users.noreply.github.com"' "$SRC" \
  && ok "source: delegate env identity is noreply" || bad "source: delegate env identity missing"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
