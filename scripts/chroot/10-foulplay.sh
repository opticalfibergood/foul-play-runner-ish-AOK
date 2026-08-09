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
# git apply resolves patch paths relative to the repo root, not CWD --
# this only works because we're sitting at /opt/foul-play (the repo root)
# and the patch's path is fp/websocket_client.py, not a bare filename
# applied from within fp/. See showdown-client-testclient.patch's
# application in 30-showdown-client.sh for what goes wrong otherwise.
if ! git apply --check "$PATCH_DIR/foulplay-noguest-login.patch" 2>/tmp/patch-check.err; then
    echo "error: foulplay-noguest-login.patch no longer applies cleanly to foul-play@${FOUL_PLAY_COMMIT}" >&2
    cat /tmp/patch-check.err >&2
    echo "foul-play's fp/websocket_client.py has likely changed upstream; the patch needs updating." >&2
    exit 1
fi
git apply "$PATCH_DIR/foulplay-noguest-login.patch"

echo "==> Applying foulplay-disable-ping-keepalive.patch"
# Modifies fp/websocket_client.py's create() to open the websocket with
# ping_interval=None when FOUL_PLAY_NOGUEST_LOGIN=1 (same opt-in env var
# as the patch above, set only by start-showdown against the bundled
# offline server). Without this, the default 20s ping/pong keepalive in
# the websockets library can get closed out from under login() -- sent
# 1011 "keepalive ping timeout" -- while pokemon-showdown is still doing
# synchronous startup work (chatroom restore, loading /formats, etc.)
# after its TCP listener is already accepting connections. start-showdown's
# supervision loop was masking this by silently restarting foul-play on
# the first launch attempt; this patch removes the race itself instead of
# just retrying past it. Guest/online logins against the real ladder are
# unaffected. Depends on foulplay-noguest-login.patch being applied first
# (that patch adds the `import os` this one relies on) -- hence applying
# it second, here.
if ! git apply --check "$PATCH_DIR/foulplay-disable-ping-keepalive.patch" 2>/tmp/patch-check.err; then
    echo "error: foulplay-disable-ping-keepalive.patch no longer applies cleanly to foul-play@${FOUL_PLAY_COMMIT}" >&2
    cat /tmp/patch-check.err >&2
    echo "foul-play's fp/websocket_client.py has likely changed upstream; the patch needs updating." >&2
    exit 1
fi
git apply "$PATCH_DIR/foulplay-disable-ping-keepalive.patch"

echo "==> Verifying the patched file (syntax + structure)"
python3 -m py_compile fp/websocket_client.py
python3 - <<'PY'
import ast
tree = ast.parse(open("fp/websocket_client.py").read())
funcs = [n.name for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef)]
assert "login" in funcs, "login() is no longer an async function after patching -- aborting"
assert "create" in funcs, "create() is no longer an async function after patching -- aborting"
print("py_compile + structure check OK; async functions:", funcs)
PY

# NOTE: this only changes which single feature requirements.txt pins for
# the venv's own default poke-engine install below -- it no longer limits
# which generations actually work at runtime, since every generation
# (plus Champions) also gets built separately as its own variant further
# down and selected per-battle by the /usr/local/bin/foul-play launcher.
# Left in place because it's still a real knob: it picks which variant
# the launcher falls back to for a --pokemon-format it can't parse, and
# which one a direct `venv/bin/python3 run.py` invocation (bypassing the
# launcher entirely) would get.
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

# ---------------------------------------------------------------------------
# Build every poke-engine generation/format variant, not just the one
# requirements.txt (or POKE_ENGINE_GEN above) happens to pin.
#
# poke-engine (the Rust search engine foul-play calls into -- a separate
# project, not foul-play's own source) picks its generation at COMPILE
# time, not runtime: confirmed directly against a real poke-engine sdist
# (pypi.org, poke-engine==0.0.48) -- Cargo.toml's [features] table has
# gen1..gen9/champions/terastallization (terastallization implying gen9),
# src/lib.rs picks src/gen1|gen2|gen3's own module for those three
# generations and falls back to one shared "genx" module (#[cfg(...)]-
# gated per feature throughout) for everything else, and lib.rs's own
# assert_unique_feature!() macro is a compile_error! if more than one of
# gen2..gen9/champions is enabled at once -- so a single `pip install
# poke-engine --config-settings=...--features poke-engine/X` can only
# ever produce a poke_engine.so that plays generation X. That's exactly
# why upstream foul-play's own README has a "Re-Installing the Engine"
# section on rebuilding poke-engine per generation you want to play, and
# why requirements.txt as shipped pins exactly one feature
# (terastallization, i.e. gen9) -- so a build of this image using only
# that install, as before, could only ever actually complete a gen9 (or
# gen9champions, since that needs the separate "champions" feature this
# one build doesn't have either) battle. start-showdown's --format
# already passes any format straight through with no restriction (see
# README), so --format gen3ou would load a foul-play that thinks it's
# playing gen3 talking to a poke-engine binary that can only compute gen9
# mechanics -- wrong results, not a crash, since poke-engine has no way
# to know it was asked for the wrong generation.
#
# Fixed here without touching a single line of foul-play's own source
# (nothing under /opt/foul-play/fp is ever modified): poke-engine is a
# self-contained package -- a pure-Python __init__.py wrapping one
# compiled extension module, confirmed against its own
# pyproject.toml/python/poke_engine source, no other runtime deps -- so
# it installs cleanly with `pip install --target` into an arbitrary
# directory outside the venv's own site-packages, once per feature. The
# /usr/local/bin/foul-play launcher below (also entirely this build's own
# file, not foul-play's) then prepends the right one of these
# directories onto PYTHONPATH -- shadowing whatever the venv's own
# site-packages has -- based on parsing --pokemon-format the same way
# fp/format_spec.py's FormatSpec.from_format_string does (gen([1-9]0?)
# regex, "champions" substring), so the two always agree on which
# generation a format string means.
#
# gen1/gen2/gen3 are their own dedicated modules; gen4-gen8, gen9 (built
# as "terastallization", which Cargo.toml declares implies gen9), and
# champions all share poke-engine's "genx" module gated by these same
# feature names -- this is the exhaustive list of feature names that
# actually correspond to a real, playable generation/format in
# poke-engine's own Cargo.toml (excluding unrelated build knobs like
# remove_low_chance_instructions, and "bss" which only ever narrows an
# already-selected champions build further, per Cargo.toml's own
# `bss = ["champions"]`).
echo "==> Building poke-engine variants for every generation + Champions"
POKE_ENGINE_SPEC="$(awk '$1 ~ /^poke-engine==/{print $1; exit}' requirements.txt)"
if [ -z "$POKE_ENGINE_SPEC" ]; then
    echo "error: could not find a 'poke-engine==X' pin in requirements.txt to build variants from" >&2
    echo "foul-play's requirements.txt has likely changed how it pins poke-engine; this needs updating." >&2
    exit 1
