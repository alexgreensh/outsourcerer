#!/bin/bash
# Run worktree tests with a fresh environment and OS isolation when available.
set -u
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo 'sealed-run: not in a worktree' >&2; exit 2; }
root="$(cd "$root" && pwd -P)" || exit 2
scripts="$root/plugins/outsourcerer/skills/outsourcerer/scripts"
unisolated=0
if [ "${1:-}" = --allow-unisolated ]; then unisolated=1; shift; fi
[ "$#" -gt 0 ] || { echo 'sealed-run: supply test paths' >&2; exit 2; }
tests=()
for arg in "$@"; do
  case "/$arg/" in *'/../'*|*'/./'*|*'//'*) echo 'sealed-run: invalid path' >&2; exit 2 ;; esac
  case "$arg" in /*|[-]*) echo 'sealed-run: paths must be relative' >&2; exit 2 ;; esac
  path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root/$arg")" || exit 2
  case "$path" in "$scripts/tests/"*.sh) [ -f "$path" ] || exit 2 ;; *) echo 'sealed-run: test outside scripts/tests' >&2; exit 2 ;; esac
  tests+=("$path")
done
real_home="${HOME:?sealed-run: HOME required}"
t="$(mktemp -d "$root/.osrc-sealed.XXXXXXXX")" || exit 2
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/osrc" "$t/tmp" || exit 2
for v in claude devin codex tmux agy droid gemini cursor-agent hermes; do
  printf '#!/bin/sh\nexit 99\n' > "$t/bin/$v"; chmod 755 "$t/bin/$v"
done
isolation=none
case "$(uname -s)" in
  Darwin) [ -x /usr/bin/sandbox-exec ] && isolation=mac ;;
  Linux) [ -x /usr/bin/bwrap ] && isolation=linux ;;
esac
if [ "$isolation" = none ]; then
  [ "$unisolated" = 1 ] || { echo 'sealed-run: no OS isolation; use --allow-unisolated for a manual run' >&2; exit 2; }
  echo 'sealed-run: WARNING: running without OS isolation' >&2
fi
rc=0
for test_path in "${tests[@]}"; do
  cmd=(/usr/bin/env -i "PATH=$t/bin:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" "HOME=$t/home" "OSRC_HOME=$t/osrc" "TMPDIR=$t/tmp" /usr/bin/nice -n 15 /usr/bin/perl -e 'alarm 600; exec @ARGV' /bin/bash "$test_path")
  case "$isolation" in
    mac)
      profile="$t/profile.sb"
      python3 - "$profile" "$root" "$t" <<'PY'
import json, sys
q = lambda p: json.dumps(p)
system = ['/usr', '/bin', '/sbin', '/System', '/Library', '/opt/homebrew', '/private/etc', '/dev']
with open(sys.argv[1], 'w') as f:
    f.write('(version 1)\n(deny default)\n(allow process*)\n(allow sysctl-read)\n(allow mach-lookup)\n')
    for p in system + [sys.argv[2]]:
        f.write('(allow file-read* (subpath %s))\n' % q(p))
    f.write('(allow file-write* (subpath %s))\n(deny network*)\n' % q(sys.argv[3]))
PY
      /usr/bin/sandbox-exec -f "$profile" "${cmd[@]}" || rc=$? ;;
    linux)
      # The home overlay hides credentials; re-expose only this worktree as read-only.
      dirs=(); d="$root"
      case "$root/" in "$real_home/"*)
        while [ "$d" != "$real_home" ] && [ "$d" != / ]; do dirs=(--dir "$d" "${dirs[@]}"); d="$(dirname "$d")"; done ;;
      esac
      /usr/bin/bwrap --unshare-net --ro-bind / / --tmpfs "$real_home" "${dirs[@]}" --ro-bind "$root" "$root" --bind "$t" "$t" -- "${cmd[@]}" || rc=$? ;;
    *) "${cmd[@]}" || rc=$? ;;
  esac
done
exit "$rc"
