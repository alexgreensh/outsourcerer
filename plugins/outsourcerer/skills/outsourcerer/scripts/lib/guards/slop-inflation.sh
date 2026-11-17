#!/usr/bin/env bash
# slop-inflation: slop.py's comment-inflation class on its own, so it can default to observe while the
# other slop classes enforce.
OSRC_SLOP_CLASSES=inflation exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/slop.py"
