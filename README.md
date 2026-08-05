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
`--no-bot`). Ctrl-C stops both the server and the bot.

`foul-play` still works completely unchanged on its own too (e.g. against
the real ladder, over the internet): `foul-play --help`.

**Updating:** there's no in-place updater on purpose (per the original
request this was built for -- simplicity first). Re-download the latest
release and import it again as a new filesystem in iSH-AOK.

## What "fully offline" actually required

This is not just "run `pokemon-showdown start` and hope." Four separate
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

The server also auto-logs the browser in as `human` (a small
`customhttpresponse` hook in `config.js` that waits for the client to
finish loading, then sends `/trn human`) so there's no console command to
type -- `http://localhost:8000`, bare, just works.

## Sprites and icons

`scripts/mirror-sprites.js` mirrors, from the real CDN, at build time:

- the icon/item/pokeball sprite **sheets** (single files covering every
  species/item -- cheap)
- type icons, Tera-type icons, category icons (small, fixed sets)
- **static** (non-animated) per-species battle sprites -- front/back,
  normal/shiny -- from the `gen5` sprite family specifically. This isn't
  arbitrary: `battle-dex.ts`'s `getSpriteData()` has every gen6-9 species'
  static sprite directory fall back to `gen5` regardless of the Pokémon's
  actual generation, so this one family of directories is what a default
  (non-animated) modern battle actually requests for every species.
  Confirmed by running a real client build and checking directly.
- `pokedex-mini.js`/`pokedex-mini-bw.js` -- not images, gender-variant and
  animation-availability metadata `getSpriteData()` reads. These are the
  two files `testclient-new.html` hardcodes an absolute CDN URL for with
  *no* local-path fallback at all, unlike every other data script.

The per-species filename (`spriteid`) is computed with the exact same
algorithm the client itself uses (copied from `battle-dex-data.ts`'s
`Species` constructor, not guessed) -- verified against a real build's
`pokedex.js`: 1517 species, 1503 unique spriteids, spot-checked against
megas, gigantamax forms, regional forms, totems, and the
`greninja-bond`/`rockruff-dusk` special cases.

**Deliberately not mirrored** (bounding this to a reasonable size/build
time -- extend `scripts/mirror-sprites.js`'s `SPECIES_SPRITE_DIRS`/
`buildFixedFileList()` if you want more):
- animated GIF battle sprites (`ani`/`ani-back`) -- this build's client
  patch doesn't need them, since static sprites are what a default gen6-9
  battle requests anyway
- audio cries
- `gen1`-`gen4` sprite directories (only matter for old-gen formats)
- team-builder-only preview sprites (`home-centered`/`dex`/`xydex` --
  used only while building a team, not during an actual battle)
- `data/commands.js` (chat-box command autocomplete) -- this one isn't a
  scoping choice, it just doesn't get generated by the client's own build
  in the first place; it already has the same onerror-fallback-to-remote
  pattern as the other data scripts, so it degrades gracefully offline
  (autocomplete just won't populate) rather than breaking anything.

## How patches work

Nothing here overwrites an upstream file wholesale. Three real,
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
- the foul-play patch: `python3 -m py_compile` + an `ast`-based check that
  `login` is still an `async def` (`scripts/chroot/10-foulplay.sh`)

All three patches were built and test-applied against real, freshly
cloned checkouts before being committed here -- not hand-written and
hoped-for.

## No build-only tooling in the final image

- **foul-play**: `rust`/`cargo`/`build-base` etc. are removed after
  `poke-engine` is compiled into the venv (same as before this feature was
  added).
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
