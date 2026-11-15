# Free local rehearsal of the lock suites on a uutils coreutils host.
#
# Why: Ubuntu 26.04 (and the ubuntu-latest runner) ship uutils coreutils, whose mkdir is not an
# atomic claim (it once accepted EEXIST), and lib/atomic-claim.sh has a uutils-only branch. The
# osrc-t6-ubuntu rehearsal image has GNU coreutils, so it could never reach that branch (REL-REPORT
# 0.16.1, CI run 43751567057). This image puts uutils FIRST on PATH so `mkdir --version` reports
# uutils, exactly like the runner.
#
# Build (no registry pull beyond the ~80 MB ubuntu:24.04 base; apt packages ~250 MB):
#   docker build -t osrc-uutils scripts/ci/uutils-rehearsal
# Run (offline, read-only source, private scratch): see run.sh next to this file.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# rust-coreutils = uutils (universe). Perl and Python 3 are what real uutils hosts have and what the
# claim helper prefers; the suites themselves fake their absence where they test that branch.
RUN sed -i 's/^Components: main restricted$/Components: main restricted universe/' /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends rust-coreutils bash jq tmux git python3 perl procps locales ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Build a PATH directory with one symlink per uutils utility, wherever the package put its multicall
# binary (24.04 and 25.x lay it out differently). Fail the build if no uutils mkdir results.
RUN set -e; \
    mc=""; for c in /usr/lib/cargo/bin/coreutils /usr/bin/coreutils /usr/lib/cargo/bin/coreutils/coreutils; do \
      [ -f "$c" ] && [ -x "$c" ] && { mc="$c"; break; }; done; \
    [ -n "$mc" ] || { echo "no uutils multicall binary found" >&2; dpkg -L rust-coreutils | head -40 >&2; exit 1; }; \
    mkdir -p /opt/uutils/bin; \
    for u in $("$mc" --list 2>/dev/null | tr ',' '\n' | tr -d ' ' | grep -E '^[a-z0-9_\[]+$'); do \
      ln -sf "$mc" "/opt/uutils/bin/$u"; done; \
    /opt/uutils/bin/mkdir --version | grep -qi uutils

# uutils first: every coreutils name (mkdir, rm, mv, ln, stat, date, ...) resolves to uutils.
ENV PATH=/opt/uutils/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN mkdir --version | grep -qi uutils && command -v mkdir | grep -q '^/opt/uutils/'
WORKDIR /scratch
