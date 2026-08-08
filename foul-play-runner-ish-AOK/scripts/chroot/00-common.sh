#!/bin/sh
# Shared setup, run once before any of the numbered build steps.
# POSIX sh only -- Alpine's /bin/sh is busybox ash.
set -eu

ALPINE_BRANCH="${ALPINE_BRANCH:?ALPINE_BRANCH must be set by build-rootfs.sh}"

# The stock minirootfs ships main enabled but community commented out --
# rust, cargo, nodejs, npm, and php all live in community.
echo "==> Enabling main + community apk repositories (v${ALPINE_BRANCH})"
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/community
EOF

echo "==> apk update"
apk update

echo "==> Installing shared base packages"
# git/patch: applying patches/*.patch via `git apply`.
# libc6-compat: esbuild's prebuilt binary (a real *production* dependency
#   of the showdown server, not just a build tool -- see BUILD_INFO.txt)
#   is glibc-linked; this is the standard, well-documented fix for running
#   glibc binaries on musl/Alpine. Kept in the final image, not stripped.
# php: build-tools/update's news-embed step shells out to `php` during
#   `node build full`; without it the client build hard-fails partway
#   through even though everything we actually need has already been
#   written by that point. Confirmed by reproducing the failure and fix
#   directly. Build-only -- removed in the final cleanup step.
apk add --no-cache \
    git patch ca-certificates libc6-compat \
    python3 python3-dev py3-pip \
    nodejs npm \
    rust cargo build-base musl-dev linux-headers openssl-dev libffi-dev \
    php

echo "==> Versions"
node --version
npm --version
python3 --version
php --version | head -1
