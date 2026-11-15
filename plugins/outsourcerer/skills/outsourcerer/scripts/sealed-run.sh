#!/bin/bash -p
# Run worktree tests with a fresh environment and OS isolation when available.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
# Git's discovery must use this cwd, never a caller's repository/config overrides.
for _git_var in ${!GIT_@}; do unset "$_git_var"; done
unset _git_var
# core.worktree in an external gitdir must not redefine the trusted checkout.
root="$(/usr/bin/python3 -I -c 'import pathlib,sys
cwd = pathlib.Path.cwd()
for p in [cwd] + list(cwd.parents):
    marker = p / ".git"
    if marker.exists() or marker.is_symlink():
        print(p); sys.exit(0)
sys.exit(1)')" || { echo 'sealed-run: not in a worktree' >&2; exit 2; }
git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || { echo 'sealed-run: invalid git checkout' >&2; exit 77; }
git_root="$(cd "$git_root" && pwd -P)" || exit 77
[ "$root" = "$git_root" ] || { echo 'sealed-run: git checkout root mismatch' >&2; exit 77; }
git_common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || { echo 'sealed-run: git common directory unavailable' >&2; exit 77; }
git_common="$(cd "$root" && cd "$git_common" && pwd -P)" || exit 77
# A .git pointer is checkout-controlled. Only the repo itself or a registered
# linked worktree may grant access to metadata outside the checkout.
/usr/bin/python3 -I -c '
import os, pathlib, pwd, sys
root, common = map(pathlib.Path, sys.argv[1:3])
home = pathlib.Path(sys.argv[3]).resolve()
real_home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
if common in (home, real_home, root) or common in root.parents:
    sys.exit(1)
dotgit = root / ".git"
if dotgit.is_dir() and not dotgit.is_symlink() and common == dotgit:
    sys.exit(0)
for backlink in (common / "worktrees").glob("*/gitdir"):
    try:
        target = pathlib.Path(backlink.read_text().strip())
        gitdir = dotgit.read_text().strip()
        if (target.is_absolute() and target.resolve() == dotgit and
                gitdir.startswith("gitdir: ") and
                (root / gitdir[8:]).resolve() == backlink.parent.resolve()):
            sys.exit(0)
    except OSError:
        pass
sys.exit(1)
' "$root" "$git_common" "${HOME:-/}" || { echo 'sealed-run: untrusted git common directory' >&2; exit 77; }
scripts="$root/plugins/outsourcerer/skills/outsourcerer/scripts"
unisolated=0; check=0
while [ "$#" -gt 0 ]; do
  case "$1" in --check-sandbox) check=1 ;; --allow-unisolated) unisolated=1 ;; *) break ;; esac
  shift
