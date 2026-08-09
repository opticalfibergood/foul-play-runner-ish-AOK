#!/bin/sh
# Step 20: build the pokemon-showdown server. POSIX sh only.
set -eu

SHOWDOWN_REF="${SHOWDOWN_REF:-master}"
PATCH_DIR="${PATCH_DIR:-/build-input/patches}"
SRC_READY_MARKER=/tmp/.pokemon-showdown-src-ready
CLONE_READY_MARKER=/tmp/.step20-clone-ready

echo "==> Waiting for 15-showdown-src.sh's shared clone+install"
while [ ! -f "$SRC_READY_MARKER" ]; do sleep 1; done

echo "==> Copying the shared pokemon-showdown checkout into place (see"
echo "    15-showdown-src.sh -- this used to be its own separate clone +"
echo "    npm install, ~2 minutes; a local copy of an already-installed"
echo "    checkout is seconds)"
cp -a /opt/pokemon-showdown-src /opt/pokemon-showdown
cd /opt/pokemon-showdown
SHOWDOWN_COMMIT="$(git rev-parse HEAD)"
# 30 needs this directory to exist (specifically server/static/, a
# checked-in dir, not a build output) before its own final merge step --
# touch this the moment the copy lands, well before build/prune below,
# since 30 polls for it independently rather than waiting on this whole
# script to finish.
touch "$CLONE_READY_MARKER"

echo "==> node build (compiles TypeScript -> dist/, via esbuild + libc6-compat)"
node build

test -d dist/server || { echo "error: dist/server missing after build" >&2; exit 1; }

echo "==> Preparing config/config.js from config-example.js"
cp config/config-example.js config/config.js

echo "==> Applying showdown-server-config.patch"
# Sets subprocesses=0 (no cluster.fork()/child_process.fork() -- see the
# patch file itself for why that specifically has to be the bare number,
# not an object), noguestsecurity=true, logchat/logchallenges=true, and
# adds a customhttpresponse hook that auto-sends `/trn human` once the
# client's finished loading. git apply fails loudly if config-example.js
# has drifted from what this patch expects.
# git apply resolves patch paths relative to the repo root, not CWD --
# this only works because we're sitting at /opt/pokemon-showdown (the
# repo root) and the patch's path is config/config.js, not a bare
# filename applied from within config/. See showdown-client-testclient.
# patch's application in 30-showdown-client.sh for what goes wrong
# otherwise.
if ! git apply --check "$PATCH_DIR/showdown-server-config.patch" 2>/tmp/patch-check.err; then
    echo "error: showdown-server-config.patch no longer applies cleanly to pokemon-showdown@${SHOWDOWN_COMMIT}" >&2
    cat /tmp/patch-check.err >&2
    echo "config-example.js has likely changed upstream; the patch needs updating." >&2
    exit 1
fi
git apply "$PATCH_DIR/showdown-server-config.patch"

echo "==> Verifying the patched config (syntax + semantic checks)"
node --check config/config.js
node -e "
const c = require('/opt/pokemon-showdown/config/config.js');
function assertEq(name, actual, expected) {
    if (actual !== expected) throw new Error(\`config.\${name} = \${actual}, expected \${expected}\`);
    console.log(\`  config.\${name} = \${actual}\`);
}
assertEq('subprocesses', c.subprocesses, 0);
assertEq('noguestsecurity', c.noguestsecurity, true);
assertEq('logchat', c.logchat, true);
assertEq('logchallenges', c.logchallenges, true);
if (typeof c.customhttpresponse !== 'function') throw new Error('customhttpresponse is not a function');
console.log('  config.customhttpresponse is a function: OK');

// The injected <script> is browser JS embedded as a template string inside
// this Node file -- node --check on config.js itself doesn't touch that
// string's own syntax at all, so extract and check it separately. This is
// what would have caught a typo in the injected script before it ever
// reached a real browser.
const fnSrc = c.customhttpresponse.toString();
const m = fnSrc.match(/<script>\n([\s\S]*?)\n<\/script>/);
if (!m) throw new Error('could not find the injected <script> block in customhttpresponse');
require('fs').writeFileSync('/tmp/injected-script-check.js', m[1]);
require('child_process').execFileSync('node', ['--check', '/tmp/injected-script-check.js']);
console.log('  injected browser script syntax OK');
if (!m[1].includes('PS.server.protocol') || !m[1].includes('PS.connection.reconnect()')) {
    throw new Error('injected script is missing the PS.server.protocol/reconnect fix');
}
console.log('  injected browser script contains the protocol fix: OK');
"

echo "==> npm prune (drop devDependencies: typescript, eslint, mocha, ...)"
npm prune --omit=dev

echo "==> Removing TypeScript/build-only source"
# dist/ is fully self-contained at runtime EXCEPT for server/static (the
# static file server's root is intentionally a live, uncompiled directory
# outside dist/ -- that's what patches/showdown-server-config.patch's
# customhttpresponse hook and the client merge in step 30 both rely on).
# This isn't an assumption: verified empirically by actually deleting
# sim/, data/, lib/, tools/, translations/, and everything in server/
# except static/, then starting the real server and confirming it both
# comes up AND serves a real HTTP 200 (deleting server/ entirely, by
# contrast, starts fine but crashes on the first request -- StaticServer
# reads server/static/404.html from the literal source path, not dist/).
find server -mindepth 1 -maxdepth 1 -not -name static -exec rm -rf {} +
rm -rf sim data lib tools translations
find . -maxdepth 1 -name "*.ts" -delete
rm -rf test .github .git .eslintrc.json eslint.config.mjs eslint-ps-standard.mjs \
       tsconfig.json .editorconfig .mocharc.yml ARCHITECTURE.md COMMANDLINE.md \
       CONTRIBUTING.md PROTOCOL.md old-simulator-doc.txt simulator-doc.txt \
       CREDITS *.md 2>/dev/null || true

cat > /opt/pokemon-showdown/BUILD_INFO.txt <<EOF
pokemon-showdown ref: $SHOWDOWN_REF
pokemon-showdown commit: $SHOWDOWN_COMMIT
patched: config/config.js (patches/showdown-server-config.patch)
EOF
cat /opt/pokemon-showdown/BUILD_INFO.txt

echo "==> 20-showdown-server.sh finished"
