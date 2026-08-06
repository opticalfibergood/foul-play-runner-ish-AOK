#!/usr/bin/env node
'use strict';
/**
 * Verifies the patched testclient-new.html: extracts the embedded
 * `if (!window.Config) { ... }` fallback-config script block, checks it's
 * syntactically valid JS on its own, then actually executes it in a
 * minimal browser-ish shim and asserts the values patches/
 * showdown-client-testclient.patch is supposed to have set.
 *
 * This is deliberately a real syntax + semantic check, not just "the file
 * still has the string localhost:8000 in it somewhere" -- if the patch
 * partially applied, or upstream reordered things such that the values
 * don't end up where expected, this fails loudly.
 */
const fs = require('node:fs');
const vm = require('node:vm');

const file = process.argv[2];
if (!file) {
	console.error('usage: verify-testclient-html.js <path to testclient-new.html>');
	process.exit(1);
}

const html = fs.readFileSync(file, 'utf8');

const match = html.match(/<script>\s*(if \(!window\.Config\)[\s\S]*?)<\/script>/);
if (!match) {
	console.error('error: could not find the "if (!window.Config) {...}" script block in', file);
	process.exit(1);
}
const snippet = match[1];

// Syntax check first, as its own step, before trying to execute it.
try {
	new vm.Script(snippet, { filename: 'testclient-new.html:embedded-config' });
} catch (err) {
	console.error('error: embedded config script has a syntax error:', err.message);
	process.exit(1);
}
console.log('  syntax OK');

// Then a semantic check: actually run it with the same window===global
// aliasing a real browser has, and check the values the patch is
// supposed to have set.
const sandbox = { location: { search: '' }, document: {} };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(snippet, sandbox);

const Config = sandbox.Config;
const expectations = {
	'Config.routes.client': [Config?.routes?.client, 'localhost:8000'],
	'Config.routes.dex': [Config?.routes?.dex, 'localhost:8000'],
	'Config.defaultserver.host': [Config?.defaultserver?.host, 'localhost'],
	'Config.defaultserver.port': [Config?.defaultserver?.port, 8000],
	'Config.defaultserver.httpport': [Config?.defaultserver?.httpport, 8000],
	'Config.testclient': [Config?.testclient, true],
};

let failed = false;
for (const [name, [actual, expected]] of Object.entries(expectations)) {
	if (actual !== expected) {
		console.error(`  FAIL: ${name} = ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
		failed = true;
	} else {
		console.log(`  ${name} = ${JSON.stringify(actual)}`);
	}
}

if (!/src="favicon-256\.png"/.test(html)) {
	console.error('  FAIL: favicon-256.png reference is not a local relative path');
	failed = true;
}
if (!/src="data\/pokedex-mini\.js" onerror="loadRemoteData/.test(html)) {
	console.error('  FAIL: pokedex-mini.js is not a local relative path with the onerror fallback');
	failed = true;
}
if (!/src="data\/pokedex-mini-bw\.js" onerror="loadRemoteData/.test(html)) {
	console.error('  FAIL: pokedex-mini-bw.js is not a local relative path with the onerror fallback');
	failed = true;
}
if (/<script src="https:\/\/play\.pokemonshowdown\.com\/config\/config\.js">/.test(html)) {
	console.error('  FAIL: the remote config.js load was not removed');
	failed = true;
}

// The reconnect-race fix: PSServer.protocol must be corrected *before*
// the connection worker's first 'connect' message, or the worker starts
// a real, doomed wss:// attempt against the plain http server, and a
// later forced disconnect+reconnect races that attempt's own async
// onclose handler (which unconditionally clobbers the worker's shared
// socket reference) -- producing an endless connect/disconnect loop.
// So this checks two things, not just one string's presence: the
// wrapper exists, AND it appears strictly before client-connection.js
// is loaded.
const workerWrapIdx = html.indexOf('window.Worker = function');
const clientConnectionIdx = html.indexOf('<script src="js/client-connection.js">');
if (workerWrapIdx === -1) {
	console.error('  FAIL: no Worker.postMessage protocol-fix wrapper found in testclient-new.html');
	failed = true;
} else if (clientConnectionIdx === -1) {
	console.error('  FAIL: could not find the client-connection.js script tag to check ordering against');
	failed = true;
} else if (workerWrapIdx > clientConnectionIdx) {
	console.error('  FAIL: Worker wrapper is injected AFTER client-connection.js loads -- too late, the race is back');
	failed = true;
} else {
	console.log('  Worker protocol-fix wrapper present and correctly ordered before client-connection.js');
}
// And that it actually does the one thing that matters: forces the
// protocol on outgoing 'connect' messages before they reach the worker.
if (!/msg\.server\.protocol\s*=\s*['"]http['"]/.test(html)) {
	console.error("  FAIL: Worker wrapper doesn't appear to force server.protocol = 'http' on connect messages");
	failed = true;
}

if (failed) {
	console.error('error: testclient-new.html failed verification');
	process.exit(1);
}
console.log('  all checks passed');
