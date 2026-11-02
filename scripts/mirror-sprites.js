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
 * This script only ever fetches from the real CDN and writes into the
 * local static tree -- it can't do anything about references that never
 * even try the local copy in the first place. A few of those exist too:
 * some of style/client2.css and style/sim-types.css's `url(...)`s (the
 * two stylesheets testclient-new.html actually loads) are hardcoded
 * *absolute* `https://play.pokemonshowdown.com/...` URLs rather than
 * relative ones, and js/panel-popups.js (built from panel-popups.tsx) has
 * one hardcoded the same way for the registration-form captcha image --
 * both bypass local serving entirely regardless of what this script
 * mirrors. Those are fixed by patches/showdown-client-css-fixes.patch and
 * a build-script-level string replacement respectively (see
 * 30-showdown-client.sh) -- not by anything in this file.
 *
 * Mirrored:
 *   - sprite sheets: pokemon icons, pokeball icons, item icons, AND
 *     trainers-sheet.png -- these are each ONE image file covering every
 *     species/item/avatar (cheap). trainers-sheet.png specifically backs
 *     the avatar-*picker* grid (.avatarlist button in style/client.css,
 *     populated by client-topbar.js) -- a different code path from the
 *     individual sprites/trainers/<name>.png files below, which are what
 *     an already-chosen avatar actually renders as. Missing this one
 *     doesn't 404 anyone's avatar, it just leaves the "change avatar"
 *     dialog blank. Confirmed missing from every earlier version of this
 *     script (only the three non-trainer sheets were ever listed).
 *   - type icons (sprites/types/, used by Dex.getTypeIcon() -- move
 *     types, tooltips, the battle log) + Tera-type icons + category
 *     icons, AND, separately, sprites/typeicons/ -- a *different*
 *     directory, same types minus the neutral/unknown '???' one (no
 *     .typeicon-??? CSS rule exists for it), used by the
 *     dedicated `typeicon`/`typeicon-<Type>` CSS classes
 *     (style/sim-types.css) that the newer Preact `TypeIcon`-style
 *     component in src/panels.tsx renders (`typeicon typeicon-${type}`).
 *     Confirmed by grepping the actual client source, not assumed from
 *     the similar name -- sprites/types/ and sprites/typeicons/ are two
 *     genuinely separate CDN paths and mirroring one does not cover the
 *     other.
 *   - a handful of small, fixed, non-species image files that specific
 *     UI/battle code hardcodes a literal path for (found by grepping
 *     src/*.ts for literal and template-literal `sprites/...` paths, the
 *     same way the trainer-avatar gap above was originally found):
 *       - sprites/ani/substitute.gif + sprites/ani-back/substitute.gif --
 *         the Substitute-doll sprite battle-animations.ts draws for
 *         every use of the move Substitute, every battle. Not tied to
 *         any species, so buildSpeciesFileList() never generates it.
 *       - sprites/misc/mega.png, sprites/misc/alpha.png,
 *         sprites/misc/omega.png -- the small badge battle-animations.ts
 *         overlays on a Pokemon's HP bar name for Mega Evolution /
 *         Primal Reversion (`symbol` in getPokemonName()'s source,
 *         values verified directly from that function's own if/else --
 *         it's exactly these three, nothing else).
 *       - sprites/afd/meloetta.png, sprites/afd/meloetta-pirouette.png,
 *         sprites/afd/digimonbg.jpg -- April Fools' Day art. Genuinely
 *         code-gated (Dex.afdMode / client-main.ts's setAFD(), not dead
 *         code), just rare to trigger outside of April 1st, so mirrored
 *         for completeness but lowest priority of this batch.
 *       - fx/mail.png, fx/item.png -- small icons battle-animations.ts
 *         draws next to a Pokemon's name in the battle log whenever it's
 *         holding a Mail or a (non-Mail) item. Shown in most battles.
 *       - fx/client-bgsheet.png -- the picker-thumbnail spritesheet for
 *         PSBackground's (client-core.ts) "change background" dialog
 *         (style/client2.css's .bglist button span, a *relative*
 *         ../fx/... URL -- unlike the sheets below, this one was never
 *         broken by the CSS bug patches/showdown-client-css-fixes.patch
 *         fixes, it was just never mirrored at all).
 *       - the fx/ effect-sprite table (BattleEffects in
 *         battle-animations.ts): 58 small hit/impact/status images
 *         (fireballs, slashes, wisps, etc.) that back the large majority
 *         of move animations, in every battle. Extracted by parsing every
 *         `url: '...'` entry in that table, not guessed at -- see
 *         FX_EFFECT_FILES below for the exact list and how its boundary
 *         was verified. Entries in that table with no `url` at all
 *         (procedural/CSS-only effects) are correctly excluded, matching
 *         the `if (!BattleEffects[id].url) continue;` skip
 *         battle-animations.ts's own setup code already does.
 *       - PSBackground's (client-core.ts) 4 selectable "Official"
 *         fx/client-bg-<theme>.jpg background themes (CLIENT_BG_THEMES
 *         below) -- this is the *entire app's* background image, not
 *         battle-specific, and defaults to a random one of these four for
 *         every user who hasn't chosen a background before. Previously
 *         entirely unmirrored, meaning the whole app had a broken
 *         background by default for every single user.
 *       - the full default (gen6+) random battle-backdrop set
 *         (BATTLE_BACKDROPS below, sprites/gen6bgs/*.jpg) -- every
 *         default-format battle picks one of these at random
 *         (battle-animations.ts), not just the two specific ones a couple
 *         of move animations switch to (bg-icecave.jpg/bg-earthycave.jpg,
 *         which are also both members of this same array, so they're
 *         subsumed here rather than separately listed). An earlier
 *         version of this script only had those two of the full 19,
 *         meaning ~17 of 19 possible default battle backgrounds 404'd.
 *       - the equivalent old-gen (graphicsGen <= 5) backdrop sets --
 *         BATTLE_BACKDROPS_THREE/FOUR/FIVE plus the two single fixed
 *         gen1/gen2 files -- reachable via the same bwgfx pref (forces
 *         graphicsGen to 5) or an actual old-gen battle format.
 *       - FX_TOUR_BACKDROPS: backdrops gated on a rated battle's tour
 *         name (Smogon Premier League/NPA/World Cup/Smogon Champions
 *         League) -- realistically unreachable here (needs live
 *         ladder/tournament data this offline build has no source for),
 *         but a small, fully-enumerable fixed list straight out of
 *         battle-animations.ts's own if/else chain, so mirrored anyway.
 *       - sprites/gen6bgs/bg-icecave.jpg, bg-earthycave.jpg -- fixed
 *         battle-background images a couple of specific move animations
 *         (battle-animations-moves.ts) switch the field to. (Now folded
 *         into BATTLE_BACKDROPS above, since both are members of that
 *         same array -- kept here only as a pointer for anyone grepping
 *         for these two filenames specifically.)
 *     NOT mirrored from that same grep pass: the per-ladder-rank badge
 *     icons battle-animations.ts also references as
 *     sprites/misc/<formatType>_<type>.png -- unlike the three above,
 *     that filename is built from live ladder data (side.badges) this
 *     offline build has no source for, and the set of possible
 *     formatType/type combinations isn't small/fixed the way mega/alpha/
 *     omega is, so there's nothing concrete yet to add to the file list
 *     here. Revisit if this build ever gets real ladder data.
 *   - **field-condition overlays**: weather (Sun/Rain/Sandstorm/Hail-Snow/
 *     Strong Winds), the four terrains (Electric/Grassy/Misty/Psychic), and
 *     the three "room" moves (Trick Room, Magic Room, Wonder Room) plus
 *     Gravity -- 13 fx/weather-*.{jpg,png} files (FX_FIELD_CONDITION_FILES
 *     below). These are a genuinely different code path from the fx/
 *     hit-effect sprites just above: addWeather()/updateWeather() never
 *     constructs a `new Sprite(BattleEffects.xyz, ...)` for these, it just
 *     swaps a CSS class (e.g. `raindanceweather`, `trickroomweather`) on a
 *     persistent overlay div, and style/battle.css is what actually
 *     supplies each class's background-image -- so grepping
 *     battle-animations.ts's `url:` table (how the fx/ list above was
 *     built) could never have found these; they were completely unmirrored
 *     before, meaning weather/terrain/Trick Room-and-friends showed as a
 *     blank overlay (just the status text) in every battle. Confirmed by
 *     grepping style/battle.css directly for every `url(../fx/weather-...)`
 *     rule. Unlike the client2.css/sim-types.css bugs
 *     showdown-client-css-fixes.patch fixes, battle.css's URLs here are
 *     already host-relative (`../fx/...`), so no patch is needed, only
 *     mirroring. (Hazard/screen sprites -- Spikes, Stealth Rock, Toxic
 *     Spikes, Sticky Web, G-Max Steel Surge -- *do* go through
 *     BattleEffects and were already covered by the fx/ list above; Reflect/
 *     Light Screen/Aurora Veil/Safeguard/Mist are CSS-only `rawHTML`
 *     entries in that same table with no image at all, so correctly need
 *     nothing mirrored for them either.)
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
 *     (see the fetching section below -- 404s are re-checked slowly before
 *     being reported as genuinely missing) either way.
 *   - old-gen (gen1-gen4) per-species static sprites, for every species
 *     that could actually appear in a battle of that generation
 *     (speciesGenFor() below <= that gen). getSpriteData() picks these
 *     directories via `graphicsGen` -- which defaults to the *battle's*
 *     own generation (`mechanicsGen`/options.gen), not a client
 *     preference -- whenever that's 4 or below, no animation is ever
 *     attempted for gen1-4 (the `spriteData.gen >= 5` guard), and gen1
 *     specifically never gets a '-shiny' variant (shiny didn't exist yet;
 *     `if (options.shiny && mechanicsGen > 1)`). This build's own
 *     start-showdown launcher exposes `--format`, passed straight through
 *     to foul-play as `--pokemon-format` with no gen restriction (see
 *     40-launchers-and-cleanup.sh) -- so an old-gen format (e.g. `--format
 *     gen3ou`) is a first-class, documented, one-flag way to reach these,
 *     not a theoretical edge case, and skipping them would break sprites
 *     for anyone who uses that flag for its stated purpose.
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
 *   - team-builder-only preview sprites (home-centered/dex/xydex
 *     directories -- used only while building a team, not during battle)
 *   - per-ladder-rank badge icons (sprites/misc/<formatType>_<type>.png,
 *     see the NOT-mirrored note further up) -- needs live ladder data
 *     this build has no source for
 */

const fs = require('node:fs');
const path = require('node:path');
const { setTimeout: sleep } = require('node:timers/promises');

// MIRROR_CDN_URL exists so the retry/rate-limit handling below can be tested against a local
// mock server; nothing in the real build sets it.
const CDN = (process.env.MIRROR_CDN_URL || 'https://play.pokemonshowdown.com').replace(/\/+$/, '');
const OUT_DIR = process.argv[2];
const CONCURRENCY = Number(process.env.MIRROR_CONCURRENCY || 8);
// Per-attempt deadline for a single fetch (not the retry loop as a whole --
// each of the 3 attempts in downloadOne gets its own fresh FETCH_TIMEOUT_MS).
// Not exposed as an env var like MIRROR_CONCURRENCY: this is a correctness
// backstop (turn a hang into a retryable failure), not a knob anyone should
// need to tune for a given run the way concurrency legitimately is.
const FETCH_TIMEOUT_MS = 30_000;

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

// Exact algorithm copied from battle-dex-data.ts's Species constructor's
// `this.gen` fallback (data/pokedex.js has NO 'gen' field for the
// overwhelming majority of entries -- confirmed directly: only 166/1517,
// almost all cosmetic alt-formes -- so this num-range-based inference is
// what the client actually runs for essentially every species, not an
// edge case). Verified against 20 hand-picked species spanning gen1-9,
// megas, and a primal, all matching known real gens exactly. A handful
// of cosmetic-only formes (Burmy/Shellos/Deerling/Vivillon color
// variants) have no 'num' at all and resolve to 0 here, same as the real
// client -- deliberately not treated as "old" by hasOldGenArt() below,
// since spriteData.gen = Math.max(graphicsGen, Math.min(0, 5)) is just
// graphicsGen unconditionally for them, i.e. they behave as if this
// per-species capping doesn't apply at all, in every generation.
function speciesGenFor(id, data) {
	if (typeof data.gen === 'number' && data.gen) return data.gen;
	const num = data.num || 0;
	const baseSpecies = data.baseSpecies || data.name;
	const forme = data.forme || '';
	const baseId = toID(baseSpecies);
	const formeid = baseId === id ? '' : '-' + toID(forme);
	const isMega = !!(forme && formeid.includes('mega'));
	const isPrimal = !!(forme && formeid === '-primal');

	if (num >= 906 || formeid.startsWith('-paldea')) return 9;
	if (num >= 810 || formeid.startsWith('-galar') || formeid.startsWith('-hisui')) return 8;
	if (num >= 722 || formeid === '-alola' || formeid === '-starter') return 7;
	if (isMega || isPrimal) return 6;
	if (formeid === '-totem' || formeid === '-alolatotem') return 7;
	if (num >= 650) return 6;
	if (num >= 494) return 5;
	if (num >= 387) return 4;
	if (num >= 252) return 3;
	if (num >= 152) return 2;
	if (num >= 1) return 1;
	return 0;
}

const STATIC_SPECIES_SPRITE_DIRS = ['gen5', 'gen5-back', 'gen5-shiny', 'gen5-back-shiny'];

// getSpriteData()'s old-gen (1-4) static directories: `dir = (baseDir ||
// 'gen5') + dir;` with baseDir = ['', 'gen1', 'gen2', 'gen3', 'gen4',
// 'gen5', '', '', '', ''][spriteData.gen] -- picked whenever the battle's
// own generation (not a client pref) is 1-4. No animation is ever
// attempted for these (getSpriteData()'s `spriteData.gen >= 5` guard), and
// gen1 never gets a shiny variant (`if (options.shiny && mechanicsGen >
// 1)`) since Shiny didn't exist in Gen 1.
const OLD_GEN_STATIC_DIRS = {
	1: ['gen1', 'gen1-back'],
	2: ['gen2', 'gen2-back', 'gen2-shiny', 'gen2-back-shiny'],
	3: ['gen3', 'gen3-back', 'gen3-shiny', 'gen3-back-shiny'],
	4: ['gen4', 'gen4-back', 'gen4-shiny', 'gen4-back-shiny'],
};

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

// sprites/typeicons/ has no icon for the neutral/unknown '???' type (no
// .typeicon-??? rule exists in style/sim-types.css, unlike sprites/types/
// which does get a '???.png' via the TYPES loop below) -- confirmed by
// grepping sim-types.css for the exact set of typeicon-<Type> classes it
// defines, rather than assumed from sprites/types/'s file list.
const TYPEICON_TYPES = TYPES.filter((t) => t !== '???');

// Every image battle-animations.ts's BattleEffects table can turn into a
// `Dex.fxPrefix + url` request (fx/<file>.png) -- these back the small
// hit/impact/status graphics (fireballs, slashes, wisps, etc.) that
// virtually every move animation uses, in every battle. Extracted by
// grepping every `url: '...'` in that table (confirmed count: 58, boundary
// double-checked against the object literal's own opening/closing braces
// so nothing past its end got swept in). A handful of BattleEffects
// entries have no `url` at all (procedural/CSS-only effects) and are
// correctly absent from this list, matching the `if
// (!BattleEffects[id].url) continue;` skip in battle-animations.ts's own
// setup code.
const FX_EFFECT_FILES = [
	'alpha.png', 'angry.png', 'blackwisp.png', 'bluefireball.png', 'bone.png',
	'bottombite.png', 'caltrop.png', 'electroball.png', 'energyball.png',
	'feather.png', 'fireball.png', 'fist.png', 'fist1.png', 'flareball.png',
	'foot.png', 'gear.png', 'greenmetal1.png', 'greenmetal2.png', 'heart.png',
	'hitmarker.png', 'iceball.png', 'icicle-pink.png', 'icicle.png',
	'impact.png', 'leaf1.png', 'leaf2.png', 'leftchop.png', 'leftclaw.png',
	'leftslash.png', 'lightning.png', 'mistball.png', 'moon.png',
	'mudwisp.png', 'omega.png', 'petal.png', 'pointer.png',
	'poisoncaltrop.png', 'poisonwisp.png', 'pokeball.png', 'rainbow.png',
	'rightchop.png', 'rightclaw.png', 'rightslash.png', 'rock1.png',
	'rock2.png', 'rock3.png', 'rocks.png', 'shadowball.png', 'shell.png',
	'shine.png', 'stare.png', 'sword.png', 'topbite.png', 'ultra.png',
	'waterwisp.png', 'web.png', 'wisp.png', 'z-symbol.png',
];
// Hazards/screens (stealth rock, spikes, toxic spikes, sticky web, mist,
// reflect, light screen, aurora veil, safeguard, gmax steel surge) are
// covered above -- those all go through BattleEffects, so the FX_EFFECT_FILES
// grep already catches every one that has a real image (the rest, like
// reflect/lightscreen/mist/safeguard/auroraveil, are CSS-only `rawHTML`
// entries in that same table with no `url` at all, confirmed by reading each
// entry directly, so correctly absent here too).
//
// Weather, terrain, and the three "room" moves are a *different* code path
// and were completely missed by every earlier version of this script: they
// never go through BattleEffects (no `.weather`-div sprite is ever
// constructed with `new Sprite(BattleEffects.xyz, ...)` for these), so
// grepping battle-animations.ts's `url:` table -- how FX_EFFECT_FILES above
// was built -- cannot find them. Instead, addWeather()/updateWeather() (see
// this.$weather/this.$terrain in battle-animations.ts) just swap the CSS
// class on a persistent overlay div (e.g. `raindanceweather`,
// `electricterrainweather`, `trickroomweather`), and style/battle.css is
// what actually supplies each class's background-image -- confirmed by
// grepping battle.css directly for every `url(../fx/weather-...)` rule.
// Unlike the client2.css/sim-types.css bugs showdown-client-css-fixes.patch
// fixes, these are already host-relative (`../fx/...`, not an absolute
// `https://play.pokemonshowdown.com/...`), so no patch is needed here --
// they just need to actually be mirrored, which this list does.
const FX_FIELD_CONDITION_FILES = [
	// weather
	'weather-sunnyday.jpg', 'weather-raindance.jpg', 'weather-sandstorm.png',
	'weather-hail.png', 'weather-strongwind.png',
	// terrain
	'weather-mistyterrain.png', 'weather-electricterrain.png',
	'weather-grassyterrain.png', 'weather-psychicterrain.png',
	// room effects (Gravity, Magic Room, Trick Room, Wonder Room)
	'weather-gravity.png', 'weather-magicroom.png', 'weather-trickroom.png',
	'weather-wonderroom.png',
];

// PSBackground's (client-core.ts) four selectable "Official" background
// themes -- this is the *entire app's* background image, not
// battle-specific, and picks one of these four at random by default for
// every user who hasn't explicitly chosen one (or "solidblue", a CSS
// color with no image; or "custom", a user-uploaded data URL with no
// fixed file; or the April Fools' "digimon" one, which actually loads
// sprites/afd/digimonbg.jpg instead of this fx/client-bg-*.jpg pattern --
// already mirrored above). Confirmed exhaustive against the "Official"
// section of the actual background-picker UI (panel-popups.tsx's
// BackgroundListPanel), not just the default-random-pick array, since
// those two lists could in principle have drifted apart.
const CLIENT_BG_THEMES = ['charizards', 'horizon', 'ocean', 'shaymin'];

// battle-animations.ts's non-default-gen6+ battle backdrops: old-gen
// formats (graphicsGen <= 5, reachable via the "2D sprites"/bwgfx pref
// forcing graphicsGen to 5, or an actual old-gen battle format) pick a
// backdrop from one of these three arrays instead of BATTLE_BACKDROPS
// below, and gen1/gen2 use a single fixed file each rather than a random
// array.
const BATTLE_BACKDROPS_OLD_GEN = ['bg-gen1.png', 'bg-gen2.png'];
const BATTLE_BACKDROPS_THREE = [
	'bg-gen3.png', 'bg-gen3-cave.png', 'bg-gen3-ocean.png', 'bg-gen3-sand.png',
	'bg-gen3-forest.png', 'bg-gen3-arena.png',
];
const BATTLE_BACKDROPS_FOUR = [
	'bg-gen4.png', 'bg-gen4-cave.png', 'bg-gen4-snow.png', 'bg-gen4-indoors.png',
	'bg-gen4-water.png',
];
const BATTLE_BACKDROPS_FIVE = [
	'bg-beach.png', 'bg-beachshore.png', 'bg-desert.png', 'bg-meadow.png',
	'bg-thunderplains.png', 'bg-city.png', 'bg-earthycave.png', 'bg-mountain.png',
	'bg-volcanocave.png', 'bg-dampcave.png', 'bg-forest.png', 'bg-river.png',
	'bg-deepsea.png', 'bg-icecave.png', 'bg-route.png',
];
// Rated-battle-with-a-specific-tour-name backdrops (SPL/NPA/WCOP/SCL) --
// gated on `battle.rated` starting with one of those tournament name
// strings, which is live server/ladder data this offline build has no
// source for, so realistically unreachable here -- mirrored anyway since
// it's a small, fully-enumerable, fixed list (battle-animations.ts's own
// if/else chain), not the open-ended per-ladder-badge case that's still
// deliberately skipped further down.
const FX_TOUR_BACKDROPS = [
	'bg-gen1-spl.png', 'bg-gen2-spl.png', 'bg-gen3-spl.png', 'bg-gen4-spl.png',
	'bg-spl.png', 'bg-npa.png', 'bg-wcop.png', 'bg-scl.png',
];

// battle-animations.ts's default (gen6+) random battle backdrop -- picked
// for literally every battle in the current/default generation (i.e. the
// overwhelmingly common case), *not* just the two backdrops a couple of
// specific move animations switch to (bg-icecave.jpg/bg-earthycave.jpg,
// both of which are members of this same array, so they're subsumed here
// rather than separately listed -- see the doc comment up top). An
// earlier version of this script only had those two of the full 19,
// meaning ~17 of 19 possible default battle backgrounds were unmirrored.
const BATTLE_BACKDROPS = [
	'bg-aquacordetown.jpg', 'bg-beach.jpg', 'bg-city.jpg', 'bg-dampcave.jpg',
	'bg-darkbeach.jpg', 'bg-darkcity.jpg', 'bg-darkmeadow.jpg', 'bg-deepsea.jpg',
	'bg-desert.jpg', 'bg-earthycave.jpg', 'bg-elite4drake.jpg', 'bg-forest.jpg',
	'bg-icecave.jpg', 'bg-leaderwallace.jpg', 'bg-library.jpg', 'bg-meadow.jpg',
	'bg-orasdesert.jpg', 'bg-orassea.jpg', 'bg-skypillar.jpg',
];

function buildFixedFileList() {
	const files = [
		'sprites/pokemonicons-sheet.png',
		'sprites/pokemonicons-pokeball-sheet.png',
		'sprites/itemicons-sheet.png',
		'sprites/trainers-sheet.png',
		'sprites/ani/substitute.gif',
		'sprites/ani-back/substitute.gif',
		'sprites/misc/mega.png',
		'sprites/misc/alpha.png',
		'sprites/misc/omega.png',
		'sprites/afd/meloetta.png',
		'sprites/afd/meloetta-pirouette.png',
		'sprites/afd/digimonbg.jpg',
		'fx/mail.png',
		'fx/item.png',
		'fx/client-bgsheet.png',
	];
	for (const t of TYPES) {
		files.push(`sprites/types/${encodeURIComponent(t)}.png`);
		files.push(`sprites/types/Tera${encodeURIComponent(t)}.png`);
	}
	for (const t of TYPEICON_TYPES) {
		files.push(`sprites/typeicons/${encodeURIComponent(t)}.png`);
	}
	for (const c of CATEGORIES) files.push(`sprites/categories/${c}.png`);
	for (const f of FX_EFFECT_FILES) files.push(`fx/${f}`);
	for (const f of FX_FIELD_CONDITION_FILES) files.push(`fx/${f}`);
	for (const theme of CLIENT_BG_THEMES) files.push(`fx/client-bg-${theme}.jpg`);
	for (const f of BATTLE_BACKDROPS) files.push(`sprites/gen6bgs/${f}`);
	for (const f of BATTLE_BACKDROPS_OLD_GEN) files.push(`fx/${f}`);
	for (const f of BATTLE_BACKDROPS_THREE) files.push(`fx/${f}`);
	for (const f of BATTLE_BACKDROPS_FOUR) files.push(`fx/${f}`);
	for (const f of BATTLE_BACKDROPS_FIVE) files.push(`fx/${f}`);
	for (const f of FX_TOUR_BACKDROPS) files.push(`fx/${f}`);
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
	// present for a spriteid if any of its raw ids has it. Also tracks the
	// *lowest* speciesGenFor() among those raw ids, for old-gen mirroring
	// below -- lowest because that's the earliest generation this spriteid
	// could actually need old-gen-specific art for (Math.min(species.gen,
	// 5) <= N is true, i.e. this dir is reachable, iff at least one raw id
	// has gen <= N).
	const rawIdsBySpriteid = new Map();
	let minGenBySpriteid = new Map();
	for (const id of Object.keys(pokedex)) {
		const spriteid = spriteIdFor(id, pokedex[id]);
		if (!rawIdsBySpriteid.has(spriteid)) rawIdsBySpriteid.set(spriteid, []);
		rawIdsBySpriteid.get(spriteid).push(id);

		const gen = speciesGenFor(id, pokedex[id]);
		const prevMin = minGenBySpriteid.get(spriteid);
		if (gen > 0 && (prevMin === undefined || gen < prevMin)) {
			minGenBySpriteid.set(spriteid, gen);
		}
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

		// Old-gen (1-4) static sprites -- only for spriteids that could
		// actually appear in a battle of that generation (see
		// minGenBySpriteid above). undefined here means every raw id
		// mapping to this spriteid resolved to gen 0 (the
		// no-'num'-at-all cosmetic-forme edge case in speciesGenFor's own
		// comment) -- those don't get old-gen treatment at all, matching
		// how they behave in the real client (see that comment).
		const minGen = minGenBySpriteid.get(spriteid);
		if (minGen !== undefined) {
			for (let n = 1; n <= 4; n++) {
				if (minGen > n) continue;
				for (const dir of OLD_GEN_STATIC_DIRS[n]) {
					files.push(`sprites/${dir}/${spriteid}.png`);
				}
				if (n === 4 && hasStaticFrontFemaleVariant(rawIds, dicts, fallbackFamilies)) {
					files.push(`sprites/gen4/${spriteid}-f.png`);
					files.push(`sprites/gen4-shiny/${spriteid}-f.png`);
				}
			}
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

// ---------------------------------------------------------------------------
// Fetching: rate-limit handling, retries, and honest classification.
//
// Every file ends up in exactly one of four buckets, and the log distinguishes
// them because they mean very different things:
//   - downloaded / skipped: we have the file.
//   - confirmed missing: the CDN said 404 on the main pass AND again on a slow,
//     low-concurrency re-check (see resolveSuspects()). This is the only
//     bucket that means "doesn't exist on the CDN".
//   - NOT fetched: we never got a usable answer (HTTP 429/5xx, timeouts, a
//     challenge/error page served instead of an image, ...), even after
//     retrying. Says nothing about whether the file exists. The build is
//     missing it, and that's reported as such -- never as "doesn't exist".
//
// Why 404s get a second look: the CDN is entitled to rate limit us (we make
// thousands of requests), and a limiter or an edge in front of it isn't
// obliged to say so with a 429 -- a "not found" under load is not something
// we can rule out from here. Re-requesting suspected-404 files slowly, once
// the burst is over, separates "really absent" from "we were being throttled".
// ---------------------------------------------------------------------------

const MAX_ATTEMPTS = 6;
const BACKOFF_BASE_MS = 500;
const BACKOFF_CAP_MS = 60_000;
const DEFAULT_RATE_LIMIT_PAUSE_MS = 2_000;
// The re-check pass is deliberately gentle: it exists to get an answer from
// the CDN while it is NOT being hammered, so it must not hammer it itself.
const RECHECK_CONCURRENCY = Math.max(1, Number(process.env.MIRROR_RECHECK_CONCURRENCY || 2));
// Re-check every suspected-404 up to this many; above it, re-check a random
// sample first and only do the rest if the sample shows 404s were bogus.
// (Brute-force fallback mode legitimately produces thousands of real 404s.)
const RECHECK_FULL_LIMIT = 1500;
const RECHECK_SAMPLE_SIZE = 300;
const MAX_LISTED = 50;
// Circuit breaker: if this many of the last BREAKER_WINDOW files failed outright
// (each after all of its retries), the CDN is down or has blocked us -- individual
// files aren't just unlucky. Stop spending ~15s of retries per remaining file; the
// rest are marked not-fetched immediately and get one slow re-check afterwards.
// A sliding window rather than "N in a row" so failures interleaved with
// successes (a partial block) trip it too.
const BREAKER_WINDOW = 40;
const BREAKER_TRIP = 16;
// Fraction of files allowed to end up not fetched before the build aborts.
const MAX_FAILURE_RATE = 0.05;
const IMAGE_EXT = /\.(png|gif|jpe?g|webp)$/i;

// Shared across every in-flight request so one 429 slows *everyone* down
// rather than each worker finding out for itself. Concurrency is cut in half
// when the CDN pushes back (AIMD) and creeps back up after a run of successes.
const throttle = {
	limit: CONCURRENCY,
	active: 0,
	pausedUntil: 0,
	successStreak: 0,
	lastCutAt: 0,
	rateLimitHits: 0,
	lowestLimit: CONCURRENCY,
	lastLoggedAt: 0,
	recent: [],       // last BREAKER_WINDOW final outcomes: true = failed outright
	giveUp: false,
	// Set once the file list is known: how many files may end up not fetched
	// before the build is going to abort anyway (see main()). Infinity until then.
	failBudget: Infinity,

	async acquire() {
		for (;;) {
			const wait = this.pausedUntil - Date.now();
			if (wait > 0) {
				await sleep(wait);
				continue;
			}
			if (this.active < this.limit) {
				this.active++;
				return;
			}
			await sleep(25);
		}
	},

	release() {
		this.active--;
	},

	noteRateLimited(what, retryAfterMs) {
		this.rateLimitHits++;
		this.successStreak = 0;
		const now = Date.now();
		const pause = Math.min(retryAfterMs ?? DEFAULT_RATE_LIMIT_PAUSE_MS, BACKOFF_CAP_MS);
		this.pausedUntil = Math.max(this.pausedUntil, now + pause);
		// A burst of N simultaneous 429s is one event, not N: only cut once
		// per couple of seconds, otherwise we'd collapse straight to 1.
		if (now - this.lastCutAt > 2_000) {
			this.lastCutAt = now;
			const before = this.limit;
			this.limit = Math.max(1, Math.floor(this.limit / 2));
			// Log the first event, any new low, and otherwise at most every 10s --
			// a long throttled stretch would otherwise be one line per cut.
			const newLow = this.limit < this.lowestLimit;
			this.lowestLimit = Math.min(this.lowestLimit, this.limit);
			if (newLow || now - this.lastLoggedAt > 10_000) {
				this.lastLoggedAt = now;
				console.warn(`  rate limited by CDN (${what}) -- pausing ${(pause / 1000).toFixed(1)}s, ` +
					`concurrency ${before} -> ${this.limit}`);
			}
		}
	},

	noteFileOutcome(failed) {
		this.recent.push(failed);
		if (this.recent.length > BREAKER_WINDOW) this.recent.shift();
		const failures = this.recent.filter(Boolean).length;
		if (failures >= BREAKER_TRIP && !this.giveUp) {
			this.giveUp = true;
			console.error(`  ${failures} of the last ${this.recent.length} files failed outright -- the CDN looks down or is ` +
				`blocking us; not retrying the rest now (they get one slow re-check at the end)`);
		}
	},

	noteFileOk() {
		this.noteFileOutcome(false);
	},

	noteFileFailed() {
		this.noteFileOutcome(true);
	},

	noteSuccess() {
		this.noteFileOk();
		if (this.limit >= CONCURRENCY) return;
		if (++this.successStreak >= 25) {
			this.successStreak = 0;
			this.limit++;
		}
	},
};

function parseRetryAfter(header) {
	if (!header) return null;
	const secs = Number(header);
	if (Number.isFinite(secs)) return Math.max(0, secs * 1000);
	const date = Date.parse(header);
	if (!Number.isNaN(date)) return Math.max(0, date - Date.now());
	return null;
}

// One file, with retries. Never throws. Returns one of:
//   { outcome: 'ok', bytes }
//   { outcome: 'notfound' }                      -- the CDN answered 404
//   { outcome: 'failed', reason, rateLimited }   -- no usable answer
async function fetchOne(relPath) {
	const url = `${CDN}/${relPath}`;
	const dest = path.join(OUT_DIR, relPath);
	let lastReason = 'unknown error';
	let sawRateLimit = false;
	// A file's own retries back off locally; only its first rate-limited response
	// feeds the global throttle, or one stubborn file would pause and halve
	// everyone's concurrency once per attempt.
	let reportedToThrottle = false;

	if (throttle.giveUp) return { outcome: 'failed', reason: 'not attempted: CDN not responding', rateLimited: false };

	for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
		let retryAfterMs = null;
		await throttle.acquire();
		// Per-attempt deadline: a stalled connection doesn't reject fetch() on
		// its own, so without this one stuck request would occupy a slot
		// forever instead of counting as a retryable failure.
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
		try {
			const res = await fetch(url, {
				headers: { 'User-Agent': 'foul-play-ish-aok sprite mirror (build-time only)' },
				signal: controller.signal,
			});
			if (res.status === 404) {
				await res.arrayBuffer().catch(() => {});
				throttle.noteFileOk();
				return { outcome: 'notfound' };
			}
			if (!res.ok) {
				retryAfterMs = parseRetryAfter(res.headers.get('retry-after'));
				if (res.status === 429 || res.status === 503 || retryAfterMs !== null) {
					sawRateLimit = true;
					if (!reportedToThrottle) {
						reportedToThrottle = true;
						throttle.noteRateLimited(`HTTP ${res.status}`, retryAfterMs);
					}
				}
				await res.arrayBuffer().catch(() => {});
				throw new Error(`HTTP ${res.status}`);
			}
			// A 200 whose body is an HTML page where an image should be is a
			// challenge/error page, not the file. Writing it to foo.png would
			// "succeed" and leave a corrupt sprite behind.
			const contentType = res.headers.get('content-type') || '';
			if (IMAGE_EXT.test(relPath) && /^text\//i.test(contentType)) {
				sawRateLimit = true;
				if (!reportedToThrottle) {
					reportedToThrottle = true;
					throttle.noteRateLimited(`HTTP 200 but ${contentType} instead of an image`, null);
				}
				await res.arrayBuffer().catch(() => {});
				throw new Error(`got ${contentType} instead of an image (likely a rate-limit/challenge page)`);
			}

			const buf = Buffer.from(await res.arrayBuffer());
			fs.mkdirSync(path.dirname(dest), { recursive: true });
			// Write-then-rename so an interrupted run can't leave a truncated
			// file that the "already present" check would later trust.
			const tmp = `${dest}.part`;
			fs.writeFileSync(tmp, buf);
			fs.renameSync(tmp, dest);
			throttle.noteSuccess();
			return { outcome: 'ok', bytes: buf.length };
		} catch (err) {
			lastReason = err.name === 'AbortError' ? `timed out after ${FETCH_TIMEOUT_MS / 1000}s` : err.message;
			if (attempt === MAX_ATTEMPTS) break;
		} finally {
			clearTimeout(timeout);
			throttle.release(); // released before backing off so sleeping doesn't hold a slot
		}
		const base = retryAfterMs ?? BACKOFF_BASE_MS * 2 ** (attempt - 1);
		await sleep(Math.min(base, BACKOFF_CAP_MS) * (0.75 + Math.random() * 0.5));
	}
	throttle.noteFileFailed();
	return { outcome: 'failed', reason: lastReason, rateLimited: sawRateLimit };
}

// Main-pass wrapper. A 404 here is only a *suspect* -- see resolveSuspects().
async function downloadOne(relPath, stats) {
	const dest = path.join(OUT_DIR, relPath);
	if (fs.existsSync(dest) && fs.statSync(dest).size > 0) {
		stats.skipped++;
		return;
	}
	const r = await fetchOne(relPath);
	if (r.outcome === 'ok') {
		stats.downloaded++;
		stats.bytes += r.bytes;
	} else if (r.outcome === 'notfound') {
		stats.suspect404.push(relPath);
	} else {
		stats.failedItems.push({ relPath, reason: r.reason, rateLimited: r.rateLimited });
		// Failures needn't be consecutive to mean the run is doomed: if more
		// files have already failed than the build tolerates, retrying every
		// remaining unlucky file at ~15s apiece would only turn a fast abort
		// into a very slow one. Stop attempting new files now; everything
		// skipped (and everything failed) still gets the slow re-check below.
		if (stats.failedItems.length > throttle.failBudget && !throttle.giveUp) {
			throttle.giveUp = true;
			console.error(`  ${stats.failedItems.length} files have failed outright (more than the ${MAX_FAILURE_RATE * 100}% ` +
				`the build tolerates) -- not attempting the rest now; they get one slow re-check at the end`);
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
	return {
		downloaded: 0, skipped: 0, bytes: 0,
		suspect404: [],          // 404 on the main pass, not yet trusted
		failedItems: [],         // no usable answer on the main pass
		missingList: [],         // confirmed 404 on the slow re-check too
		recovered404: [],        // said 404 on the main pass, exist on re-check
		recoveredFailed: [],     // failed on the main pass, fetched on re-check
		failedFinal: [],         // still no usable answer after the re-check
	};
}

// Re-request `paths` slowly and sort them into recovered / still-404 / failed.
async function recheck(paths, stats) {
	const result = { recovered: [], notfound: [], failed: [] };
	await pool(paths, async (relPath) => {
		const r = await fetchOne(relPath);
		if (r.outcome === 'ok') {
			stats.downloaded++;
			stats.bytes += r.bytes;
			result.recovered.push(relPath);
		} else if (r.outcome === 'notfound') {
			result.notfound.push(relPath);
		} else {
			result.failed.push(`${relPath}: ${r.reason}`);
		}
	}, RECHECK_CONCURRENCY);
	return result;
}

function sample(arr, n) {
	const copy = arr.slice();
	for (let i = copy.length - 1; i > 0; i--) {
		const j = Math.floor(Math.random() * (i + 1));
		[copy[i], copy[j]] = [copy[j], copy[i]];
	}
	return copy.slice(0, n);
}

// Turns the main pass's suspects into final answers. After this, missingList
// holds only files the CDN said 404 for on a quiet re-check, and failedFinal
// holds only files we genuinely could not get an answer for.
async function resolveSuspects(stats) {
	// Files the breaker never even attempted go first: they haven't had a real try,
	// so if the CDN has recovered they should all succeed. The genuinely stuck ones
	// go last, so if THEY trip the breaker again it only skips files that were
	// going to fail anyway, rather than starving healthy ones queued behind them.
	const notAttempted = (f) => f.reason.startsWith('not attempted');
	const failedPaths = [...stats.failedItems]
		.sort((a, b) => Number(notAttempted(b)) - Number(notAttempted(a)))
		.map((f) => f.relPath);
	const total = stats.suspect404.length + failedPaths.length;
	if (total === 0) return;

	// Let any rate-limit window we caused expire before asking again.
	const cooldown = throttle.rateLimitHits ? 10_000 : 1_000;
	console.log(`Re-checking ${stats.suspect404.length} suspected-missing and ${failedPaths.length} unfetched ` +
		`files slowly (concurrency ${RECHECK_CONCURRENCY}) to tell "doesn't exist" from "was throttled"...`);
	await sleep(Math.max(cooldown, throttle.pausedUntil - Date.now()));
	// The breaker may have tripped during the main pass; the cooldown is exactly
	// the chance for the CDN to have recovered, so give it a clean slate.
	throttle.giveUp = false;
	throttle.recent = [];

	// Files that failed outright: try again; a 404 now means it's really absent.
	if (failedPaths.length) {
		const r = await recheck(failedPaths, stats);
		stats.recoveredFailed.push(...r.recovered);
		stats.missingList.push(...r.notfound);
		stats.failedFinal.push(...r.failed);
	}

	// Files the main pass reported as 404.
	let toCheck = stats.suspect404;
	let trusted = [];
	if (toCheck.length > RECHECK_FULL_LIMIT) {
		const probe = sample(toCheck, RECHECK_SAMPLE_SIZE);
		const probeSet = new Set(probe);
		const r = await recheck(probe, stats);
		stats.recovered404.push(...r.recovered);
		stats.missingList.push(...r.notfound);
		stats.failedFinal.push(...r.failed);
		if (r.recovered.length === 0) {
			// The sample says the 404s are genuine; don't re-ask for thousands more.
			trusted = toCheck.filter((p) => !probeSet.has(p));
			toCheck = [];
		} else {
			console.warn(`  ${r.recovered.length}/${probe.length} sampled "404" files actually exist -- ` +
				`re-checking all remaining suspected-missing files`);
			toCheck = toCheck.filter((p) => !probeSet.has(p));
		}
	}
	if (toCheck.length) {
		const r = await recheck(toCheck, stats);
		stats.recovered404.push(...r.recovered);
		stats.missingList.push(...r.notfound);
		stats.failedFinal.push(...r.failed);
	}
	stats.missingList.push(...trusted);
}

function listSome(lines, label) {
	const shown = lines.slice(0, MAX_LISTED);
	console.error(`${label}:`);
	for (const l of shown) console.error(`  ${l}`);
	if (lines.length > shown.length) console.error(`  ... and ${lines.length - shown.length} more`);
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
			if (!dicts[family.dictExport]) {
				// tryReadDict returns null for a missing/empty file. Treating that as
				// "this family has no art for anyone" would silently mirror zero
				// animated sprites for it -- e.g. when the fetch above was throttled.
				throw new Error('file could not be fetched');
			}
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
	throttle.failBudget = Math.floor(files.length * MAX_FAILURE_RATE);

	const start = Date.now();
	await pool(files, (f) => downloadOne(f, stats), CONCURRENCY);
	await resolveSuspects(stats);
	const seconds = ((Date.now() - start) / 1000).toFixed(1);

	const recovered = stats.recovered404.length + stats.recoveredFailed.length;
	console.log(`Done in ${seconds}s: ${stats.downloaded} downloaded, ${stats.skipped} already present, ` +
		`${(stats.bytes / 1024 / 1024).toFixed(1)} MiB fetched.`);
	console.log(`  ${stats.missingList.length} confirmed missing on CDN (404 on the main pass and again on a slow ` +
		`re-check -- expected, most species only have art in one animated family)`);
	if (recovered) {
		console.log(`  ${recovered} files were recovered by the re-check ` +
			`(${stats.recovered404.length} had been answered 404, ${stats.recoveredFailed.length} had failed) -- ` +
			`the CDN was throttling us, they do exist`);
	}
	if (throttle.rateLimitHits) {
		console.log(`  CDN rate limiting seen ${throttle.rateLimitHits} time(s); concurrency dipped to ` +
			`${throttle.lowestLimit} of ${CONCURRENCY}. Consider a lower MIRROR_CONCURRENCY.`);
	}
	if (stats.failedFinal.length) {
		console.error(`  ${stats.failedFinal.length} files NOT FETCHED (no usable response even after retrying) -- ` +
			`this does NOT mean they don't exist on the CDN, only that this build doesn't have them`);
		listSome(stats.failedFinal, 'Not fetched');
	}

	// A handful of unfetched files (network blips) are tolerable; a LOT of
	// them means something structural is wrong (CDN down/blocking us, no
	// network, concurrency far too high) and the build should stop rather
	// than ship a rootfs with mostly-broken sprites. Confirmed 404s are
	// "missing", not "not fetched", and are NOT subject to this budget --
	// they're an expected, unbounded outcome of mirroring two animated
	// families per species when most species only have art in one.
	// (+ the animation-metadata files, which are fetched separately from `files`)
	const totalFiles = files.length + ANIMATED_FAMILIES.length;
	const failureRate = stats.failedFinal.length / totalFiles;
	if (failureRate > MAX_FAILURE_RATE) {
		console.error(`error: ${stats.failedFinal.length}/${totalFiles} files could not be fetched ` +
			`(${(failureRate * 100).toFixed(1)}%) -- aborting` +
			(throttle.rateLimitHits ? ' (the CDN was rate limiting; retry with a lower MIRROR_CONCURRENCY)' : ''));
		process.exit(1);
	}

	fs.writeFileSync(
		path.join(OUT_DIR, 'SPRITE_MIRROR_INFO.txt'),
		`mirrored: ${stats.downloaded} files, ${(stats.bytes / 1024 / 1024).toFixed(1)} MiB\n` +
		`confirmed missing on CDN (404, re-checked): ${stats.missingList.length}\n` +
		`not fetched (rate limited / network errors, may exist on CDN): ${stats.failedFinal.length}\n` +
		`static species sprite dirs (default gen): ${STATIC_SPECIES_SPRITE_DIRS.join(', ')}\n` +
		`old-gen static sprite dirs: ${Object.values(OLD_GEN_STATIC_DIRS).flat().join(', ')}\n` +
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
