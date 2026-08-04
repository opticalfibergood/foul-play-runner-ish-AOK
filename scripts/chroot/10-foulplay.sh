#!/bin/sh
# Step 10: build foul-play. POSIX sh only.
set -eu

POKE_ENGINE_GEN="${POKE_ENGINE_GEN:-}"
FOUL_PLAY_REF="${FOUL_PLAY_REF:-main}"
PATCH_DIR="${PATCH_DIR:-/build-input/patches}"

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

echo "==> Applying foulplay-noguest-login.patch"
# Modifies fp/websocket_client.py's login() to skip the login-server HTTP
# round trip when FOUL_PLAY_NOGUEST_LOGIN=1 is set at runtime (used by the
# start-showdown launcher against the bundled offline server, which is
# started with noguestsecurity=true -- see
# patches/showdown-server-config.patch). Every other login path (a real
# password, or a guest login against the real production server) is
# unmodified; this is opt-in per-process, not a behavior change to
# foul-play in general.
#
# git apply fails loudly (not silently) if foul-play's upstream file has
# drifted from what this patch expects -- that's deliberate: better to
# stop the build than silently ship a broken or half-applied patch.
if ! git apply --check "$PATCH_DIR/foulplay-noguest-login.patch" 2>/tmp/patch-check.err; then
    echo "error: foulplay-noguest-login.patch no longer applies cleanly to foul-play@${FOUL_PLAY_COMMIT}" >&2
    cat /tmp/patch-check.err >&2
    echo "foul-play's fp/websocket_client.py has likely changed upstream; the patch needs updating." >&2
    exit 1
fi
git apply "$PATCH_DIR/foulplay-noguest-login.patch"

echo "==> Verifying the patched file (syntax + structure)"
python3 -m py_compile fp/websocket_client.py
python3 - <<'PY'
import ast
tree = ast.parse(open("fp/websocket_client.py").read())
funcs = [n.name for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef)]
assert "login" in funcs, "login() is no longer an async function after patching -- aborting"
print("py_compile + structure check OK; async functions:", funcs)
PY

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
import fp.websocket_client  # confirms the patched module still imports
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
patched: fp/websocket_client.py (patches/foulplay-noguest-login.patch)
EOF
cat /opt/foul-play/BUILD_INFO.txt

echo "==> 10-foulplay.sh finished"
