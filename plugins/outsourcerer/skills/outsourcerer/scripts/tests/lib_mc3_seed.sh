#!/usr/bin/env bash
# lib_mc3_seed.sh -- seed a sandbox OSRC_HOME + HOME with the shapes Mission Control meets on a real
# machine (MC3). Sourced by test_hub_mc3.sh and by the screenshot rehearsal; never touches the live
# ~/.outsourcerer. Needs: HOME, OSRC_HOME, MC3_T (scratch root) exported by the caller.
#
#   A  aaaaaaaa-...  orchestrator with a running lane (a job whose pid is a sleep we own)
#   B  bbbbbbbb-...  orchestrator BETWEEN lanes: its only lane finished and the owner file is gone
#                    (exactly what stop-guard / supervise leave behind); it still runs commands
#   C  cccccccc-...  a busy Claude session that never touched Outsourcerer: never a project, "Also running"
#   D  dddddddd-...  a non-Outsourcerer session idle a few minutes: "Also running", idle
#   E  eeeeeeee-...  a non-Outsourcerer session idle for 3 hours: never shows
MC3_SID_A=aaaaaaaa-1111-4111-8111-111111111111
MC3_SID_B=bbbbbbbb-2222-4222-8222-222222222222
MC3_SID_C=cccccccc-3333-4333-8333-333333333333
MC3_SID_D=dddddddd-4444-4444-8444-444444444444
MC3_SID_E=eeeeeeee-5555-4555-8555-555555555555
MC3_SID_F=ffffffff-6666-4666-8666-666666666666

_mc3_repo() { # <name> -> path of a git repo with a github origin
  local r="$MC3_T/repos/$1"
  mkdir -p "$r" && git -C "$r" init -q 2>/dev/null
  git -C "$r" config remote.origin.url "https://github.com/alexgreensh/$1.git"
  printf '%s' "$r"
}

_mc3_transcript() { # <sid> <custom|ai|agent|none> <title> [cwd]: real line shapes, at the fleet's cwd-derived path
  local d="$HOME/.claude/projects/-mc3"
  [ -z "${4:-}" ] || d="$HOME/.claude/projects/$(printf '%s' "$4" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$d"
  jq -cn '{type:"user", message:{content:"Draft the launch post for the 10x community this week please"}}' > "$d/$1.jsonl"
  jq -cn '{type:"assistant", message:{model:"claude-opus-5-5", content:[{type:"text", text:"ok"}]}}' >> "$d/$1.jsonl"
  case "$2" in
    custom) jq -cn --arg t "$3" --arg s "$1" '{type:"ai-title", aiTitle:"an older ai title", sessionId:$s}, {type:"custom-title", customTitle:$t, sessionId:$s}' >> "$d/$1.jsonl" ;;
    ai)     jq -cn --arg t "$3" --arg s "$1" '{type:"ai-title", aiTitle:"first draft title", sessionId:$s}, {type:"agent-name", agentName:"[cloud] alexgreensh/ignored 01abcXYZ99", sessionId:$s}, {type:"ai-title", aiTitle:$t, sessionId:$s}' >> "$d/$1.jsonl" ;;
    agent)  jq -cn --arg t "$3" --arg s "$1" '{type:"agent-name", agentName:$t, sessionId:$s}' >> "$d/$1.jsonl" ;;
  esac
}

_mc3_peer() { # <sid> <cwd> <status>: a live Claude Code peer registration (~/.claude/sessions/<pid>.json)
  local now_ms pid; now_ms="$(( $(date +%s) * 1000 ))"
  sleep 600 & pid=$!; MC3_PIDS="${MC3_PIDS:-} $pid"
  mkdir -p "$HOME/.claude/sessions"
  jq -cn --argjson pid "$pid" --arg sid "$1" --arg cwd "$2" --arg st "$3" --argjson t "$now_ms" \
    '{pid:$pid, sessionId:$sid, cwd:$cwd, status:$st, statusUpdatedAt:$t, updatedAt:$t, startedAt:$t, kind:"interactive", version:"2.1.0"}' \
    > "$HOME/.claude/sessions/$pid.json"
}

_mc3_job() { # <id> <status> <repo> <task>
  local jd="$OSRC_HOME/jobs/$1"
  mkdir -p "$jd"
  printf '%s\n' "$2" > "$jd/status"
  jq -cn --arg w "$3" '{provider:"codex",model:"gpt-5.5",lane:"codex",verb:"edit",worktree:$w}' > "$jd/meta.json"
  printf '%s\n' "$4" > "$jd/task_ref"
}

