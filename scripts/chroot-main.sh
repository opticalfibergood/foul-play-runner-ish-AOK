#!/bin/sh
# Runs *inside* the aarch64 Alpine chroot (invoked by build-rootfs.sh via
# plain `chroot`, since the runner is native aarch64 -- see build-rootfs.sh
# for why no QEMU/binfmt is needed here). POSIX sh only (Alpine's /bin/sh
# is busybox ash).
#
# 00 and 40 run in the foreground, in that order: 00 installs the toolchain
# everything else needs, and 40 tears build-only packages down once
# everything else is done, so both have to bracket the rest. In between,
# 10/15/20/30 run as four concurrent background jobs instead of one after
# another -- measured on a real run, 00-40 in strict sequence took about
# 7m48s of the total build; the four middle steps don't actually depend on
# each other's *output* the way running them sequentially implies:
#
#   10 (foul-play)       -- own directory, own toolchain (python/rust/
#                            cargo). Touches nothing the other three do.
#   15 (showdown-src)     -- the ONE clone+npm-install of pokemon-showdown
#                            itself, shared by 20 and 30 below (see that
#                            script's own comment for why this used to be
#                            two full, independent installs of the same
#                            repo -- about two minutes each on a real run).
#   20 (showdown-server)  -- waits on a marker file (not a process
#                            dependency) for 15's install to be ready, then
#                            `cp -a`s its own copy and builds/prunes it.
#   30 (showdown-client)  -- its own clone+npm install (much lighter, and
#                            unrelated to 15) starts immediately; only the
#                            later `node build full` step needs 15's
#                            install, so it polls for that marker right
#                            before it, not at the top of the script. It
#                            also needs 20's copy to exist (not fully
#                            built -- just cloned into place) before its
#                            own final merge step, so it polls a second
#                            marker, touched by 20 right after its own
#                            `cp -a`, right before that merge.
#
# Marker-file polling (each script blocks itself, briefly, exactly where
# it needs to) is simpler here than trying to express those partial,
# sub-step dependencies as process-level `wait`s between four separate
# `sh` invocations from this file.
#
# Each backgrounded step's stdout/stderr goes to its own log file instead
# of the live stream, so four interleaved scripts don't turn the CI log
# into an unreadable mess -- wait_bg below prints the full log afterward
# regardless of outcome, so nothing is actually hidden, just reordered to
# stay readable. A failure in any one of the four still aborts the whole
# build with that step's own exit code, same as a foreground step failing
# would -- but only once ALL FOUR have been waited on, not the moment the
# first one fails, so a still-running sibling (30 rewrites server/static
# partway through) is never left unsupervised while this script exits and
# build-rootfs.sh tears the rootfs down around it.
#
# 35 runs foreground, after all four of the above are confirmed *finished*
# (not just started): it installs the multi-format coordinator/worker
# (see multiformat/ at the repo root), which needs 10's venv and
# poke-engine-variants/ fully populated, not mid-build.
set -eu

STEP_DIR="/build-input/scripts/chroot"
LOG_DIR="/tmp/chroot-step-logs"
mkdir -p "$LOG_DIR"

run_fg() {
	echo ""
	echo "############################################################"
	echo "# Running $1"
	echo "############################################################"
	sh "$STEP_DIR/$1"
}

# Waits on a backgrounded step (name, pid) and prints its full log either
# way. Deliberately does NOT exit on failure by itself -- see FAILED_NAME
# below for why: it only records the failure and lets its siblings still
# get waited on too.
FAILED_NAME=""
FAILED_RC=0

wait_bg() {
	name="$1"
	pid="$2"
	if wait "$pid"; then
		echo ""
		echo "############################################################"
		echo "# $name finished OK -- log follows"
		echo "############################################################"
		cat "$LOG_DIR/$name.log"
	else
		rc=$?
		echo ""
		echo "############################################################" >&2
		echo "# $name FAILED (exit $rc) -- full log follows" >&2
		echo "############################################################" >&2
		cat "$LOG_DIR/$name.log" >&2
		# Record the FIRST failure only (that's the one whose exit code we
		# report), but keep going: we still need to wait_bg the remaining
		# pids below rather than exit here. 30 in particular deletes and
		# replaces /opt/pokemon-showdown/server/static partway through its
		# own run -- exiting the moment any ONE step fails would leave
		# whichever siblings are still running unsupervised while this
		# script tears down and build-rootfs.sh goes on to unmount and
		# package the rootfs around them. That's the same blind spot
		# 40-launchers-and-cleanup.sh's own supervision loop already had to
		# fix once for foul-play vs. the server -- a plain `wait` (or here,
		# exiting after just one) silently stops tracking the others. This
		# is that same fix, for the build phase's four siblings instead of
		# the runtime phase's two.
		if [ -z "$FAILED_NAME" ]; then
			FAILED_NAME="$name"
			FAILED_RC="$rc"
		fi
	fi
}

run_fg 00-common.sh

echo ""
echo "############################################################"
echo "# Starting 10/15/20/30 concurrently (see the comment at the"
echo "# top of this file for exactly what waits on what, and why)"
echo "############################################################"

# Backgrounded directly in this shell (not inside a function called via
# command substitution -- that would run in a subshell, and \$! captured
# there would not be a direct child of *this* shell, so the wait_bg calls
# below would not be able to wait on it). Order doesn't matter here, only
# that all four start before any of the waits below.
sh "$STEP_DIR/10-foulplay.sh" > "$LOG_DIR/10-foulplay.sh.log" 2>&1 &
pid10=$!
sh "$STEP_DIR/15-showdown-src.sh" > "$LOG_DIR/15-showdown-src.sh.log" 2>&1 &
pid15=$!
sh "$STEP_DIR/20-showdown-server.sh" > "$LOG_DIR/20-showdown-server.sh.log" 2>&1 &
pid20=$!
sh "$STEP_DIR/30-showdown-client.sh" > "$LOG_DIR/30-showdown-client.sh.log" 2>&1 &
pid30=$!

wait_bg 10-foulplay.sh "$pid10"
wait_bg 15-showdown-src.sh "$pid15"
wait_bg 20-showdown-server.sh "$pid20"
wait_bg 30-showdown-client.sh "$pid30"

# Every one of the four is confirmed finished (successfully or not) at
# this point -- safe to abort now if any of them failed, since there's no
# longer a still-running sibling left for build-rootfs.sh to race against.
if [ -n "$FAILED_NAME" ]; then
	echo ""
	echo "############################################################" >&2
	echo "# Aborting: $FAILED_NAME failed above (exit $FAILED_RC)" >&2
	echo "############################################################" >&2
	exit "$FAILED_RC"
fi

# Needs 10-foulplay.sh's venv + poke-engine-variants fully finished (not
# just started) -- foreground, after the wait_bg calls above have already
# confirmed that, rather than a fifth concurrent job racing it.
run_fg 35-multiformat.sh

run_fg 40-launchers-and-cleanup.sh

echo ""
echo "All chroot build steps completed."
