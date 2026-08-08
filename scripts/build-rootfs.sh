#!/usr/bin/env bash
#
# Builds an Alpine Linux root filesystem containing:
#   - foul-play, with its poke-engine Rust extension pre-compiled
#   - a pokemon-showdown server, patched to run fully offline
#     (noguestsecurity, subprocesses=0, auto-login) with no login server
#   - a pokemon-showdown client, patched to load sprites/data/the
#     websocket connection from the local server instead of the real CDN,
#     with a bounded set of sprites/icons mirrored in at build time
# ...ready to import directly into iSH-AOK via "Import Filesystem", run
# `start-showdown`, and play the bundled bot from the ish-AOK Browser tool
# with zero internet access on-device.
#
# Must be run as root (the CI workflow invokes it with `sudo -E`).
#
# Architecture: aarch64 (ARM64). This build is meant to run on a native
# arm64 CI runner (see .github/workflows/build-rootfs.yml -- GitHub's
# ubuntu-24.04-arm / ubuntu-22.04-arm hosted runners, or Blacksmith's -arm
# labels), so building the rootfs is just a normal chroot: no QEMU/binfmt
# cross-emulation, no 32-bit compat tricks, because the runner's own kernel
# already *is* aarch64. If ARCH is changed to something that doesn't match
# the runner's own architecture, the sanity check below will catch it
# early with a clear error instead of silently producing a broken image.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (try: sudo -E $0)" >&2
    exit 1
fi

ARCH="${ARCH:-aarch64}"
# Pinned, not auto-discovered: this is the exact Alpine release (and thus
# the exact python3 package) already confirmed working by hand, and it's
# also what ish-AOK itself bundles (alpine-minirootfs-3.23.3-aarch64.tar.xz
# in the ish-AOK repo). Bump this manually if you want to move to a newer
# Alpine release later -- note Alpine has since published 3.23.4 within the
# same v3.23 branch, so that's the natural next version if/when you do.
ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"
ALPINE_BRANCH="${ALPINE_VERSION%.*}"   # "3.23.3" -> "3.23"
POKE_ENGINE_GEN="${POKE_ENGINE_GEN:-}"
FOUL_PLAY_REF="${FOUL_PLAY_REF:-main}"
SHOWDOWN_REF="${SHOWDOWN_REF:-master}"
CLIENT_REF="${CLIENT_REF:-master}"
# NOT independently configurable despite being a variable: 8000 is also
# hardcoded directly inside patches/showdown-client-testclient.patch
# (Config.defaultserver.port/httpport, Config.routes.client). Changing
# this here without also updating that patch will make the server listen
# on a different port than the offline client is configured to talk to.
# Left as a named constant for readability, not exposed as a workflow
# input, on purpose.
SHOWDOWN_PORT="${SHOWDOWN_PORT:-8000}"

# The workflow_dispatch dropdown's "default" choice (meaning "don't override
# anything") arrives here as the literal string "default" -- normalize it,
# same as an actually-empty/unset value, rather than trying to get this
# right inside GitHub Actions' && / || expression syntax.
if [ "$POKE_ENGINE_GEN" = "default" ]; then
    POKE_ENGINE_GEN=""
fi

HOST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HOST_SCRIPT_DIR/.." && pwd)"
WORK_DIR="$ROOT_DIR/build"
ROOTFS="$WORK_DIR/rootfs"
OUT_DIR="$ROOT_DIR/out"

rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$ROOTFS" "$OUT_DIR"

log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Download the pinned Alpine minirootfs for $ARCH.
# ---------------------------------------------------------------------------
log "Downloading Alpine $ALPINE_VERSION minirootfs for $ARCH"

BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/${ARCH}"
MINIROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"

curl -fsSL -o "$WORK_DIR/$MINIROOTFS_FILE" "$BASE_URL/$MINIROOTFS_FILE"
curl -fsSL -o "$WORK_DIR/$MINIROOTFS_FILE.sha256" "$BASE_URL/$MINIROOTFS_FILE.sha256"

log "Verifying checksum"
( cd "$WORK_DIR" && sha256sum -c "$MINIROOTFS_FILE.sha256" )

# ---------------------------------------------------------------------------
# 2. Extract it.
# ---------------------------------------------------------------------------
log "Extracting rootfs"
tar -xzf "$WORK_DIR/$MINIROOTFS_FILE" -C "$ROOTFS"

