#!/bin/sh
# Step 30: build the pokemon-showdown client, make it offline-capable, and
# merge it into the server built in step 20. POSIX sh only.
set -eu

CLIENT_REF="${CLIENT_REF:-master}"
PATCH_DIR="${PATCH_DIR:-/build-input/patches}"
SCRIPT_DIR="${SCRIPT_DIR:-/build-input/scripts}"

echo "==> Cloning pokemon-showdown-client (ref: ${CLIENT_REF})"
git clone --depth 1 --branch "$CLIENT_REF" https://github.com/smogon/pokemon-showdown-client.git /opt/pokemon-showdown-client
cd /opt/pokemon-showdown-client
CLIENT_COMMIT="$(git rev-parse HEAD)"

echo "==> npm install (full -- devDependencies needed to build)"
npm install --no-audit --no-fund

echo "==> node build full (data files + TS compile; also clones+builds its"
echo "    own throwaway pokemon-showdown copy under caches/ to extract dex"
echo "    data -- this is normal, confirmed by reading build-tools/build-indexes"
echo "    directly, and that copy is deleted below once this step is done)"
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
         js/client-core.js testclient-new.html favicon-256.png; do
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

echo "==> Mirroring sprites/icons from the real CDN (build-time only, see"
echo "    scripts/mirror-sprites.js for exactly what is and isn't fetched)"
node "$SCRIPT_DIR/mirror-sprites.js" play.pokemonshowdown.com

echo "==> Moving the final static client to its own top-level directory"
mkdir -p /opt/pokemon-showdown-client-static
mv play.pokemonshowdown.com/* /opt/pokemon-showdown-client-static/
CLIENT_VERSION_FILE=/opt/pokemon-showdown-client-static/version.txt
[ -f "$CLIENT_VERSION_FILE" ] || echo "unknown" > "$CLIENT_VERSION_FILE"

echo "==> Merging into the server: server/static -> the built client"
mv /opt/pokemon-showdown/server/static /opt/pokemon-showdown/server/static-stub
ln -s /opt/pokemon-showdown-client-static /opt/pokemon-showdown/server/static

echo "==> Removing the entire pokemon-showdown-client repo checkout"
echo "    (node_modules, caches/pokemon-showdown [a full second copy of the"
echo "    server, build-only], build-tools/, TS src/, and everything else"
echo "    outside play.pokemonshowdown.com/ was only ever needed to produce"
echo "    the static output already moved out above)"
cd /
rm -rf /opt/pokemon-showdown-client

cat > /opt/pokemon-showdown-client-static/BUILD_INFO.txt <<EOF
pokemon-showdown-client ref: $CLIENT_REF
pokemon-showdown-client commit: $CLIENT_COMMIT
patched: testclient-new.html (patches/showdown-client-testclient.patch)
sprite mirror: see SPRITE_MIRROR_INFO.txt in this same directory
EOF
cat /opt/pokemon-showdown-client-static/BUILD_INFO.txt

echo "==> 30-showdown-client.sh finished"
