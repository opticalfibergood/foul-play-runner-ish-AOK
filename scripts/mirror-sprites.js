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
 * Mirrored:
 *   - sprite sheets: pokemon icons, pokeball icons, item icons (each is
 *     ONE image file covering every species/item -- cheap)
 *   - type icons + tera-type icons, category icons (small, fixed sets)
 *   - per-species battle sprites, front+back, normal+shiny -- BOTH the
 *     static PNGs (the "gen5" family, always mirrored as the ultimate
 *     fallback) AND the animated GIFs, in whichever of the two families
 *     (see below) actually has art for that species. An earlier version
 *     of this script only mirrored the static family and then forced the
 *     client's "noanim" pref on client-side to match -- that "worked" in
 *     the sense that nothing 404'd, but it meant the client never showed
 *     the animated sprites it's normally supposed to. This version
 *     mirrors the real thing instead.
 *
 *     battle-dex.ts's getSpriteData() can end up requesting an animated
 *     sprite from either of two independent directory families, and
 *     which one depends on a *client-side setting* (the "2D sprites
 *     instead of 3D models" / bwgfx pref), not anything this build
 *     controls -- so both need to be mirrored for every species that has
 *     them, not just whichever one getSpriteData() would pick under
 *     default settings:
 *       - the current-gen family ('ani'/'ani-back', animDir ''), sourced
 *         from data/pokedex-mini.js's BattlePokemonSprites -- used when
 *         bwgfx is off (the default) and the species has an entry there.
 *       - the BW/legacy family ('gen5ani'/'gen5ani-back', animDir
 *         'gen5'), sourced from data/pokedex-mini-bw.js's
 *         BattlePokemonSpritesBW -- used when bwgfx is on (regardless of
 *         whether the current-gen family also has an entry), AND as the
 *         fallback when bwgfx is off but the current-gen family doesn't
 *         have this species/facing.
 *     Both families also have '-shiny' directory variants, and (for the
 *     handful of species with a visually distinct female forme, e.g.
 *     Pyroar) a '-f' filename suffix within the same directory. All of
 *     that is replicated here exactly from getSpriteData()'s own logic
 *     (see resolveAnimatedFilesForFacing() below) rather than guessed at,
 *     using the metadata already being mirrored for this exact purpose
 *     (data/pokedex-mini(-bw).js). Those two files' *content*, not just
 *     their presence, is needed before the rest of the file list can be
 *     computed, so they're fetched up front rather than as part of the
 *     main pool below (downloadOne no-ops on files already present, so
 *     listing them again in the main pool afterwards is harmless).
 *
 *     If either file can't be parsed the way data/pokedex.js already is
 *     elsewhere in this script (some future upstream format change),
 *     this falls back to fetching every variant in that file's family
 *     for every species rather than silently mirroring nothing for it --
 *     more bandwidth, but not broken. The extra 404s this can cause for
 *     species without real art in that family are expected and tolerated
 *     (see downloadOne/stats.missing below) either way.
 *   - data/pokedex-mini(-bw).js: NOT images, the animation metadata
 *     described above. These are the two files testclient-new.html
 *     hardcodes an absolute CDN URL for with no local-path attempt at
 *     all (the patch changes that to a relative path + the same
 *     onerror-fallback pattern every other data script already uses).
 *   - trainer avatars (sprites/trainers/*.png, plus the handful of
 *     '#'-prefixed special ones under sprites/trainers-custom/*.png) --
 *     these were missing from every earlier version of this script
 *     entirely (confirmed: nothing in the old file list ever referenced
 *     'sprites/trainers'), so Dex.resolveAvatar() (battle-dex.ts) 404'd
 *     for every user, including the auto-named "human"/"bot" this build
 *     always connects as. The name list isn't derivable from any built
 *     data/*.js file the way species are from data/pokedex.js -- it only
 *     exists as the BattleAvatarNumbers map in
 *     play.pokemonshowdown.com/src/battle-dex-data.ts (that src/
 *     directory is still present at this point in the build, before
 *     30-showdown-client.sh's final `rm -rf` of the whole checkout), so
 *     this reads and evaluates that object literal directly out of it
 *     rather than trying to keep a second hardcoded copy of ~300 names in
 *     sync by hand.
 *
 * Deliberately NOT mirrored (see README "Sprites and icons" for how to
 * extend this if you want more):
 *   - audio cries
 *   - gen1-gen4 sprite directories (only matters for old-gen formats,
 *     i.e. graphicsGen <= 4, which requires either playing an old-gen
 *     format or the "nopastgens"/specific old-gen-forcing prefs -- not
 *     reachable via the two settings, default and bwgfx, that the "2D
 *     sprites instead of 3D models" checkbox actually toggles between)
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

const STATIC_SPECIES_SPRITE_DIRS = ['gen5', 'gen5-back', 'gen5-shiny', 'gen5-back-shiny'];

// The two animated-sprite families getSpriteData() can draw from. animDir
// is the literal prefix it puts in front of 'ani'/'ani-back' -- '' for the
// current-gen family, 'gen5' for the BW/legacy one -- exactly matching
// `dir = animDir + 'ani' + dir;` in battle-dex.ts.
const ANIMATED_FAMILIES = [
	{ animDir: '', dictExport: 'BattlePokemonSprites', dataFile: 'data/pokedex-mini.js' },
	{ animDir: 'gen5', dictExport: 'BattlePokemonSpritesBW', dataFile: 'data/pokedex-mini-bw.js' },
];

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
	];
	for (const t of TYPES) {
		files.push(`sprites/types/${encodeURIComponent(t)}.png`);
		files.push(`sprites/types/Tera${encodeURIComponent(t)}.png`);
	}
	for (const c of CATEGORIES) files.push(`sprites/categories/${c}.png`);
	return files;
}

// Same convention as data/pokedex.js (already required elsewhere in this
// script): these built data files export via `exports.<name> = {...}`
// (also assigning to `window.<name>` for the plain <script> tag load) and
// are require()-able directly. Returns null if the file is missing
// entirely (unexpected, but downloadOne's 404 handling already tolerates
// it) or doesn't export the expected shape.
function tryReadDict(absPath, exportName) {
	if (!fs.existsSync(absPath) || fs.statSync(absPath).size === 0) return null;
	const mod = require(absPath);
	const dict = mod[exportName];
	if (!dict || typeof dict !== 'object') {
		throw new Error(`${absPath} did not export ${exportName} the way data/pokedex.js exports BattlePokedex`);
	}
	return dict;
}

// Mirrors getSpriteData()'s animated-sprite resolution (battle-dex.ts)
// for one facing ('front' or 'back') of one already-deduped spriteid,
// checking each of the two families independently (not "first match
// wins" -- see the ANIMATED_FAMILIES comment above for why both need
// mirroring). rawIds is every pokedex id that maps to this spriteid
// (usually one; occasionally more, e.g. cosmetic-only formes); a family
// counts as present if ANY of them has an entry, matching how a real
// battle could reference any of those ids.
function resolveAnimatedFilesForFacing(spriteid, facing, rawIds, dicts, fallbackFamilies) {
	const files = [];
	const backSuffix = facing === 'back' ? '-back' : '';

	for (const family of ANIMATED_FAMILIES) {
		const dict = dicts[family.dictExport];
		let hasFacing = false;
		let hasGenderVariant = false;

		if (fallbackFamilies.has(family.dictExport)) {
			// Metadata for this family is unavailable/unparseable -- can't
			// tell which species really have art in it, so fetch every
			// variant for every species instead. Extra 404s here are
			// expected (see downloadOne).
			hasFacing = true;
		} else if (dict) {
			for (const rawId of rawIds) {
				const entry = dict[rawId];
				if (entry && entry[facing]) {
					hasFacing = true;
					if (entry[facing + 'f']) hasGenderVariant = true;
				}
			}
		}

		if (!hasFacing) continue;
		const dirs = [`${family.animDir}ani${backSuffix}`, `${family.animDir}ani${backSuffix}-shiny`];
		for (const dir of dirs) {
			files.push(`sprites/${dir}/${spriteid}.gif`);
			if (hasGenderVariant) files.push(`sprites/${dir}/${spriteid}-f.gif`);
		}
	}
	return files;
}

// The static-sprite equivalent of the '-f' gender variant above: mirrors
// the `if (spriteData.gen >= 4 && miscData['frontf'] && ...) name +=
// '-f';` branch of getSpriteData()'s non-animated fallback. miscData
// there is whichever of the two dicts has an entry for the species
// (current-gen preferred), checked only for 'frontf' regardless of
// front/back -- reproduced as-is here, quirk and all, rather than
// "fixed", since matching the real client's actual request is the goal.
function hasStaticFrontFemaleVariant(rawIds, dicts, fallbackFamilies) {
	for (const family of ANIMATED_FAMILIES) {
		if (fallbackFamilies.has(family.dictExport)) return true; // unknown -> mirror it to be safe
		const dict = dicts[family.dictExport];
		if (!dict) continue;
		for (const rawId of rawIds) {
			if (dict[rawId]) return !!dict[rawId].frontf;
		}
	}
	return false;
}

function buildSpeciesFileList(pokedex, dicts, fallbackFamilies) {
	// Group raw pokedex ids by their (deduped) spriteid: getSpriteData()
	// looks up animation metadata by the *raw* id, but downloads/displays
	// under the *spriteid* filename, and several raw ids can share one
	// spriteid (e.g. cosmetic-only formes) -- so a family/facing counts as
	// present for a spriteid if any of its raw ids has it.
	const rawIdsBySpriteid = new Map();
	for (const id of Object.keys(pokedex)) {
		const spriteid = spriteIdFor(id, pokedex[id]);
		if (!rawIdsBySpriteid.has(spriteid)) rawIdsBySpriteid.set(spriteid, []);
		rawIdsBySpriteid.get(spriteid).push(id);
	}

	const files = [];
	for (const [spriteid, rawIds] of rawIdsBySpriteid) {
		for (const dir of STATIC_SPECIES_SPRITE_DIRS) {
			files.push(`sprites/${dir}/${spriteid}.png`);
		}
		if (hasStaticFrontFemaleVariant(rawIds, dicts, fallbackFamilies)) {
			files.push(`sprites/gen5/${spriteid}-f.png`);
			files.push(`sprites/gen5-shiny/${spriteid}-f.png`);
		}
		for (const facing of ['front', 'back']) {
			files.push(...resolveAnimatedFilesForFacing(spriteid, facing, rawIds, dicts, fallbackFamilies));
		}
	}
	return files;
}

// BattleAvatarNumbers only exists as a TS source literal
// (play.pokemonshowdown.com/src/battle-dex-data.ts), not in any built
// data/*.js file -- so, unlike species, this reads it directly out of the
// client checkout rather than require()ing a build product. src/ lives
// inside OUT_DIR itself, same level as data/ (confirmed against a real
// checkout -- it is NOT a sibling of OUT_DIR).
function readBattleAvatarNumbers(outDir) {
	const srcPath = path.join(outDir, 'src', 'battle-dex-data.ts');
	const src = fs.readFileSync(srcPath, 'utf8');
	const match = src.match(/export const BattleAvatarNumbers:[^=]*=\s*(\{[\s\S]*?\n\};)/);
	if (!match) {
		throw new Error(`could not find "export const BattleAvatarNumbers = {...}" in ${srcPath} -- upstream has likely changed it`);
	}
	const objectLiteral = match[1].replace(/;\s*$/, '');
	// Safe: this is a plain object literal of number/string keys to
	// string values straight out of a source file this build already
	// trusts (same trust level as require()ing data/pokedex.js below).
	return new Function(`'use strict'; return (${objectLiteral});`)();
}

// Mirrors battle-dex.ts's Dex.resolveAvatar(): a name starting with '#' is
// a special avatar served from sprites/trainers-custom/ (as toID(name
// minus the '#')); everything else is sprites/trainers/<name>.png. Also
// always includes 'unknown', resolveAvatar's own fallback for a
// missing/unrecognized avatar (e.g. before a user's avatar has loaded).
function buildAvatarFileList(outDir) {
	const avatarNumbers = readBattleAvatarNumbers(outDir);
	const names = new Set(['unknown']);
	for (const name of Object.values(avatarNumbers)) names.add(name);

	const files = [];
	for (const name of names) {
		if (name.startsWith('#')) {
			files.push(`sprites/trainers-custom/${toID(name.slice(1))}.png`);
		} else {
			files.push(`sprites/trainers/${name}.png`);
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

function newStats() {
	return { downloaded: 0, skipped: 0, missing: 0, failed: 0, bytes: 0, missingList: [], failedList: [] };
}

async function main() {
	const pokedexPath = path.join(OUT_DIR, 'data/pokedex.js');
	if (!fs.existsSync(pokedexPath)) {
		console.error(`error: ${pokedexPath} not found -- run the client build first`);
		process.exit(1);
	}
	const pokedex = require(path.resolve(pokedexPath)).BattlePokedex;

	const stats = newStats();

	// The animated-sprite file list can't be computed without the actual
	// *content* of the two animation-metadata files, so fetch just those
	// two up front. Re-listing them in the main pool below is harmless
	// (downloadOne skips files already on disk).
	for (const family of ANIMATED_FAMILIES) {
		await downloadOne(family.dataFile, stats);
	}

	const dicts = {};
	const fallbackFamilies = new Set();
	for (const family of ANIMATED_FAMILIES) {
		const absPath = path.resolve(path.join(OUT_DIR, family.dataFile));
		try {
			dicts[family.dictExport] = tryReadDict(absPath, family.dictExport);
		} catch (err) {
			console.error(`warning: couldn't read animated-sprite metadata from ${family.dataFile} (${err.message}) -- ` +
				`falling back to fetching every ${family.dictExport === 'BattlePokemonSprites' ? 'current-gen' : 'BW'} ` +
				`animated variant for every species instead of just the ones that exist`);
			fallbackFamilies.add(family.dictExport);
		}
	}

	const avatarFiles = buildAvatarFileList(OUT_DIR);
	const speciesFiles = buildSpeciesFileList(pokedex, dicts, fallbackFamilies);
	// A handful of species (e.g. Meowstic/Indeedee/Basculegion/Oinkologne)
	// model their female form as a *separate* pokedex entry with its own
	// spriteid ('meowstic-f'), which can collide with the '-f' filename
	// buildSpeciesFileList also generates for the base entry's gender
	// variant -- same path, generated two different ways. Harmless
	// (downloadOne no-ops on a file already on disk) but wasteful to
	// fetch/list twice, so dedupe once here rather than chase every
	// individual collision.
	const files = [...new Set([...buildFixedFileList(), ...speciesFiles, ...avatarFiles])];
	console.log(`Mirroring ${files.length} sprite/icon/data files (concurrency ${CONCURRENCY})...`);

	const start = Date.now();
	await pool(files, (f) => downloadOne(f, stats), CONCURRENCY);
	const seconds = ((Date.now() - start) / 1000).toFixed(1);

	console.log(`Done in ${seconds}s: ${stats.downloaded} downloaded, ${stats.skipped} already present, ` +
		`${stats.missing} missing on CDN (expected -- most species only have art in one animated family), ` +
		`${stats.failed} failed, ${(stats.bytes / 1024 / 1024).toFixed(1)} MiB fetched.`);

	// A handful of failures (network blips) are tolerable; a LOT of them
	// means something structural is wrong (wrong URL pattern, CDN down,
	// no network) and the build should stop rather than ship a rootfs
	// with mostly-broken sprites. (404s are tracked separately as
	// "missing", not "failed", and are NOT subject to this budget --
	// they're an expected, unbounded outcome of mirroring two animated
	// families per species when most species only have art in one.)
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
		`static species sprite dirs: ${STATIC_SPECIES_SPRITE_DIRS.join(', ')}\n` +
		`animated families: ${ANIMATED_FAMILIES.map(f => f.dictExport).join(', ')}` +
		`${fallbackFamilies.size ? ` (brute-forced: ${[...fallbackFamilies].join(', ')})` : ''}\n` +
		`trainer avatar files: ${avatarFiles.length}\n` +
		`built: ${new Date().toISOString()}\n`
	);
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
