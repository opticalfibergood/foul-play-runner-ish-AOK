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

echo "Waiting for it to come up..."
# The server's own "Worker N now listening" line prints right after
# calling .listen(), not after the async 'listening' event actually
# fires -- so it isn't necessarily ready the moment that's printed.
#
# On real iSH-AOK hardware, individual requests can genuinely take much
# longer than on a normal machine to actually complete (not fail outright
# -- just slow, likely from synchronous file reads going through iSH's
# fakefs layer under JIT-emulated syscalls) before the server settles.
# A short per-attempt wget timeout previously caused *every single
# attempt* to fail for this reason alone, regardless of how many times
# it retried -- confirmed on a real device where the browser eventually
# connected (after several manual reloads) while this loop kept failing
# the whole time on a much shorter per-attempt budget. So: a generous
# per-attempt timeout, and the overall budget is tracked against real
# wall-clock time rather than a fixed attempt count, since one slow
# attempt can itself now take much longer than a fixed polling interval
# would assume.
START_TIME=\$(date +%s)
BUDGET=600
LAST_PROGRESS=0
while true; do
	if wget -q -T 20 -O /dev/null "http://localhost:\$PORT/" 2>/dev/null; then
		break
	fi
	kill -0 "\$SERVER_PID" 2>/dev/null || { echo "error: server process died" >&2; exit 1; }
	NOW=\$(date +%s)
	ELAPSED=\$((NOW - START_TIME))
	if [ "\$ELAPSED" -ge "\$BUDGET" ]; then
		echo "error: server did not come up after \${BUDGET}s" >&2
		exit 1
	fi
	if [ "\$((ELAPSED - LAST_PROGRESS))" -ge 10 ]; then
		LAST_PROGRESS=\$ELAPSED
		echo "  ...still waiting (\${ELAPSED}s)"
	fi
	sleep 1
done
echo "Server is up: http://localhost:\$PORT"

if [ "\$START_BOT" -eq 1 ]; then
	echo "Starting foul-play (--bot-mode \$BOT_MODE, --pokemon-format \$FORMAT)..."
	FOUL_PLAY_NOGUEST_LOGIN=1 foul-play \\
		--websocket-uri "ws://localhost:\$PORT/showdown/websocket" \\
		--ps-username bot \\
		--bot-mode "\$BOT_MODE" \\
		--pokemon-format "\$FORMAT" &
	BOT_PID=\$!
fi

echo ""
echo "Open the Browser tool in ish-AOK and go to: http://localhost:\$PORT"
echo "You'll be auto-named 'human'. Challenge 'bot' to a \$FORMAT battle."
echo "Ctrl-C here stops everything."
wait
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
