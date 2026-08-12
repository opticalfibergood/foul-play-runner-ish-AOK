#!/bin/sh
# Step 36: pre-fetch and cache the usage-stats/team-dataset files foul-play
# would otherwise fetch live, on first use, from smogon.com,
# data.foulplay.cc, and pkmn.github.io -- for a list of formats chosen at
# build time (WARM_FORMATS below), while this chroot still has real
# internet access and a build failure is safe to be loud about.
#
# This is separate from "fully offline" as the README's "What 'fully
# offline' actually required" section defines it (that's about the login
# server and the server/client's own network assumptions, not this).
# foul-play's own fp/data/sets/*.py already caches these files
# permanently once fetched once -- confirmed directly: none of its
# on-disk cache filenames are date-keyed, not even smogon.py's chaos
# stats, despite the *remote* URL it downloads from being month-specific
# (ntpath.basename() of that URL drops the "/2026-07/" path segment
# entirely, so the cache file saved locally is just "gen9ou-0.json",
# identical every month). A file fetched once is used forever, until
# someone deletes it by hand. Running that same fetch-and-cache path
# here, once per format below, means an on-device run of start-showdown
# is never the FIRST call for any of them -- it always finds a cache hit
# and never touches the network, for exactly the formats this step warms.
#
# Runs after 35-multiformat.sh (foreground, not one of the four
# concurrent 10/15/20/30 jobs): needs 10-foulplay.sh's venv, same as 35,
# and (for WARM_FORMATS=auto below) 20-showdown-server.sh's
# /opt/pokemon-showdown/config/formats.ts -- it just happens to live in
# the same numeric neighborhood since it's the last foul-play-side data
# step before 40 tears the build toolchain down.
#
# WARM_FORMATS="auto" (the default) means "every format this image's own
# bundled Showdown server can directly be challenged into, that
# foul-play's engine can actually play" -- see
# multiformat/list_compatible_formats.py for exactly what that means and
# why it's derived from THIS build's own config/formats.ts rather than a
# hardcoded list here (which would just silently drift from whatever
# SHOWDOWN_REF actually built). That's a big, best-effort sweep (~260
# formats as of writing) -- plenty of them (draft leagues, customgame
# sandboxes, one-off community rotations) were never going to have
# published usage-stats/team-data in the first place, so this runs it
# non-strict (WARM_STRICT=0: every failure still gets printed and still
# recorded in BUILD_INFO.txt, it just doesn't fail the whole build) unless
# WARM_STRICT is already set in the environment.
#
# Set WARM_FORMATS explicitly (a plain space-separated list, e.g.
# "gen9ou gen9randombattle") to warm only formats you actually intend to
# play instead -- much faster, and since a hand-picked list is presumably
# meant to be exhaustive, this then defaults WARM_STRICT=1: any failure
# there fails the whole build loudly, same as everywhere else in this
# repo, rather than silently shipping an image where that format will
# just hang or error the first time someone tries to battle in it on a
# device with no internet to do anything about it in the moment.
set -eu

MULTIFORMAT_DIR="${MULTIFORMAT_DIR:?MULTIFORMAT_DIR must be set by build-rootfs.sh}"
WARM_FORMATS="${WARM_FORMATS:-auto}"

if [ "$WARM_FORMATS" = "auto" ]; then
    echo "==> WARM_FORMATS=auto -- deriving every directly-compatible format from this build's own config/formats.ts"
    FORMATS_TS=/opt/pokemon-showdown/config/formats.ts
    [ -f "$FORMATS_TS" ] || { echo "error: $FORMATS_TS not found -- did 20-showdown-server.sh run first?" >&2; exit 1; }
    WARM_FORMATS="$(python3 "$MULTIFORMAT_DIR/list_compatible_formats.py" "$FORMATS_TS")"
    WARM_STRICT="${WARM_STRICT:-0}"
else
    WARM_STRICT="${WARM_STRICT:-1}"
fi
export WARM_STRICT

echo "==> Warming usage-stats/team-dataset caches (WARM_STRICT=$WARM_STRICT) for:"
echo "    $WARM_FORMATS"
# shellcheck disable=SC2086  # WARM_FORMATS is deliberately word-split here:
# a space-separated list of format strings, not a single argument.
/opt/foul-play/venv/bin/python3 "$MULTIFORMAT_DIR/warm_datasets.py" $WARM_FORMATS

cat >> /opt/foul-play/BUILD_INFO.txt <<EOF
dataset caches pre-warmed for (scripts/chroot/36-warm-datasets.sh, WARM_STRICT=$WARM_STRICT): $WARM_FORMATS
EOF

echo "==> 36-warm-datasets.sh finished"
