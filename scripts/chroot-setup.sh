#!/bin/sh
# Runs *inside* the aarch64 Alpine chroot (invoked by build-rootfs.sh via
# plain `chroot`, since the runner is native aarch64). POSIX sh only --
# Alpine's /bin/sh is busybox ash.
set -eu

POKE_ENGINE_GEN="${POKE_ENGINE_GEN:-}"
FOUL_PLAY_REF="${FOUL_PLAY_REF:-main}"

echo "==> apk update"
apk update

echo "==> Installing build + runtime packages"
apk add --no-cache \
    python3 python3-dev py3-pip \
    rust cargo \
    build-base musl-dev linux-headers \
    openssl-dev libffi-dev \
    git ca-certificates

echo "==> Checking python3 version (foul-play needs 3.11+)"
python3 - <<'PY'
import sys
v = sys.version_info
print("python3:", sys.version)
assert (v.major, v.minor) >= (3, 11), (
    f"Alpine shipped python3 {v.major}.{v.minor}, but foul-play requires 3.11+. "
    "This Alpine release is too old for this build."
)
PY

echo "==> Cloning foul-play (ref: ${FOUL_PLAY_REF})"
git clone --depth 1 --branch "$FOUL_PLAY_REF" https://github.com/pmariglia/foul-play.git /opt/foul-play
cd /opt/foul-play
FOUL_PLAY_COMMIT="$(git rev-parse HEAD)"

if [ -n "$POKE_ENGINE_GEN" ]; then
    echo "==> Overriding poke-engine feature -> poke-engine/${POKE_ENGINE_GEN}"
    sed -i "s/poke-engine\/[^ \"]*/poke-engine\/${POKE_ENGINE_GEN}/" requirements.txt
fi
echo "requirements.txt poke-engine line: $(grep poke-engine requirements.txt)"

echo "==> Creating venv and installing requirements (compiles poke-engine)"
python3 -m venv /opt/foul-play/venv
# pip 24.2+ is required for the --config-settings flag poke-engine relies on
# (see foul-play's own Dockerfile / README "Re-Installing the Engine").
/opt/foul-play/venv/bin/pip install --upgrade "pip==24.2"
/opt/foul-play/venv/bin/pip install -v -r requirements.txt

echo "==> Smoke-testing the installed package"
/opt/foul-play/venv/bin/python3 - <<'PY'
import poke_engine
import fp.main  # noqa: F401 -- just confirms foul-play's package imports cleanly
print("poke_engine OK:", poke_engine.__file__)
PY

echo "==> Installing /usr/local/bin/foul-play launcher"
cat > /usr/local/bin/foul-play <<'EOS'
#!/bin/sh
cd /opt/foul-play
exec /opt/foul-play/venv/bin/python3 /opt/foul-play/run.py "$@"
EOS
chmod +x /usr/local/bin/foul-play

echo "==> Trimming dev-only files"
POKE_ENGINE_VERSION="$(/opt/foul-play/venv/bin/pip show poke-engine 2>/dev/null | awk -F': ' '/^Version/{print $2}')"
rm -rf /opt/foul-play/tests /opt/foul-play/.git /opt/foul-play/.github \
       /opt/foul-play/.dockerignore /opt/foul-play/Dockerfile \
       /opt/foul-play/requirements-dev.txt

cat > /opt/foul-play/BUILD_INFO.txt <<EOF
foul-play ref: $FOUL_PLAY_REF
foul-play commit: $FOUL_PLAY_COMMIT
poke-engine version: $POKE_ENGINE_VERSION
poke-engine gen override: ${POKE_ENGINE_GEN:-<none, used requirements.txt default>}
alpine version: $(cat /etc/alpine-release)
python version: $(python3 --version 2>&1)
built (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cat /opt/foul-play/BUILD_INFO.txt

echo "==> Removing build-only packages to shrink the image"
apk del rust cargo build-base musl-dev linux-headers python3-dev \
        openssl-dev libffi-dev git
rm -rf /var/cache/apk/* /root/.cargo /root/.cache

echo "==> Writing default resolv.conf (the one we borrowed was the CI host's)"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf

echo "==> Writing a short MOTD"
cat > /etc/motd <<'EOF'
This Alpine image ships with foul-play pre-installed and pre-built.
See /opt/foul-play/BUILD_INFO.txt for exact versions.

Run it with:
  foul-play --websocket-uri wss://sim3.psim.us/showdown/websocket \
            --ps-username 'your username' \
            --ps-password 'your password' \
            --bot-mode search_ladder \
            --pokemon-format gen9randombattle

Run `foul-play --help` for all options.
EOF

echo "==> chroot-setup.sh finished"
