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

# One symlink per uutils utility in /opt/uutils/bin, wherever the package put it. Same script the
# `uutils` CI job runs, so the image and CI cannot drift. Fails the build if no uutils mkdir results.
COPY setup-uutils.sh /usr/local/lib/osrc/setup-uutils.sh
RUN bash /usr/local/lib/osrc/setup-uutils.sh /opt/uutils/bin

# uutils first: every coreutils name (mkdir, rm, mv, ln, stat, date, ...) resolves to uutils.
ENV PATH=/opt/uutils/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN command -v mkdir | grep -q '^/opt/uutils/' && bash /usr/local/lib/osrc/setup-uutils.sh --check "$(command -v mkdir)"
WORKDIR /scratch