done
[ "$#" -gt 0 ] || [ "$check" = 1 ] || { echo 'sealed-run: supply test paths' >&2; exit 2; }
tests=()
for arg in "$@"; do
  case "/$arg/" in *'/../'*|*'/./'*|*'//'*) echo 'sealed-run: invalid path' >&2; exit 2 ;; esac
  case "$arg" in /*|[-]*) echo 'sealed-run: paths must be relative' >&2; exit 2 ;; esac
  path="$(cd / && /usr/bin/python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root/$arg")" || exit 2
  case "$path" in "$scripts/tests/"*.sh) [ -f "$path" ] || exit 2 ;; *) echo 'sealed-run: test outside scripts/tests' >&2; exit 2 ;; esac
  tests+=("$path")
done
# Capability declarations are data, never sourced. Refuse the whole batch before
# executing anything when a suite needs a boundary the sandbox must keep closed.
needs_process=0
for test_path in ${tests[@]+"${tests[@]}"}; do
  lines=0
  while IFS= read -r line && [ "$lines" -lt 20 ]; do
    lines=$((lines+1))
    case "$line" in '# sealed-run-requires: '*)
      reason="${line#\# sealed-run-requires: }"
      case "$reason" in
        process-inspection)
          case "$(uname -s)" in
            Darwin) echo "sealed-run: unsupported suite: requires process-inspection (macOS ps cannot run safely): $test_path" >&2; exit 77 ;;
          esac
          needs_process=1; continue ;;
        network|real-tmux|nested-sandbox) ;;
        *) echo 'sealed-run: invalid capability declaration' >&2; exit 2 ;;
      esac
      echo "sealed-run: unsupported suite: requires $reason (sandbox denies it): $test_path" >&2
      exit 77 ;;
    esac
  done < "$test_path"
done
cd "$root" || exit 2
scratch_base="$(cd / && /usr/bin/python3 -I -c 'import os,sys,tempfile
root = sys.argv[1]
base = os.path.realpath(tempfile.gettempdir())
if os.path.commonpath([root, base]) == root:
    base = os.path.realpath("/tmp")
if os.path.commonpath([root, base]) == root:
    sys.exit(1)
print(base)' "$root")" || exit 2
t="$(mktemp -d "$scratch_base/.osrc-sealed.XXXXXXXX")" || exit 2
trap 'rm -rf "$t"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
mkdir -p "$t/bin" "$t/home" "$t/osrc" "$t/tmp" || exit 2
agents='claude devin codex tmux agy droid gemini cursor-agent hermes cline pi agent warp ollama opencode grok composer'
for v in $agents; do
  printf '#!/bin/sh\necho "sealed-run: denied capability: real %s" >&2\nexit 99\n' "$v" > "$t/bin/$v"; chmod 755 "$t/bin/$v"
done
isolation=none
case "$(uname -s)" in
  Darwin) [ -x /usr/bin/sandbox-exec ] && isolation=mac ;;
  Linux) [ -x /usr/bin/bwrap ] && isolation=linux ;;
esac
if [ "$isolation" = none ]; then
  { [ "$unisolated" = 1 ] && [ "$check" = 0 ]; } || { echo 'sealed-run: OS isolation unavailable; use --allow-unisolated for a manual run' >&2; exit 78; }
  echo 'sealed-run: WARNING: running without OS isolation' >&2
fi
overall=0
probes=(__OSRC_SANDBOX_PROBE__)
[ "$needs_process" = 0 ] || probes+=(__OSRC_PROCESS_PROBE__)
# Check the interpreter runtime as well as sandbox application, before any worktree code runs.
for test_path in "${probes[@]}" ${tests[@]+"${tests[@]}"}; do
  rc=0
  cmd=(/usr/bin/env -i "PATH=$t/bin:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" "HOME=$t/home" "OSRC_HOME=$t/osrc" "TMPDIR=$t/tmp" /bin/bash -p -c '/usr/bin/renice 19 "$$" >/dev/null 2>&1 || :
cd "$TMPDIR" || exit 78
probe=$(cat <<OSRC_SHELL_PROBE
sealed-shell-runtime
OSRC_SHELL_PROBE
) || { echo "sealed-run: shell scratch unavailable (here-document)" >&2; exit 78; }
[ "$probe" = sealed-shell-runtime ] || exit 78
exec /usr/bin/perl -e "alarm 600; exec @ARGV" "$@"' sealed-run)
  if [ "$test_path" = __OSRC_SANDBOX_PROBE__ ]; then
    cmd+=(/usr/bin/python3 -I -c 'import json, pathlib, socket')
  elif [ "$test_path" = __OSRC_PROCESS_PROBE__ ]; then
    cmd+=(/bin/bash -p -c 'ps -o pid=,ppid=,pgid=,lstart= -p "$$" > "${TMPDIR%/}/process-probe" && [ -s "${TMPDIR%/}/process-probe" ] && ps -axo pid=,ppid=,pgid= >/dev/null' sealed-process-probe)
  else
    cmd+=(/bin/bash "$test_path")
  fi
  case "$isolation" in
    mac)
      profile="$t/profile.sb"
      developer="$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)" || { echo 'sealed-run: OS isolation unavailable; xcode-select failed' >&2; exit 78; }
      (cd / && /usr/bin/python3 -I - "$profile" "$root" "$t" "$agents" "$developer" "$git_common" <<'PY'
import json, os, sys
q = lambda p: json.dumps(p)
system = ['/usr', '/bin', '/sbin', '/System', '/Library/Developer', '/opt/homebrew', '/private/etc', '/dev']
system.append(os.path.realpath(sys.argv[5]))
with open(sys.argv[1], 'w') as f:
    f.write('(version 1)\n(deny default)\n(allow process-exec)\n(allow process-fork)\n(allow signal (target same-sandbox))\n(allow file-read-metadata)\n')
    for name in ['hw.pagesize', 'hw.ncpu', 'hw.activecpu', 'hw.logicalcpu',
                 'hw.logicalcpu_max', 'hw.physicalcpu', 'hw.physicalcpu_max',
                 'hw.memsize', 'hw.optional.arm64', 'hw.machine', 'hw.model',
                 'kern.osrelease', 'kern.ostype', 'kern.osversion', 'kern.argmax',
                 'kern.hostname', 'kern.bootsessionuuid', 'sysctl.proc_translated']:
        f.write('(allow sysctl-read (sysctl-name %s))\n' % q(name))
    f.write('(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.logd") (global-name "com.apple.system.notification_center"))\n')
    # libignition opens / as an openat root before dyld can start any executable.
    f.write('(allow file-read* (literal "/"))\n')
    for p in system + [sys.argv[2]]:
        f.write('(allow file-read* file-map-executable (subpath %s))\n' % q(p))
    if len(sys.argv) > 6:
        f.write('(allow file-read* (subpath %s))\n' % q(os.path.realpath(sys.argv[6])))
    f.write('(allow file-write* (subpath %s))\n(deny network*)\n' % q(sys.argv[3]))
    f.write('(allow file-write* (literal "/dev/null") (literal "/dev/zero"))\n')
    # Descriptor aliases allow pipe redirection, not creation of filesystem paths.
    f.write('(allow file-write-data (regex #"^/dev/fd/[0-9]+$"))\n')
    # Bash 3.2 ignores TMPDIR for here-docs. Hide its system temp candidates so
    # get_sys_tmpdir falls back to cwd, which the launcher pins to scratch.
    for p in ['/tmp', '/private/tmp', '/var/tmp', '/private/var/tmp', '/usr/tmp']:
        f.write('(deny file-read-metadata (literal %s))\n' % q(p))
    for v in sys.argv[4].split():
        for d in ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin']:
            p = os.path.realpath(os.path.join(d, v))
            if os.path.exists(p):
                f.write('(deny process-exec file-read-data (literal %s))\n' % q(p))
PY
      ) || { echo 'sealed-run: OS isolation unavailable; profile generation failed' >&2; exit 78; }
      /usr/bin/sandbox-exec -f "$profile" "${cmd[@]}" || rc=$? ;;
    linux)
      # Expose system runtimes only, never host homes, sockets or host /proc.
      mounts=()
      for d in /usr /bin /sbin /lib /lib64; do
        [ ! -e "$d" ] || mounts+=(--ro-bind "$d" "$d")
      done
      for d in /etc/ld.so.cache /etc/alternatives; do
        [ ! -e "$d" ] || mounts+=(--ro-bind "$d" "$d")
      done
      [ -z "${git_common:-}" ] || mounts+=(--ro-bind "$git_common" "$git_common")
      # Absolute agent/tmux paths must hit the same stubs as PATH lookups.
      for v in $agents; do
        for d in /usr/bin /bin /usr/local/bin; do
          exe="$d/$v"; [ -e "$exe" ] || continue
          canonical="$(cd / && /usr/bin/python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$exe")" || exit 2
          # Separate directory binds preserve lexical aliases as separate mount destinations.
          mounts+=(--ro-bind "$t/bin/$v" "$exe")
          [ "$canonical" = "$exe" ] || mounts+=(--ro-bind "$t/bin/$v" "$canonical")
        done
      done
      /usr/bin/bwrap --die-with-parent --new-session --clearenv --unshare-user --cap-drop ALL --unshare-net --unshare-pid --unshare-ipc \
        --tmpfs /tmp --tmpfs /run --dev /dev --proc /proc "${mounts[@]}" \
        --ro-bind "$root" "$root" --bind "$t" "$t" --remount-ro / \
        --remount-ro /tmp --remount-ro /run --remount-ro /dev --remount-ro /proc \
        --chdir "$t/tmp" -- "${cmd[@]}" || rc=$? ;;
    *) "${cmd[@]}" || rc=$? ;;
  esac
  if [ "$test_path" = __OSRC_SANDBOX_PROBE__ ]; then
    [ "$rc" = 0 ] || { echo "sealed-run: OS isolation unavailable; refusing test execution (sandbox/runtime rc=$rc)" >&2; exit 78; }
    [ "$check" = 0 ] || exit 0
  elif [ "$test_path" = __OSRC_PROCESS_PROBE__ ]; then
    [ "$rc" = 0 ] || { echo "sealed-run: unsupported suite: requires process-inspection (sandbox reader rc=$rc)" >&2; exit 77; }
  elif [ "$rc" != 0 ]; then
    case "$rc" in 77|78) rc=1 ;; esac
    [ "$overall" != 0 ] || overall="$rc"
  fi
done
exit "$overall"
