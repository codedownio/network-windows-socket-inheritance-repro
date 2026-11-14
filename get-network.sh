#!/usr/bin/env bash
# Fetch network at a given ref into ./network and generate its configure script (needs autoconf,
# which Windows usually lacks, so run this from Linux or WSL).
#   ./get-network.sh <repo> <ref>
set -euo pipefail
repo=${1:?repo}; ref=${2:?ref}
rm -rf network
git clone -q "$repo" network
git -C network checkout -q "$ref"
(cd network && autoreconf -i >/dev/null)
echo "network at $(git -C network rev-parse --short HEAD) ($(grep -m1 '^version' network/network.cabal))"
