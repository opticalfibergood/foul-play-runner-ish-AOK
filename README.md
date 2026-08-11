# foul-play-ish-aok

CI that builds an Alpine Linux (aarch64) root filesystem containing:

- **[foul-play](https://github.com/pmariglia/foul-play)** -- a Pokémon
  Showdown battle AI -- with its `poke-engine` Rust extension pre-compiled
- **[pokemon-showdown](https://github.com/smogon/pokemon-showdown)** -- the
  real battle server -- patched to run **fully offline**, no login server,
  no internet
- **[pokemon-showdown-client](https://github.com/smogon/pokemon-showdown-client)**
  -- the real web client -- patched to load everything (sprites, data, the
  websocket connection) from the local server instead of the real CDN,
  with a bounded set of sprites/icons mirrored in at build time

...ready to import directly into [iSH-AOK](https://github.com/emkey1/ish-AOK):
run one command, open ish-AOK's built-in **Browser** tool, and play a real
Pokémon Showdown battle against the bot -- with zero internet access on
the device, and no build tools ever running on-device.

## Get the rootfs

1. Go to the [`rootfs-latest` release](../../releases/tag/rootfs-latest).
2. On your iPhone/iPad, download `foul-play-showdown-offline-aarch64-latest.tar.gz`
   (Safari will save it to the Files app).
3. In iSH-AOK: **Filesystems → Import (top right) → Files** and pick the
   `.tar.gz` you just downloaded.
4. Switch to it and run:

   ```sh
   start-showdown
   ```

5. Open ish-AOK's **Browser** workspace tool (not Safari -- same app
   process, so the server keeps running in the background while you're
   looking at the page) and go to `http://localhost:8000`. You'll already
   be logged in as `human`. Challenge `bot` -- it auto-accepts.

`start-showdown --help` lists options (`--port`, `--bot-mode`, `--format`,
`--no-bot`). Ctrl-C stops both the server and the bot. `--format` isn't
limited to the gen9 default -- `--format gen3ou`, `--format gen1ou`,
`--format gen9championsrandombattle`, etc. all play with the actually
correct battle mechanics (see "Old-gen and Champions battles" below).

`foul-play` still works completely unchanged on its own too (e.g. against
the real ladder, over the internet): `foul-play --help`.

**Updating:** there's no in-place updater on purpose (per the original
request this was built for -- simplicity first). Re-download the latest
release and import it again as a new filesystem in iSH-AOK.

## What "fully offline" actually required

This is not just "run `pokemon-showdown start` and hope." Five separate
things all independently assume the internet exists, and each needed its
own fix. All of this was verified directly against the real source (not
assumed) -- clone the two repos yourself and grep for the things named
below if you want to check.

1. **The server always phones home for login**, even for unregistered
   guest names, via a login server. Fixed with `noguestsecurity = true`
   (a real, documented config option -- see `config-example.js`), which
   config-loader.ts confirms is what lets a bare `/trn NAME` succeed with
   no login-server contact at all.
2. **The server forks subprocesses** for networking, battle simulation,
   team validation, etc, via `cluster.fork()`/`child_process.fork()`.
   Fixed with `subprocesses = 0`. This has to be the bare number, not an
   object like `{ network: 0 }` -- confirmed directly in
   `server/config-loader.ts`: every pool's worker count is read as
   `processCount[type] ?? 1`, so a partial object still leaves most pools
   at their default of 1. Only the bare `0` zeroes all eleven at once.
3. **The client's offline-fallback config still points at the real
   production server** (`sim3.psim.us`) and, less obviously, at the real
   CDN for every sprite/icon/resource (`Config.routes.client`). This
   second part isn't something a runtime script injection can fix --
   `Dex.resourcePrefix` is computed once, early, from that value, before
   any late-loaded script could change it. Fixed by patching the embedded
   fallback `Config` object in `testclient-new.html` directly, so it's
   correct from the moment the page starts loading.
4. **Actual sprite/icon image files aren't in the client's git repo at
   all** -- `play.pokemonshowdown.com/sprites/` in the real repo is
   effectively empty (a handful of directory-index PHP files). Fixed by
   mirroring a specific, bounded set of files from the real CDN at build
   time (see "Sprites and icons" below) -- this is the one piece of the
   offline story that has to happen over the network, and it happens in
   CI, never on-device.
5. **A handful of images are referenced by a hardcoded *absolute*
   `https://play.pokemonshowdown.com/...` URL**, in two loaded
   stylesheets (`style/client2.css`, `style/sim-types.css` -- the
   Meloetta AFD icons, the avatar-picker thumbnail sheet, and every type
   icon the newer `typeicon` component renders) and one compiled JS file
   (`js/panel-popups.js` -- the registration form's captcha image).
   Unlike everything mirror-sprites.js fetches, these never even *try*
   the local server, no matter what's mirrored -- so no amount of #4
   fixes this on its own. Fixed by
   `patches/showdown-client-css-fixes.patch` for the two stylesheets
   (source-patchable, applied the same way as
   `showdown-client-testclient.patch`) and a build-script `sed` for
   `panel-popups.js` (compiled from TypeScript, so can't be
   source-patched the same way -- see `30-showdown-client.sh`), both
   stripping the CDN host to leave a host-relative path.

The server also fixes up the browser's connection at runtime, via the
same `customhttpresponse` hook in `config.js`: once the client has
loaded, it corrects `PS.server.protocol` and forces an immediate
reconnect, then sends `/trn human` so there's no console command to type
-- `http://localhost:8000`, bare, just works. The protocol fix is needed
because of a genuine quirk in the client's own source: `PSServer`'s
`protocol` field is derived from `Config.defaultserver.httpport`'s
*truthiness* at construction time (`Config.defaultserver.httpport ?
'https' : 'http'`), while that same field is *also* used as the literal
port number for plain-`http` connections -- two contradictory
requirements from one input, so no static `Config` value gets both right
at once. `testclient-new.html`'s static patch alone leaves `protocol`
wrongly set to `'https'`, which tries to open a secure WebSocket against
a plain HTTP server and just sits on "Disconnected."

Fixing `protocol` alone isn't quite enough, though: the client's actual
connection logic runs inside a Web Worker
(`client-connection-worker.js`), and that worker's `connectToServer()`
no-ops (`if (socket) return`) while it's still holding a reference to
whatever connection attempt is already in flight -- and by the time our
injected script can possibly run (document order puts it after
everything else on the page), the page's own *first* connection attempt,
made with the wrong protocol, has already started. A plain
`PS.connection.reconnect()` call can get silently ignored for as long as
that stale, doomed-to-fail attempt takes to time out on its own -- which
is exactly the "tries for a bit, then gets stuck before retrying"
symptom this produced before the fix below. So the injected script also
explicitly tells the worker to drop the stale attempt
(`worker.postMessage({ type: 'disconnect' })`) *before* reconnecting;
worker `postMessage` calls are processed in the order they're sent, so
this is guaranteed to land before the follow-up `connect` message.

All of this was confirmed directly against the real source
(`client-main.ts`, `client-connection.ts`, `client-connection-worker.ts`)
and verified two ways: a raw `curl` WebSocket-upgrade probe against a
real running (patched) server confirming the server side was never the
problem (`101 Switching Protocols` with the correct
`Sec-WebSocket-Accept`), and a mock of the real `PS`/`PS.connection`
object confirming the injected script's actual call order --
`worker.postMessage('disconnect')` then `reconnect()` then `/trn
human` -- and resulting state.

## Old-gen and Champions battles (poke-engine variants)

Getting sprites/backgrounds right for old-gen battles (see below) turned
out not to be the whole story -- the bot itself couldn't actually *play*
them correctly.

`foul-play`'s battle AI calls into
[`poke-engine`](https://github.com/pmariglia/poke-engine), a separate
Rust project, to search through a battle. `poke-engine` picks its
generation's mechanics at **compile time**, not runtime: confirmed
directly against its own source (`Cargo.toml`'s `[features]` table has
`gen1`..`gen9`, `champions`, and `terastallization` -- which
`Cargo.toml` declares implies `gen9` -- and `src/lib.rs` has an
`assert_unique_feature!()` macro that's a hard `compile_error!` if more
than one of `gen2`..`gen9`/`champions` is enabled at once). A single
`pip install poke-engine --config-settings=...--features
poke-engine/X` can only ever produce an engine that plays generation
`X` -- which is exactly why upstream foul-play's own README has a whole
"Re-Installing the Engine" section on rebuilding it per generation, and
why its `requirements.txt` pins exactly one feature
(`terastallization`, i.e. gen9) by default.

Built the naive way, this rootfs would therefore only ever be able to
correctly play gen9 (and not even `[Gen 9 Champions]` formats, which
need the separate `champions` feature) -- `start-showdown --format
gen3ou` would connect and battle, but against a `poke-engine` that's
silently computing gen9 mechanics the whole time. Wrong results, not a
crash, since `poke-engine` has no way to know it was asked for the
wrong generation.

Fixed without touching a single line of foul-play's own source
(`scripts/chroot/10-foulplay.sh`, `/usr/local/bin/foul-play`): since
`poke-engine`'s Python package is self-contained (a pure-Python
`__init__.py` wrapping one compiled extension module, no other runtime
deps), the build installs it once per feature --
`gen1`..`gen8`, `terastallization` (gen9), and `champions` -- each into
its own directory under `poke-engine-variants/`, alongside the venv's
normal install. The `/usr/local/bin/foul-play` launcher (this build's
own wrapper, not foul-play's `run.py`) then parses whatever
`--pokemon-format` was actually passed, works out the matching
generation the same way foul-play's own `fp/format_spec.py` does (a
`gen([1-9]0?)` regex plus a literal `"champions"` substring check), and
prepends that one variant's directory onto `PYTHONPATH` before handing
off to `run.py` -- shadowing the venv's own default `poke-engine`
install for just that one process. `start-showdown --format gen3ou`,
`--format gen1ou`, `--format gen9championsrandombattle`, etc. all now
load the actually-correct engine. If a format can't be parsed for some
reason, it falls back to whatever `poke-engine` the venv has installed
by default -- the same behavior as before this fix, not a new failure
mode.

## Any format, no restart (the multi-format coordinator)

The variant-selection fix above still left one thing bolted to
`start-showdown`'s command line: `--format` picks one exact format
string, `foul-play`'s own `accept_challenge()` only ever accepts a
challenge that matches it exactly (`fp/websocket_client.py`:
`split_msg[5] == battle_format`), and `apply_mods()`
(`fp/data/mods/apply_mods.py`) mutates the process's in-memory
pokedex/movedex *downward* from gen9 defaults exactly once, with no way
back up -- so a single running `foul-play` process really can only ever
play one format for its entire life. Wanting to play a different format
meant restarting the whole `start-showdown` -- server included -- and
sitting through pokemon-showdown's own slow startup work all over again
(see "What 'fully offline' actually required" above for why that's not
quick on real iSH-AOK hardware).

Confirmed directly (a second connection can't just also log in as
`bot` and wait its turn -- tried it against a real local server with
`noguestsecurity` on: the second `/trn bot` gets a flat `nametaken`,
regardless), so running one already-logged-in `foul-play` process per
generation side by side, all answering to the same name, isn't an
option either.

`start-showdown` (when `--bot-mode` is left at its default
`accept_challenge` *and* `--format` is omitted) now instead starts
`multiformat/coordinator.py`, not `foul-play` directly. It logs in to
Pokemon Showdown exactly **once**, as `bot`, and holds that one
connection open for as long as `start-showdown` runs. For each
challenge, whatever format it names:

1. Works out the generation (and so which `poke-engine-variants/`
   directory it needs) and whether the tier needs a real team, using
   the same rules described above and the same `requires_team` flags
   `fp/modes/*.py` already define.
2. If a team's needed but none exists for that exact format under
   `fp/teams/teams/`, or the generation has no poke-engine variant
   built, sends `/reject` and a short explanatory whisper, then keeps
   waiting -- the same failure `--format <that format>` would already
   hit today, just discovered per-challenge instead of at startup, and
   with the challenger actually told, rather than a warning landing on
   a console they were never watching.
3. Otherwise sends `/utm` and `/accept` itself, then hands the battle
   to a `multiformat/worker.py` subprocess -- spawned with exactly the
   PYTHONPATH trick above pointed at the right variant, and reused
   as-is for the next battle if it's the same generation, replaced if
   not. The worker never opens its own websocket at all: it plays the
   battle via `fp.run_battle.pokemon_battle()` -- foul-play's own,
   completely unmodified -- against a small stand-in for
   `PSWebsocketClient` that reads/writes JSON lines on `stdin`/`stdout`
   instead of a real socket. The coordinator pumps raw protocol lines
   between its one real connection and whichever worker is currently
   playing, so from `pokemon_battle()`'s point of view it's talking to
   Showdown exactly like it always has.
4. Once that worker reports the battle over, goes back to waiting for
   the next challenge -- on the *same* connection. No reconnect, no
   re-login, regardless of how many different formats get challenged
   in a row.

Pass `--format` explicitly to opt back into the old, single-format
behavior (useful for e.g. deliberately testing one exact variant); see
`start-showdown --help`. `--battles`/`--run-count` has no multi-format
equivalent and is ignored when `--format` is omitted -- there's no
"play N battles then log off" concept here, it just runs until Ctrl-C.

`scripts/mirror-sprites.js` mirrors, from the real CDN, at build time:

- the icon/item/pokeball/**trainer-avatar-picker** sprite **sheets**
  (single files covering every species/item/avatar-choice -- cheap)
- type icons (`sprites/types/`, what `Dex.getTypeIcon()` actually uses --
  move types, tooltips, the battle log), Tera-type icons, category icons,
  AND `sprites/typeicons/` -- a separate CDN directory, same types, used
  by the dedicated `typeicon-<Type>` CSS classes the newer Preact UI
  (`src/panels.tsx`) renders. Easy to mix these two up since they sound
  the same; they're genuinely different paths and both are mirrored.
- **per-species battle sprites, front+back, normal+shiny** -- both the
  static PNGs (`gen5` family -- every gen6-9 species' static sprite
  directory falls back to `gen5` regardless of actual generation,
  confirmed against `battle-dex.ts`'s `getSpriteData()`) *and* the
  animated GIFs, in whichever of the two independent animated families
  (current-gen `ani`/`ani-back`, or BW/legacy `gen5ani`/`gen5ani-back`)
  actually has art for that species -- which one gets requested depends
  on a client-side setting (the "2D sprites instead of 3D models" pref),
  not anything this build controls, so both are mirrored rather than
  guessing which one to skip.
- **trainer avatars** (`sprites/trainers/*.png`, plus the `#`-prefixed
  special ones under `sprites/trainers-custom/*.png`) -- the name list is
  read directly out of the client's own `battle-dex-data.ts` source
  (`BattleAvatarNumbers`) rather than hardcoded, so it stays in sync with
  upstream automatically.
- a small fixed set of non-species images specific UI/battle code
  hardcodes a literal path for: the Substitute-doll sprite, the Mega
  Evolution/Primal Reversion name-badges, the April Fools' Day
  Meloetta/Digimon art, the item/mail battle-log icons, and the
  background-picker thumbnail sheet (see the comment above
  `buildFixedFileList()` in the script for exactly which files and why
  each one needed grepping the client source to find, rather than being
  guessable from the pokedex data).
- **the `fx/` hit/impact effect sprites** (`BattleEffects` in
  `battle-animations.ts`): 58 small images -- fireballs, slashes, wisps,
  and the like -- that back the large majority of move animations, in
  every battle. This whole directory was unmirrored before; every
  animated move effect would have been invisible. This also covers every
  hazard/screen that gets a real sprite -- Stealth Rock, Spikes, Toxic
  Spikes, Sticky Web, G-Max Steel Surge (Reflect, Light Screen, Aurora
  Veil, Safeguard, and Mist are CSS-only in the client, no image needed).
- **field-condition overlays**: weather (Sun/Rain/Sandstorm/Hail-or-Snow/
  Strong Winds), all four terrains (Electric/Grassy/Misty/Psychic), and
  the three "room" moves (Trick Room, Magic Room, Wonder Room) plus
  Gravity -- 13 `fx/weather-*.{jpg,png}` files. These never go through
  `BattleEffects` at all -- the client just swaps a CSS class (e.g.
  `raindanceweather`, `trickroomweather`) on a persistent overlay div, and
  `style/battle.css` supplies each class's background image directly --
  so the grep that finds the `fx/` effect sprites above could never have
  caught these, and they were completely unmirrored before. That meant
  every one of these field conditions rendered as a blank overlay (status
  text only, no art) for the entire duration it was active, in every
  battle. `style/battle.css`'s URLs here are already host-relative
  (`../fx/...`), unlike the two stylesheets `showdown-client-css-fixes.patch`
  fixes, so no patch is needed for this -- only mirroring the files.
- **battle backgrounds** -- not just the two a couple of specific move
  animations switch to, but the *full* default (gen6+) random-pick set of
  19 (`sprites/gen6bgs/`), which is what gets chosen for every ordinary
  battle. Only 2 of the 19 were mirrored before, so ~90% of battles would
  have shown a blank background. Also mirrors the equivalent old-gen
  (gen1-5) backdrop sets, reachable via the same "2D sprites" setting.
- **the client's own background theme** (`fx/client-bg-*.jpg` +
  `fx/client-bgsheet.png`) -- this is the *entire app's* background
  image, not battle-specific, and defaults to a random pick from these
  four for every user who hasn't chosen one. Previously unmirrored
  entirely, meaning the whole app had a broken background by default.
- **old-gen (gen1-gen4) per-species static sprites** -- reachable not via
  a client setting but via the battle's own generation, and this build's
  `start-showdown --format` flag passes straight through to foul-play
  with no gen restriction (e.g. `--format gen3ou`), so old-gen play is a
  first-class, one-flag, documented feature here, not a theoretical edge
  case. Mirrored only for species that could actually appear in a battle
  of that generation (`speciesGenFor()`, replicating `Species`'s own
  num-range-based gen inference -- data/pokedex.js has no explicit `gen`
  field for ~90% of entries). No animation is ever attempted below gen5,
  and gen1 specifically never gets a shiny variant (Shiny didn't exist
  yet), both reflected in what gets mirrored.
- `pokedex-mini.js`/`pokedex-mini-bw.js` -- not images, gender-variant and
  animation-availability metadata `getSpriteData()` reads (also what the
  two families above are keyed off of). These are the two files
  `testclient-new.html` hardcodes an absolute CDN URL for with *no*
  local-path fallback at all, unlike every other data script.

The per-species filename (`spriteid`) is computed with the exact same
algorithm the client itself uses (copied from `battle-dex-data.ts`'s
`Species` constructor, not guessed) -- verified against a real build's
`pokedex.js`: 1517 species, 1503 unique spriteids, spot-checked against
megas, gigantamax forms, regional forms, totems, and the
`greninja-bond`/`rockruff-dusk` special cases. Same for the per-species
generation (`speciesGenFor()`, used for old-gen mirroring) -- spot-checked
against 20 species spanning gen1-9 plus a mega and a primal, all matching
their real generations.

**Deliberately not mirrored** (bounding this to a reasonable size/build
time -- extend `scripts/mirror-sprites.js`'s `STATIC_SPECIES_SPRITE_DIRS`/
`buildFixedFileList()` if you want more):
- audio cries
- team-builder-only preview sprites (`home-centered`/`dex`/`xydex` --
  used only while building a team, not during an actual battle)
- the per-ladder-rank badge icons (`sprites/misc/<formatType>_<type>.png`)
  a player's real ladder standing can add next to their name in battle --
  the filename depends on live ladder data (`side.badges`) this offline
  build has no source for, so there's nothing concrete to mirror yet
- `data/commands.js` (chat-box command autocomplete) -- this one isn't a
  scoping choice, it just doesn't get generated by the client's own build
  in the first place; it already has the same onerror-fallback-to-remote
  pattern as the other data scripts, so it degrades gracefully offline
  (autocomplete just won't populate) rather than breaking anything.

## How patches work

Nothing here overwrites an upstream file wholesale. Four real,
`git apply`-compatible unified diffs live in `patches/`:

- `showdown-server-config.patch` -- the four config changes above, plus
  the `/trn human` auto-login hook, applied on top of the server's own
  `config-example.js`
- `showdown-client-testclient.patch` -- the `Config.routes`/
  `defaultserver`/`Net.defaultRoute` fixes and the two hardcoded
  `pokedex-mini(.bw).js` URLs, applied on top of `testclient-new.html`
- `foulplay-noguest-login.patch` -- makes foul-play's login skip the
  login-server HTTP round trip when `FOUL_PLAY_NOGUEST_LOGIN=1` is set
  (only `start-showdown` sets it; foul-play's normal behavior against the
  real ladder is completely unchanged)
- `foulplay-disable-ping-keepalive.patch` -- applied on top of the patch
  above (it relies on the `import os` that one adds). Opens the websocket
  with `ping_interval=None` under the same `FOUL_PLAY_NOGUEST_LOGIN=1`
  opt-in. Without it, the bundled server's synchronous startup work
  (chatroom restore, loading `/formats`, etc.) can still be running well
  after its TCP listener is up, long enough to miss the websockets
  library's default 20s ping/pong keepalive -- foul-play's first
  connection then gets force-closed with `1011 keepalive ping timeout`
  before login ever happens. `start-showdown`'s restart loop silently
  papered over this by retrying, but the race could still fire again;
  disabling the client-side keepalive removes it outright. This is a
  loopback connection to a server process the launcher is itself
  supervising, so the library-level heartbeat isn't needed to detect a
  dead peer -- a closed socket or dead process is already caught
  elsewhere. Online/ladder logins are unaffected.

Each is applied with `git apply --check` first; if it doesn't apply
cleanly (upstream changed the file in a way that no longer matches), the
build **fails loudly** rather than silently doing something wrong or
skipping the patch. Every patch is followed by a real verification step,
not just "the file still contains some expected string":
- the server config patch: `node --check` (syntax) + actually
  `require()`-ing the file and asserting the resulting values
  (`scripts/chroot/20-showdown-server.sh`)
- the client patch: `scripts/verify-testclient-html.js` -- extracts the
  embedded fallback-config script, syntax-checks it standalone, then
  actually executes it in a minimal browser-shim `vm` context and asserts
  `Config.routes.client`, `Config.defaultserver.*`, etc. come out right
- the foul-play patches: `python3 -m py_compile` + an `ast`-based check
  that `login` and `create` are still `async def` after both patches are
  applied (`scripts/chroot/10-foulplay.sh`)

All four patches were built and test-applied against real, freshly
cloned checkouts before being committed here -- not hand-written and
hoped-for.

## No build-only tooling in the final image

- **foul-play**: `rust`/`cargo`/`build-base` etc. are removed after
  `poke-engine` is compiled into the venv -- now once for the venv's own
  default install, plus once more per generation/Champions variant (see
  "Old-gen and Champions battles" above) -- same as before this feature
  was added, just more compiles before the toolchain gets removed.
- **pokemon-showdown**: `npm prune --omit=dev` drops `typescript`,
  `eslint`, `mocha`, and the other 11 devDependencies. The TypeScript
  source itself is removed too -- `sim/`, `data/`, `lib/`, `tools/`,
  `translations/`, and everything in `server/` except `static/`. This
  isn't an assumption: verified empirically, by actually deleting all of
  it from a real build and confirming the server both starts *and* serves
  a real `HTTP 200` (deleting `server/` entirely, by contrast, starts
  fine but crashes on the first request, because the static file server's
  root is intentionally a live directory outside `dist/` -- which is
  exactly why `server/static` specifically survives and gets replaced
  with the built client -- as a real copy/move, not a symlink; a symlink
  there was found not to resolve reliably through iSH-AOK's fakefs layer
  on-device, even though it worked fine in a plain Linux sandbox. The
  original stub's `404.html` is also copied into the new static
  directory, since the client build has neither `404.html` nor
  `index.html` of its own -- without that, `customhttpresponse` failing
  to intercept a request for any reason crashes the server outright
  instead of degrading to a normal 404).
- **pokemon-showdown-client**: only the final built
  `play.pokemonshowdown.com/` static output is kept. Everything else --
  `node_modules`, `build-tools/`, the TypeScript `src/`, and critically
  `caches/pokemon-showdown` (a full second clone+build of the server,
  needed only to extract dex data during the build) -- is deleted.
- `git`, `patch`, `php` (needed only because `node build full`'s news-embed
  step shells out to it -- see `scripts/chroot/00-common.sh`), `npm`, and
  the whole Alpine `build-base`/`*-dev` toolchain are removed in the final
  step. Only `node` itself stays, because it's the language runtime the
  already-built server actually runs on -- not a build tool.

## Runners

The workflow defaults to `runs-on: ubuntu-24.04-arm` -- **GitHub's own
native aarch64 hosted runner**. Free, no setup, one hard limit: **only
works on public repositories**. Options:

| Situation | What to pick |
|---|---|
| Public repo | Default (`ubuntu-24.04-arm`) -- nothing to install |
| Private repo, willing to use Blacksmith | Install the [Blacksmith GitHub App](https://blacksmith.sh), run the workflow manually with `runner: blacksmith-4vcpu-ubuntu-2404-arm` |
| Private repo, no third-party app | Make the repo public, or point `runs-on` at a self-hosted aarch64 runner |

This build compiles the showdown server's TypeScript, runs a full client
build (which itself clones+builds a second throwaway server copy for dex
data), and mirrors ~6000 small sprite/icon files -- expect it to take
noticeably longer than foul-play alone did. `timeout-minutes: 120` is set
accordingly.

## Architecture: aarch64 (ARM64), Alpine pinned to 3.23.3

Same as before this feature was added: aarch64 because it's confirmed
working by hand and is what ish-AOK itself bundles
(`alpine-minirootfs-3.23.3-aarch64.tar.xz` in the ish-AOK repo -- note its
own README describes native ARM64 guest support as living on a separate
`aarch64` branch, so confirm your ish-AOK build includes that if you're
building it yourself); Alpine pinned to `3.23.3` for the same reason, not
auto-discovered "latest." See `scripts/build-rootfs.sh` for how to bump
either later.

## Triggering builds

- **Automatic:** every Monday.
- **Manual:** Actions tab → run workflow. Inputs: `alpine_version`,
  `poke_engine_gen`, `foul_play_ref`, `showdown_ref`, `client_ref`,
  `runner`.

Each run **replaces** the assets on the `rootfs-latest` release, so the
download link never changes.

## Local testing

On any aarch64 Linux box (this won't run on x86_64 -- no QEMU is set up,
by design, since real native execution is both simpler and much faster):

```sh
sudo ./scripts/build-rootfs.sh
sudo ./scripts/verify-rootfs.sh out/foul-play-showdown-offline-aarch64-latest.tar.gz
```

`verify-rootfs.sh` checks foul-play imports correctly, actually starts the
bundled server inside the chroot, waits for it to come up, and confirms
the served page is the offline-patched client (not the original,
internet-pointing one).

## License

The scripts/patches in this repo are MIT-licensed -- see [LICENSE](LICENSE).

The rootfs artifact is a combined work bundling several licenses:
- **foul-play**: GPL-3.0
- **pokemon-showdown** (server): MIT
- **pokemon-showdown-client**: **AGPL-3.0**

The AGPL-3.0 piece is the one that actually matters here: AGPL requires
that anyone who interacts with a *modified* copy of the software *over a
network* -- which describes exactly what this build does, serving the
patched client to a browser -- be able to get the corresponding source,
including the modifications. This repo's `patches/` directory plus the
exact `pokemon-showdown-client` commit hash recorded in every build's
`BUILD_INFO.txt` is that corresponding source. If you fork this repo
privately and distribute *your own* built rootfs to other people, that
obligation is yours to keep satisfying, not just something this template
took care of once.

This project isn't affiliated with `pmariglia/foul-play`,
`pmariglia/poke-engine`, `smogon/pokemon-showdown`,
`smogon/pokemon-showdown-client`, `emkey1/ish-AOK`, or Alpine Linux -- all
credit for the actual software goes to those projects.
