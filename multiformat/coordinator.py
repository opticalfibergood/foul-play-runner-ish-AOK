#!/usr/bin/env python3
"""
foul-play-ish-aok multi-format coordinator.

Logs in to Pokemon Showdown exactly ONCE, as the bot account, and keeps
that single connection open for as long as this process runs. Waits for
a PM challenge in *any* format (not one fixed at startup), and for each
one:

  1. Works out the generation/poke-engine variant and whether the
     format needs a prebuilt team, using the exact same rules
     /usr/local/bin/foul-play and fp/format_spec.py already use.
  2. If a team is required but none exists for that exact format, or no
     poke-engine variant was built for that generation, politely
     /reject the challenge and keep waiting -- same failure that
     `start-showdown --format <that format>` would already hit today,
     just discovered per-challenge instead of at startup.
  3. Otherwise sends /utm and /accept over the one real connection,
     then hands the battle to a worker subprocess (worker.py) that has
     the right poke-engine variant on PYTHONPATH -- spawning a new one
     only if the currently-warm worker (if any) is a different
     generation, reusing it otherwise.
  4. Pumps raw PS protocol lines between the real connection and
     whichever worker is currently playing, until that worker reports
     the battle finished, then goes back to waiting for the next
     challenge -- on the SAME connection, no re-login.

This intentionally duplicates a couple of small, well-contained pieces
of logic that also exist elsewhere (accept_challenge's PM-parsing in
fp/websocket_client.py; the --pokemon-format -> poke-engine-variant
mapping in /usr/local/bin/foul-play) rather than patching foul-play
itself: the point of a *coordinator* is to decide, per challenge, what
foul-play (in a worker subprocess) should do next, which is a step
"above" anything a single foul-play process does today -- see the
README's "How patches work" section for why real modifications to
foul-play's own source stay in patches/, and why this isn't one.
"""
import argparse
import asyncio
import json
import logging
import os
import re
import sys

sys.path.insert(0, "/opt/foul-play")

from fp.constants import BattleType  # noqa: E402
from fp.format_spec import FormatSpec  # noqa: E402
from fp.teams.load_team import load_team  # noqa: E402
from fp.websocket_client import PSWebsocketClient  # noqa: E402

logging.basicConfig(
    level=logging.INFO, stream=sys.stdout, format="%(levelname)-8s %(message)s"
)
logger = logging.getLogger("coordinator")

DEFAULT_WORKER_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "worker.py"
)
# Overridable for testing the coordinator's plumbing against a stand-in
# worker without a real poke-engine build (see multiformat/fake_worker.py);
# never set by start-showdown in a real deployment.
WORKER_SCRIPT = os.environ.get("FOUL_PLAY_WORKER_SCRIPT", DEFAULT_WORKER_SCRIPT)
WORKER_PYTHON = os.environ.get("FOUL_PLAY_WORKER_PYTHON", "/opt/foul-play/venv/bin/python3")
VARIANTS_DIR = "/opt/foul-play/poke-engine-variants"

# A format doesn't need a prebuilt team if fp would never call load_team()
# for it -- mirrors fp/modes/*.py's requires_team flags exactly (see
# fp/modes/random_battle.py, standard_battle.py, battle_factory.py, bss.py)
# without importing fp.modes itself, which would also construct
# TeamDatasets()/SmogonSets()/RandomBattleTeamDatasets() singletons this
# process -- which never searches a battle -- has no use for.
REQUIRES_TEAM = {
    BattleType.RANDOM_BATTLE: False,
    BattleType.STANDARD_BATTLE: True,
    BattleType.BATTLE_FACTORY: False,
    BattleType.BSS: True,
}

_GEN_REGEX = re.compile(r"gen([1-9]0?)")


def feature_for_format(format_string: str) -> str:
    """
    Exactly mirrors /usr/local/bin/foul-play's own shell-level mapping
    (see scripts/chroot/10-foulplay.sh) so the two never disagree on
    which poke-engine variant a format string means. Kept as a literal
    port, not a shared import, because one is shell and one is Python --
    if you change one, change the other.
    """
    if "champions" in format_string:
        return "champions"
    m = _GEN_REGEX.search(format_string)
    gen = m.group(1) if m else None
    if gen in ("1", "2", "3", "4", "5", "6", "7", "8"):
        return "gen{}".format(gen)
    return "terastallization"


class Worker:
    def __init__(self, feature, process):
        self.feature = feature
        self.process = process

    async def send(self, obj):
        line = (json.dumps(obj) + "\n").encode()
        self.process.stdin.write(line)
        await self.process.stdin.drain()

    async def recv(self):
        line = await self.process.stdout.readline()
        if not line:
            return None
        return json.loads(line)

    def alive(self):
        return self.process.returncode is None

    async def shutdown(self):
        if not self.alive():
            return
        try:
            await self.send({"type": "shutdown"})
        except Exception:
            pass
        try:
            await asyncio.wait_for(self.process.wait(), timeout=5)
        except asyncio.TimeoutError:
            self.process.kill()
            await self.process.wait()


