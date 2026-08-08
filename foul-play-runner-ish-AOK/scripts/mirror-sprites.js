#!/usr/bin/env node
'use strict';
/**
 * Mirrors a deliberately bounded set of Pokemon Showdown's sprite/icon
 * assets from the real production CDN into the local, already-built
 * client's static directory -- so the offline client (pointed at our own
 * server via patches/showdown-client-testclient.patch, which sets
 * Config.routes.client) actually has files to load instead of 404s.
 *
 * Why this is needed at all: play.pokemonshowdown.com/sprites/ in the
 * client's own git repo is essentially empty (a handful of index.php
 * files) -- the real site's sprite images live only on the live CDN, not
 * in source control. Confirmed by hand against the actual repo.
 *
 * Scope (deliberately bounded, not a full mirror):
 *   - sprite sheets: pokemon icons, pokeball icons, item icons (each is
 *     ONE image file covering every species/item -- cheap)
 *   - type icons + tera-type icons, category icons (small, fixed sets)
 *   - per-species STATIC battle sprites, front+back, normal+shiny, from
 *     the "gen5" sprite family. This is not an arbitrary choice: per
 *     battle-dex.ts's getSpriteData(), gen6-9 Pokemon's static sprite
 *     baseDir always falls back to 'gen5' (baseDir is '' for those gens,
 *     and `(baseDir || 'gen5')` catches it) -- so this one family of
 *     directories is what a default, non-animated, current-gen battle
 *     actually requests for every species regardless of its real
 *     generation. Verified directly against a real build's pokedex.js.
 *   - data/pokedex-mini(-bw).js: NOT images, gender-variant/animation
 *     metadata used by getSpriteData(). These are the two files
 *     testclient-new.html hardcodes an absolute CDN URL for with no
 *     local-path attempt at all (the patch changes that to a relative
 *     path + the same onerror-fallback pattern every other data script
 *     already uses).
 *
 * Deliberately NOT mirrored (see README "Sprites and icons" for how to
 * extend this if you want more):
 *   - animated GIF battle sprites (the 'ani'/'ani-back' directories) --
 *     large, and this build's client patch doesn't need them since static
 *     sprites are what a default gen6-9 battle requests anyway
 *   - audio cries
 *   - gen1-gen4 sprite directories (only matters for old-gen formats)
 *   - team-builder-only preview sprites (home-centered/dex/xydex
 *     directories -- used only while building a team, not during battle)
 */

const fs = require('node:fs');
const path = require('node:path');
const { setTimeout: sleep } = require('node:timers/promises');

const CDN = 'https://play.pokemonshowdown.com';
const OUT_DIR = process.argv[2];
const CONCURRENCY = Number(process.env.MIRROR_CONCURRENCY || 8);

if (!OUT_DIR) {
	console.error('usage: mirror-sprites.mjs <path to built play.pokemonshowdown.com dir>');
	process.exit(1);
}

function toID(text) {
	if (text != null && text.id) text = text.id;
	if (typeof text !== 'string' && typeof text !== 'number') return '';
	return ('' + text).toLowerCase().replace(/[^a-z0-9]+/g, '');
}

// Exact algorithm copied from battle-dex-data.ts's Species constructor
// (verified against a real build: 1517 species -> 1503 unique spriteids,
// spot-checked against megas, gmax, regional formes, totems, the
// greninja-bond/rockruff-dusk special cases, etc).
function spriteIdFor(id, data) {
	const baseSpecies = data.baseSpecies || data.name;
	const forme = data.forme || '';
	const baseId = toID(baseSpecies);
	const formeid = baseId === id ? '' : '-' + toID(forme);
	let spriteid = baseId + formeid;
	if (spriteid.endsWith('totem')) spriteid = spriteid.slice(0, -5);
	if (spriteid === 'greninja-bond') spriteid = 'greninja';
	if (spriteid === 'rockruff-dusk') spriteid = 'rockruff';
	if (spriteid.endsWith('-')) spriteid = spriteid.slice(0, -1);
	return spriteid;
}

const SPECIES_SPRITE_DIRS = ['gen5', 'gen5-back', 'gen5-shiny', 'gen5-back-shiny'];

// Types as of gen9 plus the neutral/unknown type and Tera-type icon variants
// (sprites/types/Tera<Type>.png, used for the Tera-type badge).
const TYPES = [
	'Normal', 'Fire', 'Water', 'Electric', 'Grass', 'Ice', 'Fighting', 'Poison',
	'Ground', 'Flying', 'Psychic', 'Bug', 'Rock', 'Ghost', 'Dragon', 'Dark',
	'Steel', 'Fairy', 'Stellar', '???',
];
const CATEGORIES = ['physical', 'special', 'status'];

