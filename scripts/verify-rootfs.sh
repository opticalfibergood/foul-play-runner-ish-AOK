#!/usr/bin/env bash
# Quick local sanity check for a built tarball: extracts it, checks
# foul-play and the bundled offline pokemon-showdown server both work
# inside a chroot, and actually starts the server briefly to confirm it
# comes up and serves the patched client. Must be run on an aarch64
# (ARM64) Linux host or VM -- e.g. an Apple Silicon Mac's Linux VM, an AWS
# Graviton box, a Raspberry Pi -- since this tarball is aarch64 and this
# script does not set up QEMU emulation.
#
# Usage: sudo ./scripts/verify-rootfs.sh out/foul-play-showdown-offline-aarch64-latest.tar.gz

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root" >&2
    exit 1
fi

if [ "$(uname -m)" != "aarch64" ]; then
    echo "error: this must run on an aarch64 host (got $(uname -m))" >&2
    exit 1
fi

TARBALL="${1:?usage: $0 <path-to-tarball>}"
TMP="$(mktemp -d)"
SERVER_PID=""

cleanup() {
    set +e
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    for d in dev/pts dev sys proc; do
        mountpoint -q "$TMP/$d" 2>/dev/null && umount -R "$TMP/$d" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

tar -xzf "$TARBALL" -C "$TMP"
install -m 644 /etc/resolv.conf "$TMP/etc/resolv.conf"
mount -t proc proc "$TMP/proc"
mount --rbind /sys "$TMP/sys"
mount --rbind /dev "$TMP/dev"

echo "==> foul-play --help"
chroot "$TMP" /usr/local/bin/foul-play --help >/dev/null

echo "==> foul-play import sanity check"
chroot "$TMP" /opt/foul-play/venv/bin/python3 -c \
    "import poke_engine, fp.main, fp.websocket_client; print('poke_engine OK:', poke_engine.__file__)"

echo "==> starting the bundled showdown server briefly"
chroot "$TMP" /usr/bin/env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin \
    sh -c 'cd /opt/pokemon-showdown && node pokemon-showdown start --skip-build 8000' &
SERVER_PID=$!

tries=0
until chroot "$TMP" /usr/bin/wget -q -O /dev/null http://localhost:8000/ 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
        echo "error: server did not come up after 30s" >&2
        exit 1
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "error: server process died" >&2; exit 1; }
    sleep 0.5
done
echo "server responded OK"

echo "==> checking the served page is the patched, offline-configured client"
PAGE="$(chroot "$TMP" /usr/bin/wget -q -O - http://localhost:8000/)"
echo "$PAGE" | grep -q 'localhost:8000' || { echo "error: served page doesn't reference localhost:8000" >&2; exit 1; }

kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo "OK"
