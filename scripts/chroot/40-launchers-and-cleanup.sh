#!/bin/sh
# Step 40: on-device launcher, MOTD, and final cleanup of build-only
# tooling (this is the step that actually removes rust/cargo/node build
# deps/php/etc -- everything up to here still needs them). POSIX sh only.
set -eu

SHOWDOWN_PORT="${SHOWDOWN_PORT:-8000}"

echo "==> Installing /usr/local/bin/start-showdown"
cat > /usr/local/bin/start-showdown <<EOS
#!/bin/sh
# Starts the bundled, offline pokemon-showdown server and (unless
# --no-bot is given) the foul-play bot, and stops both on Ctrl-C.
#
# The server auto-names any browser that connects to it "human" (see
# config/config.js's customhttpresponse hook) and needs no login server
# or internet access (noguestsecurity=true) -- open the ish-AOK Browser
# tool to http://localhost:${SHOWDOWN_PORT} once this prints
# "Test your server at", challenge "bot", and go.
set -eu

PORT="${SHOWDOWN_PORT}"
BOT_MODE="accept_challenge"
FORMAT="gen9randombattle"
START_BOT=1

while [ \$# -gt 0 ]; do
	case "\$1" in
		--port) PORT="\$2"; shift 2 ;;
		--bot-mode) BOT_MODE="\$2"; shift 2 ;;
		--format) FORMAT="\$2"; shift 2 ;;
		--no-bot) START_BOT=0; shift ;;
		--help)
			echo "usage: start-showdown [--port N] [--bot-mode MODE] [--format FORMAT] [--no-bot]"
			echo "  --port N        showdown server port (default: ${SHOWDOWN_PORT})"
			echo "  --bot-mode MODE foul-play --bot-mode (default: accept_challenge)"
			echo "  --format FORMAT foul-play --pokemon-format (default: gen9randombattle)"
			echo "  --no-bot        just run the server, don't start foul-play"
			exit 0
			;;
		*) echo "unknown argument: \$1" >&2; exit 1 ;;
	esac
done