function buildFixedFileList() {
	const files = [
		'sprites/pokemonicons-sheet.png',
		'sprites/pokemonicons-pokeball-sheet.png',
		'sprites/itemicons-sheet.png',
		'data/pokedex-mini.js',
		'data/pokedex-mini-bw.js',
	];
	for (const t of TYPES) {
		files.push(`sprites/types/${encodeURIComponent(t)}.png`);
		files.push(`sprites/types/Tera${encodeURIComponent(t)}.png`);
	}
	for (const c of CATEGORIES) files.push(`sprites/categories/${c}.png`);
	return files;
}

function buildSpeciesFileList(pokedex) {
	const spriteids = new Set();
	for (const id of Object.keys(pokedex)) {
		spriteids.add(spriteIdFor(id, pokedex[id]));
	}
	const files = [];
	for (const spriteid of spriteids) {
		for (const dir of SPECIES_SPRITE_DIRS) {
			files.push(`sprites/${dir}/${spriteid}.png`);
		}
	}
	return files;
}

async function downloadOne(relPath, stats) {
	const url = `${CDN}/${relPath}`;
	const dest = path.join(OUT_DIR, relPath);

	if (fs.existsSync(dest) && fs.statSync(dest).size > 0) {
		stats.skipped++;
		return;
	}

	for (let attempt = 1; attempt <= 3; attempt++) {
		try {
			const res = await fetch(url, {
				headers: { 'User-Agent': 'foul-play-ish-aok sprite mirror (build-time only)' },
			});
			if (res.status === 404) {
				stats.missing++;
				stats.missingList.push(relPath);
				return;
			}
			if (!res.ok) throw new Error(`HTTP ${res.status}`);

			const buf = Buffer.from(await res.arrayBuffer());
			fs.mkdirSync(path.dirname(dest), { recursive: true });
			fs.writeFileSync(dest, buf);
			stats.downloaded++;
			stats.bytes += buf.length;
			return;
		} catch (err) {
			if (attempt === 3) {
				stats.failed++;
				stats.failedList.push(`${relPath}: ${err.message}`);
				return;
			}
			await sleep(300 * attempt);
		}
	}
}

async function pool(items, worker, concurrency) {
	let i = 0;
	async function next() {
		while (i < items.length) {
			const item = items[i++];
			await worker(item);
		}
	}
	await Promise.all(Array.from({ length: concurrency }, next));
}

async function main() {
	const pokedexPath = path.join(OUT_DIR, 'data/pokedex.js');
	if (!fs.existsSync(pokedexPath)) {
		console.error(`error: ${pokedexPath} not found -- run the client build first`);
		process.exit(1);
	}
	const pokedex = require(path.resolve(pokedexPath)).BattlePokedex;

	const files = [...buildFixedFileList(), ...buildSpeciesFileList(pokedex)];
	console.log(`Mirroring ${files.length} sprite/icon/data files (concurrency ${CONCURRENCY})...`);

	const stats = {
		downloaded: 0, skipped: 0, missing: 0, failed: 0, bytes: 0,
		missingList: [], failedList: [],
	};

	const start = Date.now();
	await pool(files, (f) => downloadOne(f, stats), CONCURRENCY);
	const seconds = ((Date.now() - start) / 1000).toFixed(1);

	console.log(`Done in ${seconds}s: ${stats.downloaded} downloaded, ${stats.skipped} already present, ` +
		`${stats.missing} missing on CDN (expected for some forms), ${stats.failed} failed, ` +
		`${(stats.bytes / 1024 / 1024).toFixed(1)} MiB fetched.`);

	if (stats.missingList.length) {
		console.log(`(missing, not fetched -- likely no art in this sprite family): ${stats.missingList.length} files`);
	}

	// A handful of failures (network blips) are tolerable; a LOT of them
	// means something structural is wrong (wrong URL pattern, CDN down,
	// no network) and the build should stop rather than ship a rootfs
	// with mostly-broken sprites.
	const failureRate = stats.failed / files.length;
	if (failureRate > 0.05) {
		console.error(`error: ${stats.failed}/${files.length} downloads failed (${(failureRate * 100).toFixed(1)}%) -- aborting`);
		console.error(stats.failedList.slice(0, 20).join('\n'));
		process.exit(1);
	}

	fs.writeFileSync(
		path.join(OUT_DIR, 'SPRITE_MIRROR_INFO.txt'),
		`mirrored: ${stats.downloaded} files, ${(stats.bytes / 1024 / 1024).toFixed(1)} MiB\n` +
		`missing on CDN: ${stats.missing}\n` +
		`failed: ${stats.failed}\n` +
		`species sprite dirs: ${SPECIES_SPRITE_DIRS.join(', ')}\n` +
		`built: ${new Date().toISOString()}\n`
	);
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
