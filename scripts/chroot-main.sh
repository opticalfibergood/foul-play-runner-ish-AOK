#!/bin/sh
# Runs *inside* the aarch64 Alpine chroot (invoked by build-rootfs.sh via
# plain `chroot`, since the runner is native aarch64 -- see build-rootfs.sh
# for why no QEMU/binfmt is needed here). POSIX sh only.
#
# Just runs each numbered step in scripts/chroot/ in order. Kept as
# separate files instead of one big script so each concern (repo setup,
# foul-play, the showdown server, the showdown client, final packaging)
# is independently readable and editable.
set -eu

STEP_DIR="/build-input/scripts/chroot"

for step in "$STEP_DIR"/*.sh; do
	echo ""
	echo "############################################################"
	echo "# Running $(basename "$step")"
	echo "############################################################"
	sh "$step"
done

echo ""
echo "All chroot build steps completed."
