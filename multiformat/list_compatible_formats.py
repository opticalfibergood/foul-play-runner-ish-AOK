#!/usr/bin/env python3
"""
foul-play-ish-aok "every directly compatible format" list.

There is no fixed, externally-published list of "every format foul-play
can play" to just look up -- the actual source of truth is whatever this
specific build's bundled pokemon-showdown server itself defines in
config/formats.ts (that file IS the whole set of formats this device's
server can ever offer a challenge in -- nothing else exists to challenge
into). So this reads it directly, out of the exact showdown checkout this
image is shipping, rather than a hardcoded list here that would silently
drift from whatever SHOWDOWN_REF actually built.

config/formats.ts is TypeScript, not JSON (unquoted keys, trailing
commas, and -- inside a handful of formats' inline rule functions like
onValidateTeam -- real TS-only syntax such as `as ID` casts and typed
`const x: SomeType = ...` locals). Rather than transpile the whole file
(and inevitably fight more one-off TS syntax someone adds to a rule
function later), this only ever looks at simple top-level
`key: 'value',`-shaped lines directly inside each format's own {...}
object -- exactly the shape name/mod/team/gameType/rated/challengeShow
actually appear in, and never how they'd appear if matched accidentally
inside a nested rule function body. Brace/string/comment-aware scanning
(not a naive per-line split) is what finds those top-level object
boundaries correctly despite everything nested inside them.

"Directly compatible" here means all three of:
  - singles (gameType absent, or 'singles' -- excludes every 'doubles',
    'triples', 'multi', 'freeforall' format outright: foul-play's own
    battle/search code has no doubles-battle handling at all, confirmed
    directly -- grep fp/ turns up nothing resembling gameType or
    multi-slot handling anywhere in fp/modes, fp/battle, or fp/search)
  - laddered (rated is not explicitly false -- excludes the handful of
    hidden/test variants like "[Gen 9] Unrated Random Battle")
  - challengeable (challengeShow is not explicitly false -- excludes
    formats nobody could ever actually challenge the bot to in the first
    place, since multiformat/coordinator.py only ever responds to
    incoming /challenge PMs)
  - has a recognized gen1-gen9 in its id (matches fp/format_spec.py's own
    `gen([1-9]0?)` regex) -- poke-engine only has gen1-gen9 (+ Champions)
    variants built (see scripts/chroot/10-foulplay.sh, 20-poke-engine.sh)

This deliberately does NOT try to further guess which of those formats
Smogon/foulplay.cc actually publish usage-stats/team-data for (customgame
sandboxes, draft leagues, and plenty of Other-Metagames rotation formats
almost certainly don't) -- that's not this script's job to predict, and
guessing would just reintroduce the same "stale list baked from someone's
assumptions" problem this whole approach exists to avoid. It's
warm_datasets.py's job (via WARM_STRICT, see its own docstring) to attempt
every one of these and report -- not skip, guess, or silently drop
some -- which ones actually had data to fetch.
"""
import re
import sys


def to_ps_id(name: str) -> str:
    """Mirrors Pokemon Showdown's own toID(): lowercase, strip everything
    that isn't a-z0-9. E.g. "[Gen 9] Random Battle" -> "gen9randombattle".
    """
    return re.sub(r"[^a-z0-9]", "", name.lower())


def _skip_string(s: str, i: int, quote: str) -> int:
    i += 1
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == quote:
            return i + 1
        i += 1
    return i


def _skip_template(s: str, i: int) -> int:
    # Naive: doesn't handle ${...} interpolation containing a nested
    # backtick. None of formats.ts's template literals do that.
    i += 1
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == "`":
            return i + 1
        i += 1
    return i


def extract_top_level_entries(text: str) -> list[str]:
    """Returns the raw text inside each top-level `{...}` item of the
    `export const Formats: ... = [ ... ]` array, comment/string/template
    literal aware so nested braces inside inline rule functions never
    confuse where one format entry ends and the next begins.
    """
    marker = "export const Formats: import("
    if marker not in text:
        raise ValueError(
            "couldn't find 'export const Formats: import(...)' in this "
            "file -- is this really pokemon-showdown's config/formats.ts?"
        )
    start = text.index("[", text.index(marker))

    n = len(text)
    i = start
    array_depth = 0
    brace_depth = 0
    item_start = None
    items = []
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            i = text.index("\n", i) + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i = text.index("*/", i) + 2
            continue
        if c in ("'", '"'):
            i = _skip_string(text, i, c)
            continue
        if c == "`":
            i = _skip_template(text, i)
            continue
        if c == "[":
            array_depth += 1
            i += 1
            continue
        if c == "]":
            array_depth -= 1
            i += 1
            if array_depth == 0:
                break
            continue
        if c == "{":
            if brace_depth == 0 and array_depth == 1:
                item_start = i + 1
            brace_depth += 1
            i += 1
            continue
        if c == "}":
            brace_depth -= 1
            if brace_depth == 0 and array_depth == 1 and item_start is not None:
                items.append(text[item_start:i])
                item_start = None
            i += 1
            continue
        i += 1
    return items


def _field(entry: str, key: str, kind: str = "str"):
    if kind == "str":
        m = re.search(r"^\s*" + key + r":\s*['\"]([^'\"]*)['\"]", entry, re.MULTILINE)
        return m.group(1) if m else None
    m = re.search(r"^\s*" + key + r":\s*(true|false)", entry, re.MULTILINE)
    return (m.group(1) == "true") if m else None


_GEN_RE = re.compile(r"gen[1-9]")


def compatible_format_ids(formats_ts_text: str) -> list[str]:
    ids = []
    for entry in extract_top_level_entries(formats_ts_text):
        name = _field(entry, "name")
        if name is None:
            continue  # a `{section: "..."}` header, not a format
        if _field(entry, "gameType") not in (None, "singles"):
            continue
        if _field(entry, "rated", "bool") is False:
            continue
        if _field(entry, "challengeShow", "bool") is False:
            continue
        format_id = to_ps_id(name)
        if not _GEN_RE.search(format_id):
            continue
        ids.append(format_id)
    return ids


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: list_compatible_formats.py path/to/config/formats.ts", file=sys.stderr)
        return 1
    text = open(argv[0], encoding="utf-8").read()
    ids = compatible_format_ids(text)
    if not ids:
        print("error: parsed formats.ts but found zero compatible formats -- parser is likely broken", file=sys.stderr)
        return 1
    print(" ".join(ids))
    print(f"({len(ids)} directly-compatible formats)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