fi
echo "poke-engine version pin used for every variant: $POKE_ENGINE_SPEC"

POKE_ENGINE_VARIANTS_DIR=/opt/foul-play/poke-engine-variants
mkdir -p "$POKE_ENGINE_VARIANTS_DIR"
for feature in gen1 gen2 gen3 gen4 gen5 gen6 gen7 gen8 terastallization champions; do
    echo "==> Building poke-engine variant: $feature"
    variant_dir="$POKE_ENGINE_VARIANTS_DIR/$feature"
    rm -rf "$variant_dir"
    mkdir -p "$variant_dir"
    /opt/foul-play/venv/bin/pip install -v --no-deps --no-cache-dir \
        --target "$variant_dir" \
        "$POKE_ENGINE_SPEC" \
        --config-settings="build-args=--features poke-engine/${feature} --no-default-features"

    echo "==> Smoke-testing poke-engine variant: $feature"
    PYTHONPATH="$variant_dir" /opt/foul-play/venv/bin/python3 - "$feature" <<'PY'
import sys
variant = sys.argv[1]
import poke_engine
print(f"poke_engine ({variant}) OK:", poke_engine.__file__)
PY
done
echo "==> All poke-engine variants built: $(ls "$POKE_ENGINE_VARIANTS_DIR")"

echo "==> Installing /usr/local/bin/foul-play launcher"
cat > /usr/local/bin/foul-play <<'EOS'
#!/bin/sh
# This wrapper is entirely this build's own file (not part of foul-play's
# source -- nothing under /opt/foul-play/fp is touched). Before exec'ing
# foul-play, it works out which poke-engine variant (see 10-foulplay.sh)
# matches whatever --pokemon-format was actually asked for and puts that
# variant's directory first on PYTHONPATH, shadowing the venv's own
# site-packages copy -- mirroring, in shell, the exact same
# gen([1-9]0?)/"champions" in format_string parse foul-play's own
# fp/format_spec.py FormatSpec.from_format_string() does in Python, so
# the two always agree on which generation a format string means. If
# --pokemon-format is missing/unparseable, or the matching variant
# directory doesn't exist for some reason, this deliberately falls back
# to whatever poke-engine the venv has installed by default (unmodified
# behavior) rather than failing outright.
set -eu

FORMAT=""
prev=""
for arg in "$@"; do
	case "$prev" in
		--pokemon-format) FORMAT="$arg" ;;
	esac
	case "$arg" in
		--pokemon-format=*) FORMAT="${arg#--pokemon-format=}" ;;
	esac
	prev="$arg"
done

VARIANTS_DIR=/opt/foul-play/poke-engine-variants
if [ -n "$FORMAT" ] && [ -d "$VARIANTS_DIR" ]; then
	case "$FORMAT" in
		*champions*) FEATURE=champions ;;
		*)
			GEN="$(printf '%s' "$FORMAT" | sed -n 's/.*gen\([1-9]0\{0,1\}\).*/\1/p')"
			case "$GEN" in
				1|2|3|4|5|6|7|8) FEATURE="gen$GEN" ;;
				*) FEATURE="terastallization" ;;
			esac
			;;
	esac
	if [ -d "$VARIANTS_DIR/$FEATURE" ]; then
		PYTHONPATH="$VARIANTS_DIR/$FEATURE${PYTHONPATH:+:$PYTHONPATH}"
		export PYTHONPATH
	else
		echo "warning: no poke-engine variant for '$FEATURE' (from --pokemon-format '$FORMAT'); falling back to the venv's default poke-engine" >&2
	fi
fi

# Debug/test-only escape hatch (never set by start-showdown or a normal
# invocation): print the variant this run would have selected and exit,
# instead of actually starting foul-play. Lets verify-rootfs.sh check the
# selection logic itself against a real built image without needing a
# live server/websocket to hand.
if [ "${FOUL_PLAY_VARIANT_DEBUG:-}" = "1" ]; then
	echo "${FEATURE:-<default>}"
	exit 0
fi

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
poke-engine gen override (venv default/fallback only): ${POKE_ENGINE_GEN:-<none, used requirements.txt default>}
poke-engine variants built (selected per-battle by /usr/local/bin/foul-play): $(ls "$POKE_ENGINE_VARIANTS_DIR" | tr '\n' ' ')
patched: fp/websocket_client.py (patches/foulplay-noguest-login.patch)
EOF
cat /opt/foul-play/BUILD_INFO.txt

echo "==> 10-foulplay.sh finished"
