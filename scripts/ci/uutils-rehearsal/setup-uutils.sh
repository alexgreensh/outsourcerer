#!/usr/bin/env bash
# Build a PATH directory where every coreutils name resolves to uutils, wherever the rust-coreutils
# package put it (Ubuntu releases differ: a multicall binary, or a directory of per-utility links).
# Shared by the Dockerfile here and the `uutils` CI job, so the two can never drift.
#   bash setup-uutils.sh [/opt/uutils/bin]   -> prints the dir; exit 1 unless its mkdir is uutils
#   bash setup-uutils.sh --check <mkdir-path> -> exit 0 only if that mkdir is uutils (prints evidence)
set -euo pipefail

# Proof a mkdir is uutils. NOT "--version mentions uutils": Ubuntu 24.04's uutils 0.0.24 prints only
# "<argv0> 0.0.24" (newer releases print "mkdir (uutils coreutils) 0.x"), and argv0 is the invoked
# PATH, so a directory named "uutils" fakes a match. Instead: the version line must not be GNU's, and
# either it names uutils coreutils or the resolved binary belongs to the rust-coreutils package.
is_uutils_mkdir() {
  local m="$1" real ver line owner=""
  real="$(readlink -f "$m" 2>/dev/null)" || real="$m"
  ver="$(LC_ALL=C "$m" --version 2>/dev/null)" || ver=""
  line="$(printf '%s\n' "$ver" | head -1)"
  owner="$(dpkg -S "$real" 2>/dev/null | head -1)" || owner=""
  echo "mkdir=$m resolves=$real version=[$line] package=[${owner%%:*}]"
  case "$ver" in *"GNU coreutils"*) return 1 ;; esac
  case "$ver" in *"(uutils coreutils)"*) return 0 ;; esac
  case "$owner" in rust-coreutils:*) return 0 ;; esac
  return 1
}

if [ "${1:-}" = --check ]; then
  is_uutils_mkdir "${2:?usage: --check <mkdir-path>}"
  exit $?
fi
OUT="${1:-/opt/uutils/bin}"
mkdir -p "$OUT"

mc=""
for c in /usr/lib/cargo/bin/coreutils /usr/bin/coreutils /usr/lib/cargo/bin/coreutils/coreutils; do
  if [ -f "$c" ] && [ -x "$c" ]; then mc="$c"; break; fi
done
if [ -z "$mc" ]; then
  # Last resort: any executable the package ships that is named coreutils.
  mc="$(dpkg -L rust-coreutils 2>/dev/null | while read -r f; do
          case "${f##*/}" in coreutils) [ -f "$f" ] && [ -x "$f" ] && { echo "$f"; break; } ;; esac
        done)" || true
fi

if [ -n "$mc" ]; then
  for u in $("$mc" --list 2>/dev/null | tr ',' '\n' | tr -d ' ' | grep -E '^[a-z0-9_\[]+$'); do
    ln -sf "$mc" "$OUT/$u"
  done
fi
# Per-utility directory layout (e.g. /usr/lib/cargo/bin/coreutils/mkdir): link those too.
for d in /usr/lib/cargo/bin/coreutils /usr/lib/cargo/bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    [ -e "$OUT/${f##*/}" ] || ln -sf "$f" "$OUT/${f##*/}"
  done
done

if ! is_uutils_mkdir "$OUT/mkdir" >&2; then
  echo "setup-uutils: no uutils mkdir produced in $OUT" >&2
  dpkg -L rust-coreutils 2>/dev/null | head -60 >&2 || true
  exit 1
fi
printf '%s\n' "$OUT"