mc3_seed() {
  mkdir -p "$OSRC_HOME/jobs" "$HOME/.claude" "$MC3_T/bin"
  local tr out
  tr="$(_mc3_repo total-recall)"; out="$(_mc3_repo outsourcerer)"
  # A: one running lane, one finished lane.
  _mc3_transcript "$MC3_SID_A" ai "TR v1.8.6 build"
  _mc3_job job-a1 running "$tr" "Sync engine retries for the cloud backup path"
  sleep 600 & MC3_SLEEP_PID=$!
  printf '%s\n' "$MC3_SLEEP_PID" > "$OSRC_HOME/jobs/job-a1/pid"
  _mc3_job job-a2 done "$tr" "Search ranking fix"
  mkdir -p "$OSRC_HOME/owners/$MC3_SID_A"
  : > "$OSRC_HOME/owners/$MC3_SID_A/job-a1"; : > "$OSRC_HOME/owners/$MC3_SID_A/job-a2"
  # B: its lane ended; the owner registry entry was removed (stop-guard rmdir'd the dir).
  _mc3_transcript "$MC3_SID_B" custom "Outsourcerer 0.16.2"
  _mc3_job job-b1 done "$out" "Mission Control heartbeat"
  mkdir -p "$OSRC_HOME/owners/$MC3_SID_B"; : > "$OSRC_HOME/owners/$MC3_SID_B/job-b1"
  printf '{"session_id":"%s"}' "$MC3_SID_B" | CLAUDE_CODE_SESSION_ID="$MC3_SID_B" bash "$MC3_ENGINE" stop-guard >/dev/null 2>&1 || true
  # C: a busy Claude session with no Outsourcerer footprint at all: never a project; it is "Also running".
  local web; web="$(_mc3_repo marketing-site)"
  _mc3_transcript "$MC3_SID_C" ai "Write a LinkedIn post" "$web"
  _mc3_peer "$MC3_SID_C" "$web" busy
  # D: idle but wrote its transcript minutes ago (shows, "idle"); E: idle for hours (never shows).
  local notes; notes="$(_mc3_repo weekly-notes)"
  _mc3_transcript "$MC3_SID_D" none "" "$notes"; _mc3_peer "$MC3_SID_D" "$notes" idle
  _mc3_transcript "$MC3_SID_E" ai "Old idle chat" "$notes"; _mc3_peer "$MC3_SID_E" "$notes" idle
  touch -t "$(date -r $(( $(date +%s) - 10800 )) +%Y%m%d%H%M 2>/dev/null || date -d "@$(( $(date +%s) - 10800 ))" +%Y%m%d%H%M)" \
    "$HOME/.claude/projects/$(printf '%s' "$notes" | tr -c 'A-Za-z0-9' '-')/$MC3_SID_E.jsonl"
  # F: a cloud session whose only title is an agent-name: "[cloud] owner/repo <id>" must read as the repo.
  _mc3_transcript "$MC3_SID_F" agent "[cloud] alexgreensh/total-recall-core 0163xupZjM" "$web"; _mc3_peer "$MC3_SID_F" "$web" busy
  # A is an orchestrator with a live peer registration too: it must not repeat under "Also running".
  _mc3_peer "$MC3_SID_A" "$tr" busy
  # Limits: 5h window at 30% resetting in ~3h, weekly at 55% resetting in ~92h.
  local now; now="$(date +%s)"
  jq -cn --argjson t "${now}000" --argjson r5 "$((now + 10800))" --argjson r7 "$((now + 333180))" \
    '{five_hour:{used_percentage:30,resets_at:$r5},seven_day:{used_percentage:55,resets_at:$r7},timestamp:$t,source:"statusline"}' \
    > "$OSRC_HOME/rate-limits.json"
  printf '{}' > "$HOME/.claude/.credentials.json"   # a logged-in Claude Code, so the limits rows exist
  printf '#!/bin/sh\nexit 0\n' > "$MC3_T/bin/claude"; chmod +x "$MC3_T/bin/claude"
}

mc3_unseed() { local p; for p in ${MC3_SLEEP_PID:-} ${MC3_PIDS:-}; do kill "$p" 2>/dev/null; done; return 0; }