SERVER_PID=""
BOT_PID=""
CLEANED_UP=0
cleanup() {
	[ "\$CLEANED_UP" -eq 1 ] && return
	CLEANED_UP=1
	echo ""
	echo "Stopping..."
	[ -n "\$BOT_PID" ] && kill "\$BOT_PID" 2>/dev/null || true
	[ -n "\$SERVER_PID" ] && kill "\$SERVER_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

echo "Starting pokemon-showdown on port \$PORT..."
cd /opt/pokemon-showdown
node pokemon-showdown start --skip-build "\$PORT" &
SERVER_PID=\$!

# Wait for the port to actually accept TCP connections before ever
# launching foul-play. A bare TCP connect is a much cheaper/more reliable
# readiness probe than an HTTP GET here: unlike wget, it never touches
# customhttpresponse or any sockjs/HTTP request-handling code, so it can't
# be fooled by that -- it only confirms .listen() has actually completed.
# (Loading the sim/Dex data before pokemon-showdown ever calls .listen()
# routinely takes longer than a fixed 3s sleep on real ish-AOK hardware,
# which is what made the old sleep-3-then-kill-0 check unreliable: it only
# proved the node process hadn't crashed, not that it was accepting
# connections yet, so foul-play's first launch attempt would race and lose.)
echo "Waiting for pokemon-showdown to start listening on port \$PORT..."
i=0
until nc -z 127.0.0.1 "\$PORT" 2>/dev/null; do
	kill -0 "\$SERVER_PID" 2>/dev/null || { echo "error: server process died immediately" >&2; exit 1; }
	i=\$((i + 1))
	if [ "\$i" -ge 60 ]; then
		echo "error: server did not start listening within 60s" >&2
		exit 1
	fi
	sleep 1
done
echo "Server starting in the background: http://localhost:\$PORT"

# websockets.connect()'s default open_timeout is 10s (confirmed in the
# vendored library's asyncio/client.py) -- foul-play's first connection
# attempt races that clock against pokemon-showdown's synchronous startup
# work (chatroom restore, Dex loading, etc.), which can still be running
# well after the port above starts accepting TCP connections. A
# .listen()'d socket takes the handshake into the kernel backlog right
# away even if node hasn't gotten around to answering it yet, so the
# process can look "alive" for a while before it actually connects, or
# before it times out and dies.
CONNECT_CHECK_DELAY=15

launch_bot() {
	FOUL_PLAY_NOGUEST_LOGIN=1 foul-play \\
		--websocket-uri "ws://localhost:\$PORT/showdown/websocket" \\
		--ps-username bot \\
		--bot-mode "\$BOT_MODE" \\
		--pokemon-format "\$FORMAT" &
	BOT_PID=\$!
}

if [ "\$START_BOT" -eq 1 ]; then
	echo "Waiting for foul-play to connect (--bot-mode \$BOT_MODE, --pokemon-format \$FORMAT)..."
	# Earlier versions of this script polled the server with wget before
	# ever starting the bot. That was checking the wrong thing: on real
	# iSH-AOK hardware a plain HTTP GET can behave very differently from
	# an actual WebSocket connection attempt (customhttpresponse's
	# synchronous file read alone was enough to make wget an unreliable
	# proxy -- confirmed directly: wget kept failing for 200s+ of real
	# wall-clock time while the browser successfully connected through
	# the same server in the meantime). foul-play connecting is the only
	# thing that actually matters here, so let IT be the readiness check.
	#
	# run.py re-raises any exception after logging it (confirmed directly
	# in foul-play's own source) -- including a failed initial
	# websockets.connect() -- so the process exits promptly on a failed
	# connection attempt and keeps running once genuinely connected. That
	# gives a clean, real signal to retry on: launch it, and if it's
	# still alive a bit later, it connected.
	#
	# NOTE: CONNECT_CHECK_DELAY is comfortably past the library's 10s
	# open_timeout, but a single point-in-time check like this is
	# inherently racy no matter what number is picked here -- the real
	# protection against this timeout (and any later crash) is the
	# supervision loop below, which keeps watching for the rest of the
	# session instead of checking once and walking away.
	START_TIME=\$(date +%s)
	BUDGET=600
	LAST_PROGRESS=0
	while true; do
		launch_bot
		sleep "\$CONNECT_CHECK_DELAY"
		if kill -0 "\$BOT_PID" 2>/dev/null; then
			echo "foul-play connected."
			break
		fi
		wait "\$BOT_PID" 2>/dev/null || true
		kill -0 "\$SERVER_PID" 2>/dev/null || { echo "error: server process died" >&2; exit 1; }
		NOW=\$(date +%s)
		ELAPSED=\$((NOW - START_TIME))
		if [ "\$ELAPSED" -ge "\$BUDGET" ]; then
			echo "error: foul-play could not connect after \${BUDGET}s" >&2
			exit 1
		fi
		if [ "\$((ELAPSED - LAST_PROGRESS))" -ge 10 ]; then
			LAST_PROGRESS=\$ELAPSED
			echo "  ...still trying (\${ELAPSED}s)"
		fi
		sleep 2
	done
fi

echo ""
echo "Open the Browser tool in ish-AOK and go to: http://localhost:\$PORT"
echo "You'll be auto-named 'human'. Challenge 'bot' to a \$FORMAT battle."
echo "Ctrl-C here stops everything."

if [ "\$START_BOT" -eq 1 ]; then
	# A plain \`wait\` here would block until the first background job exits
	# and then fall straight through to cleanup/exit -- silently ending the
	# session if foul-play dies later (this same handshake-timeout race can
	# in principle strike again after we've already declared victory once,
	# and a real crash mid-battle is possible too). Supervise both
	# processes for the rest of the run instead: the server dying is
	# fatal, and foul-play crashing/disconnecting gets auto-restarted so
	# the bot doesn't just sit there OFFLINE.
	#
	# foul-play's own run_foul_play() loops until it has played
	# --run-count battles (default 1, confirmed in fp/config.py), then
	# closes the websocket and returns -- run.py has no exception to
	# reraise, so the process exits 0. That is a *clean, intentional*
	# exit, not a crash, and must not be treated like one: restarting on
	# it (as this loop used to do, unconditionally) meant the bot never
	# actually stopped after a battle ended, no matter --run-count.
	# Only a genuine nonzero exit is a crash worth auto-restarting from.
	while true; do
		[ "\$CLEANED_UP" -eq 1 ] && break
		kill -0 "\$SERVER_PID" 2>/dev/null || { echo "error: server process died" >&2; exit 1; }
		if [ -n "\$BOT_PID" ] && ! kill -0 "\$BOT_PID" 2>/dev/null; then
			BOT_EXIT=0
			wait "\$BOT_PID" 2>/dev/null || BOT_EXIT=\$?
			[ "\$CLEANED_UP" -eq 1 ] && break
			if [ "\$BOT_EXIT" -eq 0 ]; then
				echo "foul-play finished its battle(s) and exited cleanly -- not restarting."
				echo "Server is still running at http://localhost:\$PORT; Ctrl-C to stop."
				BOT_PID=""
			else
				echo "foul-play disconnected/crashed (exit \$BOT_EXIT) -- restarting..."
				launch_bot
			fi
		fi
		sleep 3
	done
else
	wait
fi
EOS
chmod +x /usr/local/bin/start-showdown

echo "==> Writing consolidated BUILD_INFO.txt"
cat > /BUILD_INFO.txt <<EOF
=== foul-play ===
$(cat /opt/foul-play/BUILD_INFO.txt)

=== pokemon-showdown (server) ===
$(cat /opt/pokemon-showdown/BUILD_INFO.txt)

=== pokemon-showdown-client (offline static client + mirrored sprites) ===
$(cat /opt/pokemon-showdown/server/static/BUILD_INFO.txt)
$(cat /opt/pokemon-showdown/server/static/SPRITE_MIRROR_INFO.txt)

alpine version: $(cat /etc/alpine-release)
node version: $(node --version)
python version: $(python3 --version 2>&1)
built (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cat /BUILD_INFO.txt

echo "==> Writing MOTD"
cat > /etc/motd <<EOF
foul-play + an offline pokemon-showdown server are pre-installed here.
See /BUILD_INFO.txt for exact versions.

Quickest start: run \`start-showdown\`, then open the ish-AOK Browser tool
to http://localhost:${SHOWDOWN_PORT} -- you'll be auto-named "human"; the
bot is named "bot" and will auto-accept your challenge.
Run \`start-showdown --help\` for options; Ctrl-C stops both processes.

foul-play alone (e.g. against the real ladder, over the internet) still
works unchanged: \`foul-play --help\`.
EOF

echo "==> Removing build-only packages (this is the point of no return for"
echo "    rebuilding anything on-device -- everything past here is runtime-only)"
apk del rust cargo build-base musl-dev linux-headers python3-dev \
        openssl-dev libffi-dev git patch php npm
rm -rf /var/cache/apk/* /root/.cargo /root/.cache /root/.npm

echo "==> Writing default resolv.conf (the one build-rootfs.sh borrowed was the CI host's)"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf

echo "==> Final size report"
du -sh /opt/foul-play /opt/pokemon-showdown 2>/dev/null || true

echo "==> 40-launchers-and-cleanup.sh finished"
