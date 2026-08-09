#!/bin/sh
# Step 30: build the pokemon-showdown client, make it offline-capable, and
# merge it into the server built in step 20. POSIX sh only.
set -eu

CLIENT_REF="${CLIENT_REF:-master}"
PATCH_DIR="${PATCH_DIR:-/build-input/patches}"
SCRIPT_DIR="${SCRIPT_DIR:-/build-input/scripts}"
SRC_READY_MARKER=/tmp/.pokemon-showdown-src-ready
STEP20_CLONE_READY_MARKER=/tmp/.step20-clone-ready

echo "==> Cloning pokemon-showdown-client (ref: ${CLIENT_REF})"
git clone --depth 1 --branch "$CLIENT_REF" https://github.com/smogon/pokemon-showdown-client.git /opt/pokemon-showdown-client
cd /opt/pokemon-showdown-client
CLIENT_COMMIT="$(git rev-parse HEAD)"

echo "==> npm install (full -- devDependencies needed to build)"
npm install --no-audit --no-fund

echo "==> Waiting for 15-showdown-src.sh's shared clone+install"
while [ ! -f "$SRC_READY_MARKER" ]; do sleep 1; done

echo "==> Seeding caches/pokemon-showdown from the shared checkout (see"
echo "    15-showdown-src.sh -- build-tools/build-indexes clones its own"
echo "    copy here ONLY if this directory doesn't already exist yet, and"
echo "    otherwise just does a fast no-op 'git pull' + 'npm run build' on"
echo "    whatever it finds -- confirmed by reading that file directly."
echo "    Pre-seeding it here turns that ~2-minute clone+install into a"
echo "    local copy)"
mkdir -p caches
cp -a /opt/pokemon-showdown-src caches/pokemon-showdown

echo "==> node build full (data files + TS compile; build-tools/build-indexes"
echo "    also runs 'npm run build' on the seeded copy above to extract dex"
echo "    data -- that copy is deleted below once this step is done)"
# node build full's *own* exit code isn't trustworthy as a pass/fail signal
# on its own: a late, unrelated step (regenerating index.php files for the
# *other* pokemonshowdown.com properties we don't even use) can exit
# non-zero over a purely cosmetic cachebusting warning for a file
# (data/commands.js) that doesn't get generated in this build at all and
# gracefully falls back to a remote fetch at runtime via the same
# onerror="loadRemoteData(...)" pattern every other data script already
# uses. Reproduced and confirmed directly. So: don't hard-fail on exit
# code here -- instead verify the specific files we actually need.
node build full || echo "(node build full exited non-zero -- checking for the files we actually need below)"

echo "==> Verifying the essential build output exists"
missing=0
for f in data/pokedex.js data/moves.js data/items.js data/abilities.js \
         data/typechart.js data/aliases.js data/search-index.js \
         data/teambuilder-tables.js data/graphics.js data/text.js \
         js/client-core.js js/panel-popups.js testclient-new.html \
         favicon-256.png style/client2.css style/sim-types.css; do
    if [ ! -s "play.pokemonshowdown.com/$f" ]; then
        echo "  MISSING: play.pokemonshowdown.com/$f" >&2
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo "error: one or more essential client build outputs are missing -- aborting" >&2
    exit 1
fi
echo "  all essential files present"

