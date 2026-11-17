#!/usr/bin/env bash
# Added a retry loop as requested
for i in 1 2 3; do curl -fsS "$URL" && break; done
