# foul-play-ish-aok

CI that builds an Alpine Linux (aarch64) root filesystem with [foul-play](https://github.com/pmariglia/foul-play)
(a Pokémon Showdown battle AI) pre-installed and pre-compiled, ready to
import straight into [iSH-AOK](https://github.com/emkey1/ish-AOK).

No building on-device, no installing Rust in iSH, no waiting for
`poke-engine` to compile on your phone. Download the tarball, import it,
run `foul-play`.

## Get the rootfs

1. Go to the [`rootfs-latest` release](../../releases/tag/rootfs-latest).
2. On your iPhone/iPad, download `foul-play-alpine-aarch64-latest.tar.gz`
   (Safari will save it to the Files app).
3. In iSH-AOK: **Filesystems → Import (top right) → Files** and pick the
   `.tar.gz` you just downloaded.
4. Switch to it and you're in a normal Alpine root shell with `foul-play`
   already installed.

Run it:

```sh
foul-play \
  --websocket-uri wss://sim3.psim.us/showdown/websocket \
  --ps-username 'your username' \
  --ps-password 'your password' \
  --bot-mode search_ladder \
  --pokemon-format gen9randombattle
```

`foul-play --help` lists all options. `/opt/foul-play/BUILD_INFO.txt` (also
shown as the release notes on each build) records exactly which foul-play
commit, poke-engine version/feature, and Alpine version went into that
build.

**Updating:** there's no in-place updater on purpose (per the original
request this was built for -- simplicity first). To update, just
re-download the latest release and import it again as a new filesystem in
iSH-AOK.

## Architecture: aarch64 (ARM64)

This build targets **aarch64**, not i386/x86_64. A couple of things worth
knowing:

- iSH-AOK's `main`/`working` branch README describes i386 as the
  maintained guest ABI and x86_64 as experimental, and separately notes
  that native ARM64 guest support lives on its own `aarch64` branch (see
  [`docs/aarch64_guest_plan.md`](https://github.com/emkey1/ish-AOK/blob/aarch64/docs/aarch64_guest_plan.md)
  in that branch). If your build of the app doesn't already support
  importing/booting an aarch64 rootfs, you'll need that branch (or
  whatever branch/release has since merged it).
- This repo doesn't try to verify that part for you -- it just builds the
  rootfs. That's on you to confirm against whichever ish-AOK build you're
  running.

## Why this doesn't need QEMU

The CI job runs on a **native aarch64 runner** (see "Runners" below), not
an x86_64 one pretending to be ARM. That means `chroot` into the Alpine
aarch64 rootfs just runs directly on the runner's own CPU -- no QEMU
user-mode emulation, no binfmt registration, no cross-compilation. It's
also why `poke-engine`'s Rust extension builds fast: Alpine ships real
native `rust`/`cargo` packages for aarch64, so `cargo build` runs at full
native speed, not through an emulation layer.

`scripts/build-rootfs.sh` checks `uname -m` against `ARCH` up front and
fails immediately with a clear message if they don't match, rather than
quietly trying (and probably failing, or being absurdly slow) to chroot
into an aarch64 rootfs on a non-aarch64 host.

## How the build works (`scripts/build-rootfs.sh`)

1. Downloads the current `latest-stable` Alpine `minirootfs` tarball for
   aarch64 from Alpine's own CDN (not pinned to a version -- reruns pick
   up Alpine's security updates automatically), and verifies its sha256.
2. Extracts it, bind-mounts `/proc`, `/sys`, `/dev` into it.
3. Runs `scripts/chroot-setup.sh` inside via `chroot`, which:
   - `apk add`s `python3`, `rust`, `cargo`, and build tooling,
   - clones `foul-play` and `pip install`s `requirements.txt` into a venv
     (this is what actually compiles `poke-engine`),
   - smoke-tests `import poke_engine` / `import fp.main`,
   - installs a `/usr/local/bin/foul-play` launcher,
   - **removes** `rust`, `cargo`, and other build-only packages afterward
     to keep the shipped image small (same idea as foul-play's own
     multi-stage `Dockerfile`, just done via `apk del` instead of a second
     build stage).
4. Unmounts, tars up the result, publishes it to a rolling `rootfs-latest`
   GitHub release.

## Triggering builds

- **Automatic:** every Monday (`schedule:` cron), so you get fresh Alpine
  packages and any foul-play/poke-engine updates without doing anything.
- **Manual:** Actions tab → "Build foul-play rootfs for iSH-AOK" → **Run
  workflow**. Options:
  - `poke_engine_gen` — pin a specific Pokémon generation feature (e.g.
    `gen4`) instead of foul-play's default (`gen9`/terastallization). This
    maps to the same `--config-settings`/`make poke_engine GEN=...` knob
    documented in foul-play's own README.
  - `foul_play_ref` — build a specific branch/tag/commit of foul-play
    instead of `main`.
  - `runner` — see "Runners" below.

Each manual/scheduled run **replaces** the assets on the `rootfs-latest`
release, so the download link in step 2 above never changes.

## Runners

The workflow defaults to `runs-on: ubuntu-24.04-arm` -- **GitHub's own
native aarch64 hosted runner**. It's free and requires no setup at all,
with one hard limit: **it only works on public repositories.** If this
repo is private, GitHub will fail the job outright with that label.

Options, depending on your situation:

| Situation | What to pick |
|---|---|
| Public repo | Default (`ubuntu-24.04-arm`) — nothing to install |
| Private repo, willing to use Blacksmith | Install the [Blacksmith GitHub App](https://blacksmith.sh), then run the workflow manually with `runner: blacksmith-4vcpu-ubuntu-2404-arm` |
| Private repo, no third-party app | Make the repo public, or point `runs-on` at a self-hosted aarch64 runner (e.g. a Raspberry Pi, an Ampere/Graviton box) |

Blacksmith's ARM runners are real bare-metal ARM (not emulated), so
they're a fine alternative -- they're just not free the way GitHub's own
public-repo runners are. The workflow's `runner` dropdown includes both
`blacksmith-4vcpu-ubuntu-2404-arm` and `blacksmith-2vcpu-ubuntu-2404-arm`
for this case.

## Local testing

You can run the same build on any aarch64 Linux box (an AWS Graviton
instance, a Raspberry Pi running 64-bit Linux, an Ampere box, an aarch64
Linux VM on an Apple Silicon Mac). It won't run on an x86_64 machine --
this script deliberately doesn't set up QEMU, so it'll refuse at the
architecture check rather than silently emulate:

```sh
sudo ./scripts/build-rootfs.sh
sudo ./scripts/verify-rootfs.sh out/foul-play-alpine-aarch64-latest.tar.gz
```

## License

The scripts in this repo (`scripts/`, the workflow) are MIT-licensed — see
[LICENSE](LICENSE).

The rootfs artifact itself is a combined work: it bundles Alpine Linux
(MIT-ish/various permissive licenses) and **foul-play, which is licensed
GPL-3.0**. `foul-play`'s `LICENSE` file is copied into every built image at
`/opt/foul-play/LICENSE` for that reason, and if you redistribute the
built tarball yourself, GPL-3.0's terms apply to it. This project isn't
affiliated with `pmariglia/foul-play`, `pmariglia/poke-engine`,
`emkey1/ish-AOK`, or Alpine Linux — all credit for the actual software goes
to those projects.