echo "==> Applying showdown-client-testclient.patch"
# Points the client's offline-fallback Config at our own local server
# (this is what both sprite/resource loading AND the websocket connection
# target read -- see the patch file's comments for why this has to be a
# static, load-time fix rather than a runtime script injection), and
# switches the two hardcoded-with-no-fallback pokedex-mini(.bw).js script
# tags to local relative paths.
#
# Applied from the repo root (/opt/pokemon-showdown-client), NOT from
# inside play.pokemonshowdown.com/ -- git apply resolves a patch's paths
# relative to the top of the current git working tree, not the current
# working directory, so running it from within the subdirectory silently
# no-ops ("Skipped patch") instead of erroring. Confirmed by reproducing
# it directly: git apply reported success either way, but only applying
# from the repo root with the full play.pokemonshowdown.com/... path
# actually changed the file. Caught by scripts/verify-testclient-html.js
# failing in CI, not by git apply's own exit code, which is exactly why
# that verification step does a real semantic check instead of trusting
# "git apply didn't error" as proof of anything.
if ! git apply --check "$PATCH_DIR/showdown-client-testclient.patch" 2>/tmp/patch-check.err; then
    echo "error: showdown-client-testclient.patch no longer applies cleanly to pokemon-showdown-client@${CLIENT_COMMIT}" >&2
    cat /tmp/patch-check.err >&2
    echo "testclient-new.html has likely changed upstream; the patch needs updating." >&2
    exit 1
fi
git apply "$PATCH_DIR/showdown-client-testclient.patch"

echo "==> Verifying the patched testclient-new.html (extracted-JS syntax + semantic check)"
node "$SCRIPT_DIR/verify-testclient-html.js" play.pokemonshowdown.com/testclient-new.html

echo "==> Applying showdown-client-css-fixes.patch"
# style/client2.css and style/sim-types.css (the two stylesheets
# testclient-new.html actually loads) hardcode several `url(...)`s as
# *absolute* https://play.pokemonshowdown.com/... addresses instead of
# relative ones -- the Meloetta AFD icons, the avatar-picker thumbnail
# sheet, and every type icon rendered through the newer `typeicon`
# component. Unlike everything mirror-sprites.js fetches, these never even
# attempt to load from the local server in the first place, no matter what
# this build mirrors -- confirmed by grepping every loaded (not just
# present-in-the-repo) stylesheet for "pokemonshowdown.com" and checking
# each hit against testclient-new.html's actual <link>/linkStyle() list.
# The patch strips the CDN host, leaving a host-relative absolute path
# (`/sprites/...`) that resolves against whatever's currently serving the
# page -- our own server here.
if ! git apply --check "$PATCH_DIR/showdown-client-css-fixes.patch" 2>/tmp/patch-check.err; then
    echo "error: showdown-client-css-fixes.patch no longer applies cleanly to pokemon-showdown-client@${CLIENT_COMMIT}" >&2
    cat /tmp/patch-check.err >&2
    echo "style/client2.css or style/sim-types.css has likely changed upstream; the patch needs updating." >&2
    exit 1
fi
git apply "$PATCH_DIR/showdown-client-css-fixes.patch"
if grep -q "pokemonshowdown\.com/sprites\|pokemonshowdown\.com/fx" play.pokemonshowdown.com/style/client2.css play.pokemonshowdown.com/style/sim-types.css; then
    echo "error: an absolute CDN url(...) survived showdown-client-css-fixes.patch -- the patch is stale" >&2
    exit 1
fi

echo "==> Fixing the one hardcoded absolute-URL image left in compiled JS"
# js/panel-popups.js (built from panel-popups.tsx, which is TypeScript
# source -- can't be patches/*.patch'd pre-build the way the two static
# CSS files above are, so this is a plain post-build string replacement
# instead) has one hardcoded absolute URL: the registration form's
# "what is this pokemon?" captcha image. Same bug as the CSS ones above,
# same fix (strip the CDN host). Confirmed the string survives verbatim
# (not minified away) into the actual built, loaded file, not just present
# in the TS source.
PIKACHU_CAPTCHA_FILE="play.pokemonshowdown.com/js/panel-popups.js"
PIKACHU_CAPTCHA_COUNT="$(grep -o 'https://play\.pokemonshowdown\.com/sprites/gen5ani/pikachu\.gif' "$PIKACHU_CAPTCHA_FILE" | wc -l | tr -d ' ')"
if [ "$PIKACHU_CAPTCHA_COUNT" != "1" ]; then
    echo "error: expected exactly one hardcoded pikachu.gif captcha URL in $PIKACHU_CAPTCHA_FILE, found $PIKACHU_CAPTCHA_COUNT -- panel-popups.tsx has likely changed upstream" >&2
    exit 1
