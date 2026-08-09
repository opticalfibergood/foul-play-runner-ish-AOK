#!/bin/sh
# Step 15: the ONE clone + full (devDependencies included) npm install of
# pokemon-showdown itself. POSIX sh only.
#
# 20 (the real server) and 30 (which needs a throwaway pokemon-showdown
# checkout purely so its own upstream build tooling, build-tools/build-
# indexes, can extract dex data -- confirmed by reading that file directly)
# used to each do this clone+install completely independently. Measured on
# a real run: about two minutes each, for installing the exact same
# package.json's dependencies twice back to back. This step pays that cost
# once; 20 and 30 each `cp -a` this directory into place instead (seconds,
# not minutes) and go on to do their own thing with their own copy.
#
# Runs concurrently with 10/20/30 (see chroot-main.sh). 20 and 30 each poll
# for READY_MARKER below rather than being started only once this script's
# own process exits -- so neither one waits any longer than the specific
# line inside it that actually needs this.
set -eu

SHOWDOWN_REF="${SHOWDOWN_REF:-master}"
SRC_DIR=/opt/pokemon-showdown-src
READY_MARKER=/tmp/.pokemon-showdown-src-ready

echo "==> Cloning pokemon-showdown (ref: ${SHOWDOWN_REF}) -- shared source for steps 20 and 30"
git clone --depth 1 --branch "$SHOWDOWN_REF" https://github.com/smogon/pokemon-showdown.git "$SRC_DIR"
cd "$SRC_DIR"

echo "==> npm install (full -- both consumers need devDependencies present)"
npm install --no-audit --no-fund

touch "$READY_MARKER"
echo "==> 15-showdown-src.sh finished"
