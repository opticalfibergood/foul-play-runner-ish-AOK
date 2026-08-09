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

echo "==> poke-engine variants: each one imports cleanly on its own"
for feature in gen1 gen2 gen3 gen4 gen5 gen6 gen7 gen8 terastallization champions; do
    variant_dir="/opt/foul-play/poke-engine-variants/$feature"
    if ! chroot "$TMP" test -d "$variant_dir"; then
        echo "error: expected poke-engine variant directory missing: $variant_dir" >&2
        exit 1
    fi
    chroot "$TMP" /usr/bin/env -i PYTHONPATH="$variant_dir" \
        /opt/foul-play/venv/bin/python3 -c \
        "import poke_engine; print('poke_engine ($feature) OK:', poke_engine.__file__)"
done

echo "==> foul-play launcher: --pokemon-format selects the right poke-engine variant"
# FOUL_PLAY_VARIANT_DEBUG=1 makes the /usr/local/bin/foul-play wrapper
# print the variant it would have used and exit, instead of actually
# starting a battle -- see its own comments in 10-foulplay.sh.
check_variant_selection() {
    fmt="$1"
    want="$2"
    got="$(chroot "$TMP" /usr/bin/env -i FOUL_PLAY_VARIANT_DEBUG=1 \
        /usr/local/bin/foul-play --pokemon-format "$fmt" --websocket-uri ws://x \
        --ps-username bot --bot-mode accept_challenge)"
    if [ "$got" != "$want" ]; then
        echo "error: --pokemon-format $fmt selected poke-engine variant '$got', expected '$want'" >&2
        exit 1
    fi
    echo "  --pokemon-format $fmt -> $got (OK)"
}
check_variant_selection gen1ou gen1
check_variant_selection gen2ou gen2
check_variant_selection gen3ou gen3
check_variant_selection gen4ou gen4
check_variant_selection gen5ou gen5
check_variant_selection gen6ou gen6
check_variant_selection gen7ou gen7
check_variant_selection gen8ou gen8
check_variant_selection gen9ou terastallization
check_variant_selection gen9randombattle terastallization
check_variant_selection gen9championsrandombattle champions
check_variant_selection gen9championsou champions

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
