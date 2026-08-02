#!/usr/bin/env bash
#
# Builds an Alpine Linux root filesystem, with foul-play (and its compiled
# poke-engine Rust extension) pre-installed, that can be imported directly
# into iSH-AOK via "Import Filesystem".
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
POKE_ENGINE_GEN="${POKE_ENGINE_GEN:-}"
FOUL_PLAY_REF="${FOUL_PLAY_REF:-main}"

# The workflow_dispatch dropdown's "default" choice (meaning "don't override
# anything") arrives here as the literal string "default" -- normalize it,
# same as an actually-empty/unset value, rather than trying to get this
# right inside GitHub Actions' && / || expression syntax.
if [ "$POKE_ENGINE_GEN" = "default" ]; then
    POKE_ENGINE_GEN=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$ROOT_DIR/build"
ROOTFS="$WORK_DIR/rootfs"
OUT_DIR="$ROOT_DIR/out"

rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$ROOTFS" "$OUT_DIR"

log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Find and download the current Alpine minirootfs for $ARCH.
#    We deliberately track latest-stable instead of pinning a version, so
#    scheduled rebuilds pick up Alpine security fixes automatically.
# ---------------------------------------------------------------------------
log "Locating latest-stable Alpine minirootfs for $ARCH"

BASE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ARCH}"
LISTING="$(curl -fsSL "$BASE_URL/")"
MINIROOTFS_FILE="$(printf '%s' "$LISTING" \
    | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${ARCH}\.tar\.gz" \
    | sort -V | uniq | tail -n1)"

if [ -z "$MINIROOTFS_FILE" ]; then
    echo "error: could not find an alpine-minirootfs-*-${ARCH}.tar.gz on $BASE_URL/" >&2
    exit 1
fi

ALPINE_VERSION="$(printf '%s' "$MINIROOTFS_FILE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
echo "Found: $MINIROOTFS_FILE (Alpine $ALPINE_VERSION)"

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
# 5. Run the actual build inside the chroot.
# ---------------------------------------------------------------------------
log "Building foul-play inside the chroot (this is the slow part)"
install -m 755 "$SCRIPT_DIR/chroot-setup.sh" "$ROOTFS/chroot-setup.sh"

chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    POKE_ENGINE_GEN="$POKE_ENGINE_GEN" \
    FOUL_PLAY_REF="$FOUL_PLAY_REF" \
    /bin/sh /chroot-setup.sh

rm -f "$ROOTFS/chroot-setup.sh"
cp "$ROOTFS/opt/foul-play/BUILD_INFO.txt" "$OUT_DIR/BUILD_INFO.txt"

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
TIMESTAMP="$(date -u +%Y%m%d)"
ARTIFACT="foul-play-alpine${ALPINE_VERSION}-${ARCH}-${TIMESTAMP}.tar.gz"

tar --numeric-owner -czf "$OUT_DIR/$ARTIFACT" -C "$ROOTFS" .
cp "$OUT_DIR/$ARTIFACT" "$OUT_DIR/foul-play-alpine-${ARCH}-latest.tar.gz"

( cd "$OUT_DIR" && sha256sum ./*.tar.gz > checksums.sha256 )

cat >> "$OUT_DIR/BUILD_INFO.txt" <<EOF
alpine minirootfs: $MINIROOTFS_FILE
architecture: $ARCH
artifact: $ARTIFACT
EOF

log "Done"
ls -lh "$OUT_DIR"
