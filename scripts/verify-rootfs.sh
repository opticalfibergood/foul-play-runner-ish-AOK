#!/usr/bin/env bash
# Quick local sanity check for a built tarball: extracts it and runs
# `foul-play --help` inside a chroot. Must be run on an aarch64 (ARM64)
# Linux host or VM -- e.g. an Apple Silicon Mac's Linux VM, an AWS Graviton
# box, a Raspberry Pi -- since this tarball is aarch64 and this script does
# not set up QEMU emulation.
#
# Usage: sudo ./scripts/verify-rootfs.sh out/foul-play-alpine-aarch64-latest.tar.gz

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

cleanup() {
    set +e
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
chroot "$TMP" /usr/local/bin/foul-play --help

echo "==> import sanity check"
chroot "$TMP" /opt/foul-play/venv/bin/python3 -c \
    "import poke_engine, fp.main; print('poke_engine OK:', poke_engine.__file__)"

echo "OK"
