#!/usr/bin/env bash
# Guard test suites against inheriting a developer's HOME when they use the engine.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required for the test HOME guard"
  exit 1
fi
python3 -B - "${1:-$HERE}" <<'PY'
from pathlib import Path
import re, sys

# T4c's canary run found no credential reads or HOME writes for these legacy
# suites. Each is an explicit exception until its own HOME fixture is added.
ALLOW = {
    'test_blind_turn_guard.sh',          # fleet paths overridden; canary verified
    'test_catalog_validation.sh',       # catalog fixtures in OSRC_HOME; canary verified
    'test_cc_model_restore.sh',         # screen/tmux fixtures; canary verified
    'test_detection.sh',                # parser fixtures; canary verified
    'test_devin_catalog_free_tier.sh',  # fake catalog; canary verified
    'test_devin_free_guard.sh',         # fake processes/jobs; canary verified
    'test_explain.sh',                  # fake jobs; canary verified
    'test_external_send_opt_in.sh',      # fake endpoint; canary verified
    'test_fanout_json.sh',              # fake jobs; canary verified
    'test_feature_fixes.sh',            # fake jobs and screen; canary verified
    'test_fleet_names.sh',              # explicit fake session paths; canary verified
    'test_fleet_states.sh',             # explicit fake session paths; canary verified
    'test_gemini_lane.sh',              # fake catalog; canary verified
    'test_handover.sh',                 # fake owners/jobs; canary verified
    'test_heartbeat_ownership.sh',      # fake heartbeat state; canary verified
    'test_heartbeat_reclaim.sh',        # fake heartbeat state; canary verified
    'test_interactive_default.sh',      # launch parsing fixtures; canary verified
    'test_job_lifecycle.sh',            # fake jobs; canary verified
    'test_job_rc_guard_leak.sh',        # fake supervisor; canary verified
    'test_loop_escalate.sh',            # fake loop state; canary verified
    'test_loops.sh',                    # fake loop state; canary verified
    'test_model_denylist.sh',           # fake denylist and source checks; canary verified
    'test_model_pin_enforcement.sh',    # fake session registry; canary verified
    'test_no_silent_escalation.sh',     # fake delegates and keys; canary verified
    'test_obligations.sh',              # fake endpoint and state; canary verified
    'test_output_truncation.sh',        # fake supervisor output; canary verified
    'test_pr10_falsestall_before_quota.sh', # captured text fixtures; canary verified
    'test_reconcile_launch_grace.sh',   # fake job state; canary verified
    'test_reverdict_residuals.sh',      # fake heartbeat and endpoint; canary verified
    'test_stop_guard.sh',               # fake owners; canary verified
    'test_supervise.sh',                # fake owners and state; canary verified
    'test_timeout_capture.sh',          # process timeout fixtures; canary verified
    'test_tool_bugs_062.sh',            # fake quota/parser fixtures; canary verified
    'test_vocab_hygiene.sh',            # text sanitizer; canary verified
    'test_wait.sh',                     # fake jobs; canary verified
    'test_wake_queue.sh',               # fake state queue; canary verified
    'test_droid_session.sh',            # legacy session fixture; T4c static review only
    'test_managed_send.sh',             # legacy session fixture; T4c static review only
    'test_session_claims.sh',           # legacy session fixture; T4c static review only
    'test_session_control.sh',          # legacy session fixture; T4c static review only
    'test_session_exit_liveness.sh',    # legacy session fixture; T4c static review only
    'test_session_model_pin_guard.sh',  # legacy session fixture; T4c static review only
    'test_session_reply_safety.sh',     # legacy session fixture; T4c static review only
    'test_session_send_verify.sh',      # legacy session fixture; T4c static review only
    'test_tmux_kill_safety.sh',         # legacy tmux fixture; T4c static review only
    'test_watcher.sh',                  # legacy watcher fixture; T4c static review only
    'test_wrapper_liveness.sh',         # legacy tmux fixture; T4c static review only
}
# L7 owns these paths; report its hits rather than editing or exempting them silently.
L7 = re.compile(r'test_(?:cloud_.*|cloudrun|spend_.*|limit_gate|lane_billing|failover_pick|factory_exclude|autodetach)\.sh$')
HOME_EXPORT = re.compile(r'^\s*export\s+(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\'[^\']*\'|[^\s;]+)\s+)*HOME=(?:"[^"]*"|\'[^\']*\'|[^\s;]+)(?:\s|$)')
HOME_ASSIGN = re.compile(r'^\s*HOME=(?:"[^"]*"|\'[^\']*\'|[^\s;]+)\s*$')
HOME_DECLARE = re.compile(r'^\s*export\s+HOME(?:\s|$)')
ENGINE_USE = re.compile(r'(?:^|[;(&|]\s*|\s)(?:\.|source|(?:/bin/)?bash)\s+[^\n]*(?:\$\{?(?:SRC|LIB|ENGINE|SCRIPT_PATH)\b|outsourcerer\.sh|/lib/)')
ENGINE = re.compile(r'outsourcerer\.sh|/lib/|\$\{?(?:LIB|SRC|ENGINE|OSRC|SCRIPT_PATH)\b')