# ---------------------------------------------------------------------------
# 3. Sanity-check that this runner's kernel actually IS $ARCH before we spend
#    time compiling Rust. This script deliberately does not set up QEMU/
#    binfmt cross-emulation -- it's meant to run on a native aarch64 runner
#    (see .github/workflows/build-rootfs.yml), which is both simpler and
#    much faster than emulating ARM64 on an x86_64 host. If someone runs
#    this on a mismatched host, fail fast with a clear reason instead of
#    silently producing a broken (or absurdly slow, under emulation) image.
# ---------------------------------------------------------------------------
log "Sanity-checking that this runner's architecture matches ARCH=$ARCH"
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "$ARCH" ]; then
    cat >&2 <<EOF

This runner reports 'uname -m' = $HOST_ARCH, but ARCH=$ARCH was requested.
This script builds natively (no QEMU/binfmt) and expects to run on a host
that already is $ARCH. Run it on an aarch64 runner instead -- e.g. GitHub's
ubuntu-24.04-arm/ubuntu-22.04-arm hosted runners, or a Blacksmith *-arm
runner label.
EOF
    exit 1
fi

if ! chroot "$ROOTFS" /bin/busybox true 2>/tmp/sanity.err; then
    cat /tmp/sanity.err >&2
    echo "error: chroot into the freshly-extracted rootfs failed" >&2
    exit 1
fi
echo "OK: host is $HOST_ARCH, chroot execution works."

# ---------------------------------------------------------------------------
# 4. Prepare the chroot: DNS, and bind-mount the pseudo-filesystems apk/pip/
#    cargo need (network sockets, /dev/null, /proc/self, etc).
# ---------------------------------------------------------------------------
log "Preparing chroot mounts"
install -m 644 /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

cleanup() {
    set +e
    for d in dev/pts dev sys proc; do
        if mountpoint -q "$ROOTFS/$d" 2>/dev/null; then
            umount -R "$ROOTFS/$d" 2>/dev/null || umount -l "$ROOTFS/$d" 2>/dev/null
        fi
    done
}
trap cleanup EXIT

mount -t proc proc "$ROOTFS/proc"
mount --rbind /sys "$ROOTFS/sys"
mount --make-rslave "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
mount --make-rslave "$ROOTFS/dev"

# ---------------------------------------------------------------------------
# 5. Run the actual build inside the chroot: foul-play, the pokemon-showdown
#    server, and the pokemon-showdown client (patched to be fully offline
#    and with a bounded set of sprites/icons mirrored in) -- see
#    scripts/chroot/*.sh, run in order by scripts/chroot-main.sh.
# ---------------------------------------------------------------------------
log "Building inside the chroot (this is the slow part)"
mkdir -p "$ROOTFS/build-input"
cp -r "$HOST_SCRIPT_DIR" "$ROOTFS/build-input/scripts"
cp -r "$ROOT_DIR/patches" "$ROOTFS/build-input/patches"

chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    ALPINE_BRANCH="$ALPINE_BRANCH" \
    POKE_ENGINE_GEN="$POKE_ENGINE_GEN" \
    FOUL_PLAY_REF="$FOUL_PLAY_REF" \
    SHOWDOWN_REF="$SHOWDOWN_REF" \
    CLIENT_REF="$CLIENT_REF" \
    SHOWDOWN_PORT="$SHOWDOWN_PORT" \
    PATCH_DIR=/build-input/patches \
    SCRIPT_DIR=/build-input/scripts \
    /bin/sh /build-input/scripts/chroot-main.sh

cp "$ROOTFS/BUILD_INFO.txt" "$OUT_DIR/BUILD_INFO.txt"
rm -rf "$ROOTFS/build-input"

# ---------------------------------------------------------------------------
# 6. Unmount before packaging, or we'd tar up the host's /proc, /sys, /dev.
# ---------------------------------------------------------------------------
log "Unmounting"
cleanup
trap - EXIT

# ---------------------------------------------------------------------------
# 7. Package it up.
# ---------------------------------------------------------------------------
log "Packaging tarball"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_BASENAME="foul-play-showdown-offline"
ARTIFACT="${ARTIFACT_BASENAME}-alpine${ALPINE_VERSION}-${ARCH}-${TIMESTAMP}.tar.gz"

tar --numeric-owner -czf "$OUT_DIR/$ARTIFACT" -C "$ROOTFS" .
cp "$OUT_DIR/$ARTIFACT" "$OUT_DIR/${ARTIFACT_BASENAME}-${ARCH}-latest.tar.gz"

( cd "$OUT_DIR" && sha256sum ./*.tar.gz > checksums.sha256 )

cat >> "$OUT_DIR/BUILD_INFO.txt" <<EOF
alpine minirootfs: $MINIROOTFS_FILE
architecture: $ARCH
artifact: $ARTIFACT
EOF

log "Done"
ls -lh "$OUT_DIR"