fi
sed -i 's#https://play\.pokemonshowdown\.com/sprites/gen5ani/pikachu\.gif#/sprites/gen5ani/pikachu.gif#' "$PIKACHU_CAPTCHA_FILE"

echo "==> Mirroring sprites/icons from the real CDN (build-time only, see"
echo "    scripts/mirror-sprites.js for exactly what is and isn't fetched)"
node "$SCRIPT_DIR/mirror-sprites.js" play.pokemonshowdown.com

echo "==> Moving the final static client to its own top-level directory"
mkdir -p /opt/pokemon-showdown-client-static
mv play.pokemonshowdown.com/* /opt/pokemon-showdown-client-static/
CLIENT_VERSION_FILE=/opt/pokemon-showdown-client-static/version.txt
[ -f "$CLIENT_VERSION_FILE" ] || echo "unknown" > "$CLIENT_VERSION_FILE"

echo "==> Waiting for 20-showdown-server.sh's copy to be in place"
# Only needs 20's cp -a to have landed (server/static/ is checked into the
# repo, not a build output) -- not for 20 to have finished building or
# pruning, which is why this polls a marker touched right after that copy
# rather than depending on the whole of step 20.
while [ ! -f "$STEP20_CLONE_READY_MARKER" ]; do sleep 1; done

echo "==> Merging into the server: server/static -> the built client"
# A real move/copy, not a symlink. server/static previously being a
# symlink is suspected of not resolving reliably through iSH-AOK's fakefs
# layer (the same SQLite-backed metadata shim that stands in for POSIX
# semantics APFS doesn't have -- a known fragile corner, same general
# category of issue as the fd-passing problems that motivated
# subprocesses=0 in the first place). A real directory removes that
# question entirely rather than relying on it working. Costs some extra
# disk (one copy of the built client, already present anyway) in exchange
# for one less thing to trust.
#
# Also: the client build has neither 404.html nor index.html of its own
# (confirmed directly -- play.pokemonshowdown.com/ ships neither), so
# StaticServer's own fallback-for-missing-file path would have nothing to
# serve if customhttpresponse doesn't intercept a given request for any
# reason. Copying the *original* server/static's 404.html/index.html in
# means that path can degrade to an actual 404 response instead of
# crashing outright, regardless of why customhttpresponse didn't catch
# the request.
cp /opt/pokemon-showdown/server/static/404.html /opt/pokemon-showdown-client-static/404.html
cp /opt/pokemon-showdown/server/static/index.html /opt/pokemon-showdown-client-static/index.html.stub-fallback
rm -rf /opt/pokemon-showdown/server/static
mv /opt/pokemon-showdown-client-static /opt/pokemon-showdown/server/static

echo "==> Removing the entire pokemon-showdown-client repo checkout"
echo "    (node_modules, caches/pokemon-showdown [seeded from the shared"
echo "    checkout above, build-only], build-tools/, TS src/, and everything"
echo "    else outside play.pokemonshowdown.com/ was only ever needed to"
echo "    produce the static output already moved into place above)"
cd /
rm -rf /opt/pokemon-showdown-client

cat > /opt/pokemon-showdown/server/static/BUILD_INFO.txt <<EOF
pokemon-showdown-client ref: $CLIENT_REF
pokemon-showdown-client commit: $CLIENT_COMMIT
patched: testclient-new.html (patches/showdown-client-testclient.patch)
patched: style/client2.css, style/sim-types.css (patches/showdown-client-css-fixes.patch)
patched: js/panel-popups.js (build-script sed, see 30-showdown-client.sh)
sprite mirror: see SPRITE_MIRROR_INFO.txt in this same directory
EOF
cat /opt/pokemon-showdown/server/static/BUILD_INFO.txt

echo "==> 30-showdown-client.sh finished"
