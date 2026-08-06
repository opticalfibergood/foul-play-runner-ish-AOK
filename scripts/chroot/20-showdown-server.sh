#!/bin/sh
# Step 20: build the pokemon-showdown server. POSIX sh only.
set -eu

SHOWDOWN_REF="${SHOWDOWN_REF:-master}"
PATCH_DIR="${PATCH_DIR:-/build-input/patches}"

echo "==> Cloning pokemon-showdown (ref: ${SHOWDOWN_REF})"
git clone --depth 1 --branch "$SHOWDOWN_REF" https://github.com/smogon/pokemon-showdown.git /opt/pokemon-showdown
cd /opt/pokemon-showdown
SHOWDOWN_COMMIT="$(git rev-parse HEAD)"

echo "==> npm install (full -- devDependencies are needed to actually build)"
npm install --no-audit --no-fund

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
// The protocol fix itself now lives client-side (a Worker.postMessage
// wrap in testclient-new.html, applied before client-connection.js ever
// loads -- see showdown-client-testclient.patch and its verification in
// scripts/verify-testclient-html.js). This script's only remaining job
// is the auto-login, and it must wait for an actual connection rather
// than firing blind -- otherwise the send can race a not-yet-open
// socket and get silently dropped.
if (!m[1].includes(\"PS.connection.connected\") || !m[1].includes(\"PS.send('/trn human')\")) {
    throw new Error('injected script is missing the connected-gated /trn human auto-login');
}
console.log('  injected browser script contains the gated auto-login: OK');
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
