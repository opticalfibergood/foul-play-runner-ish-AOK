#!/usr/bin/env python3
"""
foul-play-ish-aok multi-format worker.

Plays foul-play battles for exactly one poke-engine generation/variant,
driven entirely by JSON-lines on stdin/stdout instead of its own
websocket connection -- it never logs in to Pokemon Showdown itself.
The coordinator (coordinator.py) owns the one real, logged-in
connection for the bot's entire lifetime and pipes raw PS protocol
lines to/from whichever worker is currently playing a battle.

This process is spawned by the coordinator with the correct
poke-engine variant already first on PYTHONPATH (see
coordinator.py's WORKER_ENV_FOR_FEATURE / the existing
/usr/local/bin/foul-play wrapper's own selection logic, which this
mirrors) -- exactly one variant per process, for its whole life, which
is why it's kept warm and reused across consecutive battles of the
*same* generation rather than respawned every time: fp's own
apply_mods() (see fp/data/mods/apply_mods.py) mutates the in-memory
pokedex/movedex dictionaries downward from gen9 defaults and has no
way to undo that, so a single process can only ever really be "one
generation" for its whole life -- switching generations always means a
new process, never a new codepath within this one.

Wire protocol, newline-delimited JSON:

  coordinator -> worker (stdin):
    {"type": "start_battle", "format": "...", "team_dict": {...},
     "username": "bot", "search_time_ms": 100, "search_parallelism": 1,
     "team_preview_search_time_ms": null, "team_preview_search_parallelism": null,
     "search_threads": 1, "smogon_stats": null, "save_replay": "never"}
    {"type": "recv", "msg": "<raw PS protocol text, exactly what
     ps_websocket_client.receive_message() would have returned>"}
    {"type": "shutdown"}

  worker -> coordinator (stdout):
    {"type": "worker_ready"}                     -- process is up, waiting for "start_battle"
    {"type": "send", "room": "...", "lines": [...]}  -- forward this out over the real socket
    {"type": "battle_done", "winner": "..."}      -- battle finished, worker idle again
    {"type": "battle_error", "error": "..."}      -- battle crashed; worker is exiting
    {"type": "log", "message": "..."}             -- informational only

Only ever reads/writes stdin/stdout for protocol -- everything else
(logging, tracebacks) goes to stderr, which the coordinator captures
separately so it never gets mistaken for a protocol line.
"""
import asyncio
import json
import logging
import sys
import traceback

sys.path.insert(0, "/opt/foul-play")

from fp.config import FoulPlayConfig, SaveReplay  # noqa: E402
from fp.data.mods.apply_mods import apply_mods  # noqa: E402
from fp.format_spec import FormatSpec  # noqa: E402
from fp.run_battle import pokemon_battle  # noqa: E402
from fp.websocket_client import PSWebsocketClient  # noqa: E402

logging.basicConfig(
    level=logging.INFO, stream=sys.stderr, format="%(levelname)-8s %(message)s"
)
logger = logging.getLogger("worker")


def _emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


class StdioRelayClient(PSWebsocketClient):
    """
    Same public surface as PSWebsocketClient, but reads/writes the
    stdin/stdout protocol above instead of a real websocket.
    Deliberately does NOT override __init__/create/login/close -- this
    is only ever handed to fp.run_battle.pokemon_battle(), which never
    calls any of those; it only calls receive_message/send_message
    (and, through the base class's own unmodified leave_battle/
    save_replay, those two again) -- see fp/run_battle.py and
    fp/modes/base.py's start_battle_common for the exhaustive list.
    """

    def __init__(self, stdin_reader):
        self._reader = stdin_reader

    async def receive_message(self):
        while True:
            line = await self._reader.readline()
            if not line:
                raise ConnectionError("coordinator closed stdin")
            envelope = json.loads(line)
            kind = envelope.get("type")
            if kind == "recv":
                return envelope["msg"]
            if kind == "shutdown":
                raise ConnectionError("coordinator requested shutdown")
            # anything else on stdin mid-battle is unexpected; ignore and
            # keep waiting rather than crashing the battle over it.

    async def send_message(self, room, message_list):
        _emit({"type": "send", "room": room, "lines": message_list})


async def _read_envelope(reader):
    line = await reader.readline()
    if not line:
        return None
    return json.loads(line)


def _configure_for_battle(envelope):
    FoulPlayConfig.username = envelope["username"]
    FoulPlayConfig.pokemon_format = envelope["format"]
    FoulPlayConfig.search_time_ms = envelope.get("search_time_ms", 100)
    FoulPlayConfig.parallelism = envelope.get("search_parallelism", 1)
    FoulPlayConfig.team_preview_search_time_ms = (
        envelope.get("team_preview_search_time_ms")
        or FoulPlayConfig.search_time_ms
    )
    FoulPlayConfig.team_preview_search_parallelism = (
        envelope.get("team_preview_search_parallelism")
        or FoulPlayConfig.parallelism
    )
    FoulPlayConfig.search_threads = envelope.get("search_threads", 1)
    FoulPlayConfig.smogon_stats = envelope.get("smogon_stats")
    FoulPlayConfig.save_replay = SaveReplay[envelope.get("save_replay", "never")]


async def main():
    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    relay = StdioRelayClient(reader)

    # Block for the very first battle. Its format is what fixes this
    # process's generation for its entire remaining life -- apply_mods()
    # only ever runs once, here, using that first format.
    envelope = await _read_envelope(reader)
    if envelope is None or envelope.get("type") != "start_battle":
        logger.error("expected an initial start_battle envelope, got: %r", envelope)
        return

    _configure_for_battle(envelope)
    format_spec = FormatSpec.from_format_string(envelope["format"])
    apply_mods(format_spec)
    logger.info("mods applied for generation %s; ready", format_spec.generation)
    _emit({"type": "worker_ready", "generation": format_spec.generation})

    while envelope is not None:
        team_dict = envelope.get("team_dict") or {}
        try:
            winner = await pokemon_battle(relay, envelope["format"], team_dict)
            _emit({"type": "battle_done", "winner": winner})
        except Exception:
            logger.error("battle crashed:\n%s", traceback.format_exc())
            _emit({"type": "battle_error", "error": traceback.format_exc()})
            return

        envelope = await _read_envelope(reader)
        if envelope is None:
            return
        if envelope.get("type") == "shutdown":
            return
        if envelope.get("type") != "start_battle":
            continue
        # Same generation for every battle after the first -- the
        # coordinator guarantees this by only ever reusing a worker for
        # formats that map to the same poke-engine variant; re-derive
        # and re-configure per battle anyway since tier (OU vs Ubers
        # vs random, etc.) can differ battle to battle even within one
        # generation, and fp's own dataset/stats initialization already
        # keys off the *full* format string each time (see
        # fp/modes/standard_battle.py's start_battle) -- only
        # apply_mods() is a true do-it-once.
        _configure_for_battle(envelope)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception:
        logger.error("worker crashed:\n%s", traceback.format_exc())
        _emit({"type": "battle_error", "error": traceback.format_exc()})
