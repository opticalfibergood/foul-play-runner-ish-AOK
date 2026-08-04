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
