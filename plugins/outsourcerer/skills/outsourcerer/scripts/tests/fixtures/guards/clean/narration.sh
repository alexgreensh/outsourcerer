#!/usr/bin/env bash
# The API drops the first call after an idle period, so try three times.
for i in 1 2 3; do curl -fsS "$URL" && break; done