def uncomment(line):
    single = double = escaped = False
    for i, c in enumerate(line):
        if escaped: escaped = False; continue
        if c == '\\' and not single: escaped = True; continue
        if c == "'" and not double: single = not single
        elif c == '"' and not single: double = not double
        elif c == '#' and not single and not double and (i == 0 or line[i-1].isspace()): return line[:i]
    return line

def shell_words(line):
    # Ignore literal quoted text, but inspect commands inside double-quoted $(...).
    out = []; stack = [('plain', 0)]; i = 0
    while i < len(line):
        state, depth = stack[-1]; c = line[i]
        if c == '\\' and state != 'single': out.extend('  '); i += 2; continue
        if state == 'single':
            out.append(' ')
            if c == "'": stack.pop()
        elif state == 'double':
            if line[i:i+2] == '$(':
                out.extend('  '); stack.append(('sub', 1)); i += 2; continue
            out.append(' ')
            if c == '"': stack.pop()
        else:
            if c in "'\"":
                stack.append(('single' if c == "'" else 'double', 0)); out.append(' ')
            elif state == 'sub' and c == '(':
                stack[-1] = (state, depth+1); out.append(c)
            elif state == 'sub' and c == ')':
                if depth == 1: stack.pop()
                else: stack[-1] = (state, depth-1)
                out.append(' ')
            else: out.append(c)
        i += 1
    return ''.join(out)

def missing_home(text):
    lines = [uncomment(line) for line in text.splitlines()]
    code = '\n'.join(lines)
    if not ENGINE.search(code): return False
    assigned = False
    # Split ordinary semicolon-separated setup commands, keeping quoted semicolons intact.
    statements = []
    for line in lines:
        parts = re.split(r";(?=(?:[^'\"]|'[^']*'|\"[^\"]*\")*$)", line)
        statements.extend(parts)
    for line in statements:
        words = shell_words(line)
        if re.search(r'\bosrc_test_sandbox\b', words): return False
        if HOME_EXPORT.match(line): return False
        if HOME_ASSIGN.match(line): assigned = True; continue
        if assigned and HOME_DECLARE.match(line): return False
        if ENGINE_USE.search(line) and not re.search(r'\bbash\s+-n\b', line): return True
    return True

assert missing_home('SRC="../outsourcerer.sh"\n# HOME=/fake\nexport OSRC_HOME=/fake\n. "$SRC"')
print('PASS: comment and OSRC_HOME do not count as HOME')
assert missing_home('SRC="../outsourcerer.sh"\necho "HOME=/fake"\n. "$SRC"')
print('PASS: quoted text does not count as HOME')
assert not missing_home('SRC="../outsourcerer.sh"\nexport HOME=/fake\n. "$SRC"')
assert not missing_home('SRC="../outsourcerer.sh"\nHOME=/fake\nexport HOME\n. "$SRC"')
print('PASS: persistent HOME assignments are accepted')
assert missing_home('SRC="../outsourcerer.sh"\nHOME=/fake bash "$SRC"')
assert missing_home('SRC="../outsourcerer.sh"\n. "$SRC"\nexport HOME=/fake')
print('PASS: one-command and late assignments are rejected')

root = Path(sys.argv[1]); hits = 0; checked = 0; scanned = 0
for path in sorted(root.glob('test_*.sh')):
    scanned += 1
    if path.name == 'test_tests_set_home.sh': continue  # this guard never sources the engine
    text = path.read_text(errors='replace')
    if not missing_home(text): continue
    if L7.fullmatch(path.name):
        print('SKIP L7-owned HOME hit:', path.name)
    elif path.name in ALLOW:
        print('ALLOW reviewed legacy suite:', path.name)
    else:
        hits += 1; print('FAIL: engine or lib without HOME assignment:', path.name)
    checked += 1
if scanned < 100:
    hits += 1; print('FAIL: only %d test files scanned (minimum 100)' % scanned)
if hits:
    print('RESULT: 4 passed, %d failed' % hits); sys.exit(1)
print('PASS: no undocumented HOME guard hits (%d documented exceptions or L7 hits)' % checked)
print('RESULT: 5 passed, 0 failed')
PY