class Coordinator:
    def __init__(self, args):
        self.args = args
        self.client: PSWebsocketClient | None = None
        self.worker: Worker | None = None
        # The one and only battle-worthy state: which worker (if any) is
        # currently mid-battle and should receive every raw PS message.
        self.active_worker: Worker | None = None
        self.challenge_queue: asyncio.Queue = asyncio.Queue()
        self._reader_task: asyncio.Task | None = None

    async def connect(self):
        self.client = await PSWebsocketClient.create(
            self.args.ps_username, self.args.ps_password, self.args.websocket_uri
        )
        user_id = await self.client.login()
        logger.info("Logged in as %s", user_id)
        if self.args.room_name:
            await self.client.join_room(self.args.room_name)

    async def spawn_worker(self, feature: str) -> Worker:
        env = dict(os.environ)
        variant_dir = os.path.join(VARIANTS_DIR, feature)
        if os.path.isdir(variant_dir):
            env["PYTHONPATH"] = variant_dir + (
                os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
            )
        else:
            logger.warning(
                "no poke-engine variant for '%s'; worker will fall back to "
                "the venv's default poke-engine",
                feature,
            )
        process = await asyncio.create_subprocess_exec(
            WORKER_PYTHON,
            WORKER_SCRIPT,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            cwd="/opt/foul-play",
            env=env,
        )
        worker = Worker(feature, process)
        logger.info("spawned worker pid=%s for variant '%s'", process.pid, feature)
        return worker

    async def ensure_worker(self, feature: str) -> Worker:
        if self.worker is not None and self.worker.feature == feature and self.worker.alive():
            return self.worker
        if self.worker is not None:
            logger.info(
                "current worker is '%s', need '%s' -- replacing it",
                self.worker.feature,
                feature,
            )
            await self.worker.shutdown()
        self.worker = await self.spawn_worker(feature)
        return self.worker

    @staticmethod
    def _parse_challenge(msg, username):
        """
        Same PM shape fp.websocket_client.PSWebsocketClient.accept_challenge
        checks (|pm|from|to|/challenge format|teambuilderFormat|message|
        acceptButton|rejectButton, 9 pipe-delimited fields -- see
        server/ladders-challenges.ts's Challenges.getUpdate()), except the
        format field is captured instead of compared against a fixed value.
        Returns (challenger, requested_format) or None.
        """
        for line in msg.split("\n"):
            split_msg = line.split("|")
            if (
                len(split_msg) == 9
                and split_msg[1] == "pm"
                and split_msg[3].strip().replace("!", "").replace("\u203d", "")
                == username
                and split_msg[4].startswith("/challenge ")
                and split_msg[5]
            ):
                return split_msg[2].strip(), split_msg[5]
        return None

    async def _reader_loop(self):
        """
        The ONLY coroutine that ever calls self.client.receive_message().
        Every incoming raw PS message is routed from here -- to whichever
        worker is currently mid-battle (if any), *and* independently
        checked for a fresh challenge PM regardless of whether a battle
        is active. This single-reader design is deliberate: an earlier
        version had a second, separate task reading the same socket only
        while a battle was in progress, and briefly, right as a battle
        ended, both a leftover in-battle read and a brand new challenge
        PM could be in flight at once -- occasionally the new challenge
        got forwarded into the just-finishing worker's stdin and silently
        dropped instead of ever reaching wait_for_challenge(). Funneling
        every message through one place removes that window entirely:
        a challenge that arrives while a battle is still wrapping up
        simply sits in challenge_queue until this coordinator is ready
        for it, instead of a race deciding whether it's seen at all.
        """
        username = self.args.ps_username
        while True:
            msg = await self.client.receive_message()
            logger.debug("RAW <<< %r", msg)
            if self.active_worker is not None:
                await self.active_worker.send({"type": "recv", "msg": msg})
            challenge = self._parse_challenge(msg, username)
            if challenge is not None:
                logger.info("queued challenge: %r", challenge)
                await self.challenge_queue.put(challenge)

    async def wait_for_challenge(self):
        return await self.challenge_queue.get()

    async def handle_challenge(self, challenger: str, requested_format: str):
        format_spec = FormatSpec.from_format_string(requested_format)
        feature = feature_for_format(requested_format)
        variant_dir = os.path.join(VARIANTS_DIR, feature)

        team_packed, team_dict, team_file_name = "null", {}, "None"
        if REQUIRES_TEAM.get(format_spec.battle_type, True):
            try:
                team_name = self.args.team_name or requested_format
                team_packed, team_dict, team_file_name = load_team(team_name)
            except (ValueError, FileNotFoundError, OSError) as e:
                logger.warning(
                    "rejecting %s challenge from %s: no team available (%s)",
                    requested_format,
                    challenger,
                    e,
                )
                await self._decline(challenger, requested_format, "no team available for this format yet")
                return

        if not os.path.isdir(variant_dir):
            # /usr/local/bin/foul-play's own --pokemon-format -> variant
            # lookup (scripts/chroot/10-foulplay.sh) warns and falls back to
            # the venv's default poke-engine on a miss rather than failing --
            # a reasonable choice *there*, since that format was something
            # the person running start-showdown deliberately typed, and the
            # warning lands in the same console they're already watching.
            # Neither is true of a challenge: the challenger picked the
            # format in the Showdown UI, not on this console, and would
            # never see that warning -- they'd just get a bot that plays
            # confidently wrong mechanics for their generation with no
            # indication anything was off. A clean, visible /reject is the
            # honest failure mode here.
            logger.warning(
                "rejecting %s challenge from %s: no poke-engine variant built for '%s'",
                requested_format,
                challenger,
                feature,
            )
            await self._decline(challenger, requested_format, "this generation isn't available")
            return

        logger.info(
            "accepting %s challenge from %s (team: %s, variant: %s)",
            requested_format,
            challenger,
            team_file_name,
            feature,
        )
        worker = await self.ensure_worker(feature)

        await self.client.update_team(team_packed)
        await self.client.send_message("", ["/accept " + challenger])

        await worker.send(
            {
                "type": "start_battle",
                "format": requested_format,
                "team_dict": team_dict,
                "username": self.args.ps_username,
                "search_time_ms": self.args.search_time_ms,
                "search_parallelism": self.args.search_parallelism,
                "team_preview_search_time_ms": self.args.team_preview_search_time_ms,
                "team_preview_search_parallelism": self.args.team_preview_search_parallelism,
                "search_threads": self.args.search_threads,
                "smogon_stats": self.args.smogon_stats_format,
                "save_replay": self.args.save_replay,
            }
        )

        self.active_worker = worker
        try:
            await self._drain_until_done(worker)
        finally:
            self.active_worker = None

    async def _decline(self, challenger, requested_format, reason):
        await self.client.send_message("", ["/reject " + challenger])
        await self.client.send_message(
            "",
            ["/w {}, Sorry -- can't play {} right now ({}).".format(
                challenger, requested_format, reason
            )],
        )

    async def _drain_until_done(self, worker: Worker):
        """
        self._reader_loop() (running the whole time as a background task)
        is already forwarding every real-socket message into worker's
        stdin because self.active_worker is set; this just drains
        whatever worker sends back until it reports the battle over.
        """
        while True:
            envelope = await worker.recv()
            if envelope is None:
                logger.error("worker died mid-battle (pid=%s)", worker.process.pid)
                self.worker = None
                return
            kind = envelope.get("type")
            if kind == "send":
                await self.client.send_message(envelope["room"], envelope["lines"])
            elif kind == "battle_done":
                logger.info("battle finished, winner=%s", envelope.get("winner"))
                return
            elif kind == "battle_error":
                logger.error("worker reported a battle error: %s", envelope.get("error"))
                self.worker = None  # this worker is exiting; don't reuse it
                return
            elif kind == "worker_ready":
                pass
            elif kind == "log":
                logger.info("[worker] %s", envelope.get("message"))

    async def run(self):
        await self.connect()
        self._reader_task = asyncio.ensure_future(self._reader_loop())
        while True:
            logger.debug("waiting for next challenge...")
            challenger, requested_format = await self.wait_for_challenge()
            logger.debug("dequeued challenge from %s: %s", challenger, requested_format)
            try:
                await self.handle_challenge(challenger, requested_format)
            except Exception:
                logger.exception(
                    "unhandled error while handling a %s challenge from %s",
                    requested_format,
                    challenger,
                )
            logger.debug("handle_challenge returned, active_worker=%r", self.active_worker)


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--websocket-uri", required=True)
    p.add_argument("--ps-username", required=True)
    p.add_argument("--ps-password", default=None)
    p.add_argument("--room-name", default=None)
    p.add_argument("--team-name", default=None, help="Overrides the per-format team lookup; normally left unset so each format looks up fp/teams/teams/<format>")
    p.add_argument("--search-time-ms", type=int, default=100)
    p.add_argument("--search-parallelism", type=int, default=1)
    p.add_argument("--team-preview-search-time-ms", type=int, default=None)
    p.add_argument("--team-preview-search-parallelism", type=int, default=None)
    p.add_argument("--search-threads", type=int, default=1)
    p.add_argument("--smogon-stats-format", default=None)
    p.add_argument("--save-replay", default="never", choices=["always", "never", "on_loss", "on_win"])
    p.add_argument("--debug", action="store_true", help="verbose per-message tracing, for troubleshooting")
    return p.parse_args()


async def _main():
    args = parse_args()
    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)
    coordinator = Coordinator(args)
    await coordinator.run()


if __name__ == "__main__":
    asyncio.run(_main())
