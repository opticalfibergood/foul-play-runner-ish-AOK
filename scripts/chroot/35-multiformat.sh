#!/bin/sh
# Installs the multi-format coordinator/worker (see multiformat/ at the
# repo root for what these actually do and why) on top of the foul-play
# install 10-foulplay.sh already finished. POSIX sh only -- Alpine's
# /bin/sh is busybox ash.
#
# Runs foreground, after 10/15/20/30 are all confirmed done (not
# concurrently with them): unlike those four, this genuinely does depend
# on another step's *output* -- 10-foulplay.sh's venv (for its
# dependencies: requests/websockets/etc., already installed there) and
# poke-engine-variants/ (each worker picks one at spawn time, same
# selection rule /usr/local/bin/foul-play itself uses) both have to
# already exist, fully populated, not mid-build.
set -eu

MULTIFORMAT_DIR="${MULTIFORMAT_DIR:?MULTIFORMAT_DIR must be set by build-rootfs.sh}"

echo "==> Installing the multi-format coordinator/worker"
mkdir -p /opt/foul-play/multiformat
cp "$MULTIFORMAT_DIR/coordinator.py" /opt/foul-play/multiformat/coordinator.py
cp "$MULTIFORMAT_DIR/worker.py" /opt/foul-play/multiformat/worker.py

echo "==> Smoke-testing that both import cleanly against the real venv"
# Fails the build loudly right here (set -eu) instead of only failing at
# runtime on-device the first time someone challenges the bot -- worth
# doing given worker.py's import chain is the one that actually reaches
# poke_engine (via fp.battle.protocol/inference), which coordinator.py's
# own imports deliberately avoid (see coordinator.py's own module
# docstring for why: it never searches a battle, so it has no use for
# constructing fp.modes's TeamDatasets()/SmogonSets()/etc. singletons,
# and every one of ITS imports stays poke_engine-free on purpose).
/opt/foul-play/venv/bin/python3 -c "
import sys
sys.path.insert(0, '/opt/foul-play')
sys.path.insert(0, '/opt/foul-play/multiformat')
import worker
import coordinator
print('worker.py and coordinator.py both imported cleanly')
"

cat >> /opt/foul-play/BUILD_INFO.txt <<EOF
multi-format coordinator/worker installed: /opt/foul-play/multiformat/{coordinator,worker}.py
EOF

echo "==> 35-multiformat.sh finished"
