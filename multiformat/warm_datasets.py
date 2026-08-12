#!/usr/bin/env python3
"""
foul-play-ish-aok dataset cache warmer.

Runs once, at build time (inside the chroot, with real internet access,
before 40-launchers-and-cleanup.sh removes the build toolchain) -- plain
`venv/bin/python3`, no poke-engine variant needed on PYTHONPATH, since
fp.data.sets is poke_engine-free by construction (confirmed directly:
grep fp/ for `import poke_engine` -- it only appears in fp/battle/
inference.py, fp/battle/protocol.py, and fp/search/*.py, none of which
fp/data/sets/*.py imports; multiformat/coordinator.py's own docstring
notes this same fact, for its own unrelated reason).

For each format string given on argv, this triggers exactly the same
SmogonSets/TeamDatasets/RandomBattleTeamDatasets.initialize() calls (or,
for Battle Factory, the lower-level get_pkmn_sets_file() call the
tier-specific lookup sits on top of -- see the BATTLE_FACTORY branch
below) that fp/modes/*.py itself makes on first use of that format. It
does not reimplement any caching logic -- it only calls the real thing
early, deliberately, at a time when a failure is safe to fail loudly
instead of silently mid-battle. Whatever lands in fp/data/*_cache/ here
is byte-for-byte what a real battle would have fetched and cached itself.

Every cache file this writes is picked up permanently: none of
fp/data/sets/{base,smogon}.py's on-disk cache filenames are date-keyed
(confirmed directly -- smogon.py's *remote* URL is month-specific, but
`ntpath.basename()` of it is not, so the cache file it's saved under
never changes name across months). A file warmed here today is still a
cache hit next year, until someone deletes it by hand.

Every format on argv is attempted even if an earlier one fails -- one
tier having no published chaos stats this month (too little ladder play)
or a typo'd format string shouldn't block every other format from being
warmed. Failures are collected and reported at the end. Whether that
makes the process (and so the CI build) exit non-zero is controlled by
WARM_STRICT (default "1"): a small, hand-picked WARM_FORMATS list is
usually meant to be exhaustive -- every failure there is a real problem
worth failing loudly over, same "fail loudly, not silently" stance as
everything else in this repo. A large, auto-derived "every compatible
format" sweep (see list_compatible_formats.py) is inherently best-effort
-- plenty of those formats (draft leagues, customgame sandboxes, one-off
community rotations) were never going to have published usage-stats/
team-data in the first place, and failing the whole build over that
would just be noise -- so scripts/chroot/36-warm-datasets.sh sets
WARM_STRICT=0 specifically for that case; every failure is still printed
and still recorded, just doesn't fail the process.

Fetches run WARM_CONCURRENCY (default 8) at a time -- same
os.environ-driven-default pattern as scripts/mirror-sprites.js's
MIRROR_CONCURRENCY, and for the same reason: these are small,
independent, network-latency-bound requests (a plain synchronous requests
loop of ~260 formats at even a modest ~1s server response time each would
take minutes for no reason).
"""
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, "/opt/foul-play")

from fp.constants import BattleType  # noqa: E402
from fp.data.sets import (  # noqa: E402
    RandomBattleTeamDatasets,
    SmogonSets,
    TeamDatasets,
)
from fp.data.sets.team_datasets import get_pkmn_sets_file  # noqa: E402
from fp.format_spec import FormatSpec  # noqa: E402


def warm_one(format_string: str) -> None:
    format_spec = FormatSpec.from_format_string(format_string)

    if format_spec.battle_type == BattleType.RANDOM_BATTLE:
        print(f"[{format_string}] fetching randbats sets...")
        RandomBattleTeamDatasets().initialize(format_spec)

    elif format_spec.battle_type == BattleType.BATTLE_FACTORY:
        # BattleFactoryTeamDatasets needs a tier name that's only known
        # once a real battle reaches team preview (see
        # fp/modes/battle_factory.py's extract_battle_factory_tier_from_msg
        # -- it's parsed out of a live server message). But every tier for
        # a format lives in the SAME factory-sets.json, indexed by tier
        # name only after the file is already loaded (see
        # fp/data/sets/team_datasets.py's _get_battle_factory_sets_dict).
        # Fetching that one file covers every tier of this format --
        # nothing here has to guess a tier name.
        print(f"[{format_string}] fetching factory-sets.json...")
        get_pkmn_sets_file(format_spec.full_name, "factory-sets.json")

    else:
        # STANDARD_BATTLE and BSS both go through StandardBattleMode's own
        # SmogonSets + TeamDatasets calls (fp/modes/standard_battle.py) --
        # BSS is StandardBattleMode's own subclass, no separate data path.
        print(f"[{format_string}] fetching smogon chaos stats...")
        SmogonSets().initialize(format_spec, set())
        print(f"[{format_string}] fetching team datasets...")
        TeamDatasets().initialize(format_spec, set())


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: warm_datasets.py FORMAT [FORMAT ...]", file=sys.stderr)
        return 1

    strict = os.environ.get("WARM_STRICT", "1") == "1"
    concurrency = int(os.environ.get("WARM_CONCURRENCY", "8"))

    failures = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        future_to_format = {
            pool.submit(warm_one, format_string): format_string for format_string in argv
        }
        for future in as_completed(future_to_format):
            format_string = future_to_format[future]
            try:
                future.result()
            except Exception as exc:  # noqa: BLE001 -- report every format, not just the first failure
                print(f"error: failed to warm '{format_string}': {exc}", file=sys.stderr)
                failures.append(format_string)

    if failures:
        # Sort for stable, readable output -- as_completed() finishes in
        # whatever order the network happens to respond, not argv's order.
        failures.sort()
        print(
            f"\n{len(failures)} of {len(argv)} format(s) failed to warm: "
            f"{' '.join(failures)}",
            file=sys.stderr,
        )
        if strict:
            return 1
        print("WARM_STRICT=0: not failing the build over this -- see the errors above.", file=sys.stderr)

    print(f"\n{len(argv) - len(failures)} of {len(argv)} format(s) warmed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
