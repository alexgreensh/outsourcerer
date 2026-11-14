# lib/parity.sh: the reverse-bridge INSOURCE writers (parity-codex | parity-droid | parity-cursor).
# Moved out of outsourcerer.sh (size rule: that file may only shrink); sourced by the lib loader,
# functions only. They use $SCRIPT_PATH, set by outsourcerer.sh before this loads.
#
# Reverse bridge INTO droid / cursor / codex: teach the HOST agent (Factory droid, Cursor CLI, Codex) to
# drive outsourcerer from ITS side, so someone living in that tool gets the Devin/OpenRouter/Claude/
# Codex/local lanes plus bg/fanout supervision without leaving it. parity-* REWRITES the
# OUTSOURCERER:INSOURCE block on every run (issue #62): append-once kept retired model names and a
# versioned script path that the next plugin upgrade deletes.

_insource_write() {   # <file> <host-label> [codex]
  local f="$1"; shift; local b="" s="" e=""
  b="$(mktemp "${TMPDIR:-/tmp}/osrc-ins.XXXXXX")" || die "parity: mktemp failed"
  _insource_block "$@" > "$b" || { rm -f "$b"; die "parity: cannot render insource block"; }
  eval "$(awk '/^<!-- OUTSOURCERER:INSOURCE/ && !s { s=NR } s && /^<!-- \/OUTSOURCERER:INSOURCE -->/ && NR > s && !e { e=NR } END { if (s) print "s=" s " e=" e }' "$f" 2>/dev/null)"
  # Write IN PLACE (cat tmp > "$f"), never mv a temp over the target: the file belongs to the user (often a
  # symlink into a dotfiles repo, sometimes read-only), and a rename would turn the link into a regular
  # file, reset the mode, and can cross filesystems. A read-only target fails loudly here.
  if [ -n "$s" ] && [ -n "$e" ]; then
    { [ "$s" -eq 1 ] || head -n "$((s-1))" "$f"; cat "$b"; tail -n "+$((e+1))" "$f"; } > "$b.out" \
      || { rm -f "$b" "$b.out"; die "parity: cannot rewrite $f"; }
    cat "$b.out" > "$f" || { rm -f "$b" "$b.out"; die "parity: cannot write $f (read-only or not writable)"; }
  else
    if [ -n "$s" ]; then   # dangling start marker: drop it
      sed "${s}d" "$f" > "$b.out" && cat "$b.out" > "$f" || { rm -f "$b" "$b.out"; die "parity: cannot write $f (read-only or not writable)"; }
    fi
    { [ -s "$f" ] && printf '\n'; cat "$b"; } >> "$f" || { rm -f "$b" "$b.out"; die "parity: cannot write $f"; }
  fi
  rm -f "$b" "$b.out"
}
# _insource_block <host-label> [codex]: emit the block. Model-agnostic (hardcoded ids went stale); cache
# installs resolve the NEWEST version at read time (numeric sort — no GNU sort -V on macOS).
_insource_block() {
  local OLINE="  O=\"$SCRIPT_PATH\"" vroot=""
  case "$SCRIPT_PATH" in */plugins/cache/*/*/*/skills/outsourcerer/scripts/outsourcerer.sh)
    vroot="$(cd "$(dirname "$SCRIPT_PATH")/../../../.." 2>/dev/null && pwd)" || vroot="" ;; esac
  case "$vroot::$SCRIPT_PATH" in *[\'\"\$\`\\]*) ;;   # unsafe to embed in the emitted command: keep pinned
    *) [ -z "$vroot" ] || OLINE="  O=\"\$(ls -d \"$vroot\"/*/skills/outsourcerer/scripts/outsourcerer.sh 2>/dev/null | awk -F/ '{print \$(NF-4) \"\\t\" \$0}' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1 | cut -f2-)\"; [ -n \"\$O\" ] || O=\"$SCRIPT_PATH\"" ;; esac
  [ "${2:-}" != "codex" ] || {
    cat <<EOF
<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity-codex) -->
## Insourcing to Claude from this Codex session (outsourcerer reverse bridge)
$OLINE
  "\$O" run -m <claude-model> "<task>"  # Claude-native (your Claude subscription); or --provider cc for a cheap Claude-compatible
Delegates end with OSRC::DONE <summary> (or OSRC::BLOCKED <reason>); read only the final message.
<!-- /OUTSOURCERER:INSOURCE -->
EOF
    return; }
  cat <<EOF
<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: $1) -->
## Outsourcerer: delegate grunt work to cheaper/different engines
This machine has outsourcerer installed — delegate from this $1 session to Devin, OpenRouter,
Claude-subscription, ChatGPT-sub, keyless-Gemini or local-Ollama (\$0 cash + \$0 plan, private) lanes.
$OLINE
  "\$O" doctor && "\$O" models             # what's live + current model ids (ids churn: pick live)
  "\$O" run -m <model> "<read-only task>"  # one-shot; edit/yolo for mutating work
  "\$O" bg run -m <model> "<long task>"    # supervised background job -> status/result <id>
First cloud delegation: "\$O" consent grant (one-time, remembered). Delegates end with OSRC::DONE <summary> (or OSRC::BLOCKED <reason>); read only the final message.
<!-- /OUTSOURCERER:INSOURCE -->
EOF
}

parity_droid() {
  have droid || printf '>>> note: droid CLI not on PATH yet; writing the bridge anyway so it works the moment droid is installed.\n' >&2
  mkdir -p "${FACTORY_HOME:-$HOME/.factory}"
  _insource_write "${FACTORY_HOME:-$HOME/.factory}/AGENTS.md" "Factory droid"
  echo "parity-droid: insource block written to ${FACTORY_HOME:-$HOME/.factory}/AGENTS.md (refreshed on every run; droid loads ~/.factory/AGENTS.md globally)"
}

parity_cursor() {
  _insource_write "$PWD/AGENTS.md" "Cursor"
  echo "parity-cursor: insource block written to $PWD/AGENTS.md (refreshed on every run; repo-level by design — commit or gitignore as you prefer)"
}

parity_codex() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}"; mkdir -p "$codex_home"
  _insource_write "$codex_home/AGENTS.md" "Codex" codex
  echo "parity-codex: insource block written to $codex_home/AGENTS.md (refreshed on every run)"
}
