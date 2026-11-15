#!/bin/bash -p
# Run worktree tests with a fresh environment and OS isolation when available.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo 'sealed-run: not in a worktree' >&2; exit 2; }
root="$(cd "$root" && pwd -P)" || exit 2
scripts="$root/plugins/outsourcerer/skills/outsourcerer/scripts"
unisolated=0; check=0
if [ "${1:-}" = --check-sandbox ]; then check=1; shift; fi
if [ "${1:-}" = --allow-unisolated ]; then unisolated=1; shift; fi
[ "$#" -gt 0 ] || [ "$check" = 1 ] || { echo 'sealed-run: supply test paths' >&2; exit 2; }
tests=()
for arg in "$@"; do
  case "/$arg/" in *'/../'*|*'/./'*|*'//'*) echo 'sealed-run: invalid path' >&2; exit 2 ;; esac
  case "$arg" in /*|[-]*) echo 'sealed-run: paths must be relative' >&2; exit 2 ;; esac
  path="$(cd / && /usr/bin/python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root/$arg")" || exit 2
  case "$path" in "$scripts/tests/"*.sh) [ -f "$path" ] || exit 2 ;; *) echo 'sealed-run: test outside scripts/tests' >&2; exit 2 ;; esac
  tests+=("$path")
done
cd "$root" || exit 2
t="$(mktemp -d "$root/.osrc-sealed.XXXXXXXX")" || exit 2
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/osrc" "$t/tmp" || exit 2
agents='claude devin codex tmux agy droid gemini cursor-agent hermes'
for v in $agents; do
  printf '#!/bin/sh\nexit 99\n' > "$t/bin/$v"; chmod 755 "$t/bin/$v"
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
# Check the interpreter runtime as well as sandbox application, before any worktree code runs.
[ "$check" = 0 ] || tests=(/usr/bin/true)
for test_path in __OSRC_SANDBOX_PROBE__ "${tests[@]}"; do
  rc=0
  cmd=(/usr/bin/env -i "PATH=$t/bin:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" "HOME=$t/home" "OSRC_HOME=$t/osrc" "TMPDIR=$t/tmp" /bin/bash -p -c '/usr/bin/renice 19 "$$" >/dev/null 2>&1 || :; exec /usr/bin/perl -e "alarm 600; exec @ARGV" "$@"' sealed-run)
  if [ "$test_path" = __OSRC_SANDBOX_PROBE__ ]; then
    cmd+=(/usr/bin/python3 -I -c 'import json, pathlib, socket')
  else
    cmd+=(/bin/bash "$test_path")
  fi
  case "$isolation" in
    mac)
      profile="$t/profile.sb"
      developer="$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)" || exit 2
      (cd / && /usr/bin/python3 -I - "$profile" "$root" "$t" "$agents" "$developer" <<'PY'
import json, os, sys
q = lambda p: json.dumps(p)
system = ['/usr', '/bin', '/sbin', '/System', '/Library/Developer', '/opt/homebrew', '/private/etc', '/dev']
system.append(os.path.realpath(sys.argv[5]))
with open(sys.argv[1], 'w') as f:
    f.write('(version 1)\n(deny default)\n(allow process-exec)\n(allow process-fork)\n(allow signal (target same-sandbox))\n(allow sysctl-read)\n(allow file-read-metadata)\n')
    f.write('(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.logd") (global-name "com.apple.system.notification_center"))\n')
    # libignition opens / as an openat root before dyld can start any executable.
    f.write('(allow file-read* (literal "/"))\n')
    for p in system + [sys.argv[2]]:
        f.write('(allow file-read* file-map-executable (subpath %s))\n' % q(p))
    f.write('(allow file-write* (subpath %s))\n(deny network*)\n' % q(sys.argv[3]))
    f.write('(allow file-write* (literal "/dev/null") (literal "/dev/zero"))\n')
    for v in sys.argv[4].split():
        for d in ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin']:
            p = os.path.realpath(os.path.join(d, v))
            if os.path.exists(p):
                f.write('(deny process-exec file-read-data (literal %s))\n' % q(p))
PY
      ) || exit 2
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
        "${mounts[@]}" --tmpfs /tmp --tmpfs /run --dev /dev --proc /proc \
        --ro-bind "$root" "$root" --bind "$t" "$t" --remount-ro / --chdir "$root" -- "${cmd[@]}" || rc=$? ;;
    *) "${cmd[@]}" || rc=$? ;;
  esac
  if [ "$test_path" = __OSRC_SANDBOX_PROBE__ ]; then
    [ "$rc" = 0 ] || { echo "sealed-run: OS isolation unavailable; refusing test execution (sandbox/runtime rc=$rc)" >&2; exit 78; }
    [ "$check" = 0 ] || exit 0
  elif [ "$rc" != 0 ]; then overall="$rc"; fi
done
exit "$overall"
