#!/usr/bin/env bash
# Run the lock suites inside the uutils rehearsal image, one suite at a time, offline.
#   bash scripts/ci/uutils-rehearsal/run.sh            # all lock suites
#   bash scripts/ci/uutils-rehearsal/run.sh test_atomic_mkdir_claim   # one suite
# Build the image first: docker build -t osrc-uutils scripts/ci/uutils-rehearsal
# The source tree is mounted read-only and copied into a tmpfs, so nothing leaks back to the host.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
IMAGE="${OSRC_UUTILS_IMAGE:-osrc-uutils}"
SUITES="${*:-$(grep -v '^#' "$ROOT/scripts/ci/uutils-rehearsal/suites.txt")}"

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "image $IMAGE missing: docker build -t $IMAGE $ROOT/scripts/ci/uutils-rehearsal" >&2; exit 2; }

LOGD="$(mktemp -d)" || exit 1
trap 'rm -rf "$LOGD"' EXIT
fails=0
for s in $SUITES; do
  docker run --rm --network none --cpus 2 \
    --mount "type=bind,src=$ROOT,dst=/work,readonly" --tmpfs /scratch:exec \
    "$IMAGE" bash -c '
      set -u
      bash /usr/local/lib/osrc/setup-uutils.sh --check "$(command -v mkdir)" || { echo "FAIL: mkdir is not uutils: $(command -v mkdir)"; exit 3; }
      cp -a /work /scratch/w && cd /scratch/w
      export HOME=/scratch/home OSRC_HOME=/scratch/osrc TMPDIR=/scratch/tmp; mkdir -p "$HOME" "$OSRC_HOME" "$TMPDIR"
      bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/'"$s"'.sh' > "$LOGD/$s.log" 2>&1
  rc=$?
  printf '%-34s rc=%s  %s\n' "$s" "$rc" "$(grep -E 'RESULT|passed|PASS|FAIL' "$LOGD/$s.log" | tail -1)"
  [ "$rc" = 0 ] || { fails=$((fails+1)); grep -E 'FAIL' "$LOGD/$s.log" | head -20 | sed 's/^/    /'; }
done
echo "uutils rehearsal: $fails suite(s) failed"
[ "$fails" = 0 ]
