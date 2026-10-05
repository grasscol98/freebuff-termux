# Freebuff for Termux

Run [Freebuff](https://freebuff.com) — the free coding agent — **natively on
Android**, with no glibc userland and no proot.

```bash
pkg install dpkg curl git ripgrep
curl -fsSL https://raw.githubusercontent.com/grasscol98/freebuff-termux/main/install.sh | bash

cd ~/your-project
freebuff
```

> **Status: experimental.** This port was written without access to Android
> hardware — it was developed from the published sources of Freebuff, Bun and
> OpenTUI, plus a working reference port. The build is automated and every step
> is verifiable, but *no release here has been run on a physical device by the
> author.* Expect the first real install to surface something. If it does, run
> `freebuff --diagnose` and open an issue with the output — that report is how
> this port gets fixed. See [Status](#status) for what is and is not verified.

---

## Why `npm install -g freebuff` does not work

It is worth being precise, because the reasons are not obvious and one of them
cannot be worked around:

1. **npm refuses the package.** It declares
   `os: ["darwin","linux","win32"]`, and Node on Termux reports
   `process.platform === "android"`, so `npm install -g freebuff` fails with
   `EBADPLATFORM`. (`--force` gets past this.)

2. **The binary it downloads cannot run.** That package is only a 4-file
   JavaScript bootstrapper. It fetches `freebuff-linux-arm64.tar.gz` from
   `codebuff.com` and execs it — a **glibc**-linked Bun executable. Android's libc
   is Bionic. There is no flag for this. The stock Freebuff CLI only runs on
   Android inside a glibc userland, i.e. proot-distro.

3. **There is no static build to fall back to.** It is tempting to reach for
   `bun build --compile --target=bun-linux-arm64-musl`, which avoids glibc
   entirely. That does not work: Bun's musl target is *dynamically* linked. Its
   program headers carry

   ```
   ph[1] type=0x3 (INTERP) off=568 filesz=26
     interpreter: /lib/ld-musl-aarch64.so.1
   ```

   Android cannot satisfy that path, cannot create it, and its linker
   (`/system/bin/linker64`) refuses non-Bionic ELFs anyway.

So a native port has to change the runtime and the TUI library, not just repackage
things. That is what this repository does.

## How it works

Three pieces, two of them built by other people and reused here:

| Piece | What it is | Why it is needed |
| --- | --- | --- |
| **Freebuff** | Unmodified, from `CodebuffAI/freebuff` | The agent itself |
| **bun-termux** | [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | A Bun runtime that runs under Bionic, with source patches for the seccomp traps on `fchmodat2`/`openat2`, a TinyCC-backed FFI JIT, and a launcher. Stock Bun has no usable Android build |
| **@androidtui** | [@androidtui/core](https://www.npmjs.com/package/@androidtui/core) and friends | `libopentui.so` rebuilt for `android-arm64` (Bionic ABI, 16 KiB page-aligned), plus the JS that routes to it. Upstream `@opentui/core` publishes darwin/linux/win32 only, and its Linux build is glibc |

Both of those exist because [opencode](https://opencode.ai) — which uses the same
OpenTUI-based TUI as Freebuff — needed exactly this port. Rather than solve the
same three problems again, this repository reuses their solutions and does the
Freebuff-specific work: a redirect for the OpenTUI dependency, a patch set, the
package layout, and the installer. Full details and attribution in
[CREDITS.md](CREDITS.md).

This port's own work is deliberately small, and mostly *not* clever:

- **`ci/apply-config-delta.mjs`** — redirects `@opentui/core` and
  `@opentui/react` to the Android build through npm aliases, so the ~90
  Freebuff source files that import `"@opentui/core"` need no edits.
- **`ci/apply-patches.mjs`** — eight anchored edits to three files, each
  asserting it matched exactly once and each documenting what breaks without it.
- **`freebuff`** — a runtime wrapper for the handful of things the binary cannot
  discover about its own environment.
- **`install.sh`**, **`diagnose.sh`**, CI, and a `.deb`.

## Requirements

- **aarch64** Android. There is no 32-bit build of Bun or OpenTUI, so this port
  is aarch64-only. On a 32-bit device, use proot-distro with the stock CLI.
- **Android 7.0 (API 24) or newer.**
- Termux with `dpkg`, `curl`, `git`, `ripgrep`.
- Free. Freebuff is free; so is this port.

Your device does **not** need root.

## Install

```bash
pkg install dpkg curl git ripgrep
curl -fsSL https://raw.githubusercontent.com/grasscol98/freebuff-termux/main/install.sh | bash
```

Options:

```bash
./install.sh                    # install or upgrade to the latest release
./install.sh --version 0.1.0    # a specific release
./install.sh --force            # reinstall the same version
./install.sh --uninstall        # remove it; logins and settings are kept
```

The install lands at:

```
$PREFIX/bin/freebuff                        the wrapper you type
$PREFIX/bin/freebuff-diagnose               diagnostics
$PREFIX/libexec/freebuff/freebuff           the real executable
$PREFIX/libexec/freebuff/tree-sitter.wasm   read from beside the executable
$PREFIX/share/freebuff/version              what it was built from
```

There are no published releases yet — this port has never been run on a phone, so
no `.deb` has been built. Until one is, `install.sh` will tell you so; to build
and install directly, see [Testing it](#testing-it-before-you-trust-it).

## What the wrapper does

`bin/freebuff` is a small shell script around the real executable. It always ends
in `exec`, so Ctrl-C, signals, exit codes and job control are the real binary's.

It fixes four things the binary cannot work out for itself:

1. **Sweeps the per-launch OpenTUI library.** Every launch unpacks a ~10 MB
   `libopentui.so` to a fresh `TMPDIR` file and never deletes it, with a unique
   name each time. On a phone that is real storage, several GB per month. This is
   [upstream issue 1443](https://github.com/CodebuffAI/freebuff/issues/1443),
   still open; the wrapper deletes stale copies on each launch, but the real fix
   belongs upstream.
2. **Points ripgrep at Termux's.** Freebuff extracts its own glibc `rg` next to
   itself and spawns it, which cannot execute. `CODEBUFF_RG_PATH` is the
   supported override, but the compiled CLI only read it on its failure path —
   the `ripgrep:` edit in `ci/apply-patches.mjs` fixes that, and the wrapper sets
   it to the `rg` from `pkg`.
3. **Adds Termux's CA bundle** via `NODE_EXTRA_CA_CERTS`, so a proxy with a
   private CA does not break sign-in.
4. **Checks that `tree-sitter.wasm` sits beside the executable**, which is where
   the CLI looks for it at startup.

## Diagnosing a problem

```bash
freebuff --diagnose            # full report, safe to paste into an issue
freebuff --diagnose --short    # environment and exec test only
freebuff --diagnose --redact   # omit paths and the device model
```

It checks the things that actually go wrong: the ELF interpreter (glibc vs musl
vs Bionic), 16 KiB page alignment, the `libopentui.so` leak, ripgrep,
`/proc` CPU-count skew, disk space, and whether the binary runs at all — then
interprets each result rather than just dumping it.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for what the common
messages mean.

## Known issues

Carried from upstream, not introduced here:

- **[#1443](https://github.com/CodebuffAI/freebuff/issues/1443)** — the ~10 MB
  per-launch `libopentui.so` leak. Mitigated by the wrapper, not fixed.
- **[#1374](https://github.com/CodebuffAI/freebuff/issues/1374)** — a crash from
  `/proc` CPU-count disagreement. Upstream fixed their side. This port should
  not hit it, since it does not use proot; the diagnostic still checks.

Specific to this port:

- **No updater.** Freebuff's own self-update mechanism is part of the glibc
  launcher this port replaces. Re-run `install.sh`.
- **`tree-sitter` syntax highlighting** may be degraded. The wasm asset is
  shipped, but its interaction with the Android native module is unverified.
- **32-bit devices are unsupported.** There is no build to fall back to.

## Testing it before you trust it

This port has never run on a phone, so two scripts exist to find out whether it
can — in increasing order of cost.

### 1. Probe the prerequisites (minutes)

```bash
./scripts/probe-termux.sh
```

Validates the two things this port cannot build itself and does not control:
someone else's Bionic Bun, and someone else's Bionic `libopentui.so`. Both are
prebuilt artifacts, so the entire foundation can be checked in a couple of
minutes without building Freebuff at all. It also catches the mistake people
actually make — installing Termux's stock `bun`, which lacks the FFI launcher
OpenTUI needs.

If this passes, the hard, unverifiable part is done and what remains is packaging.

### 2. Build Freebuff on the device

```bash
./ci/build-on-device.sh --dry-run     # clone, patch, verify; stop there
./ci/build-on-device.sh               # the full build, then install
```

Slower than anything else here — a ten-workspace Bun monorepo on a phone — but it
is the only way to test the port without CI. Re-runs reuse the checkout, so
iterating on a build failure does not re-clone. Needs `git nodejs dpkg file
binutils`, ~6 GB free and as much RAM as the device has.

### Or build on a desktop / in CI

```bash
FREEBUFF_VERSION=0.1.0 bash ci/build-on-runner.sh
```

Requires Docker and an arm64 host.

## Building from source

Requires an arm64 host or Docker, because the compile must happen under a Bionic
Bun — that is what makes the output Bionic.

```bash
# On an arm64 Linux box with Docker:
FREEBUFF_VERSION=0.1.0 bash ci/build-on-runner.sh

# Or inside termux-docker, where the rest of the work happens:
bash ci/build-in-container.sh
```

`ci/prepare-build-tree.sh` does the reproducible part: clone upstream at a pinned
ref, apply the config delta, apply the patch set. Both steps are idempotent and
fail loudly rather than half-applying.

Pins live in [`versions.json`](versions.json). Read it before bumping anything —
each field is a decision with a reason attached.

## Status

Verified here, on a machine with no Android:

- The patch set applies to upstream source, is idempotent, and the patched
  TypeScript parses.
- The config delta produces the expected dependency graph and preserves
  everything else in both `package.json` files.
- Every claim in this README about upstream behaviour is sourced in
  [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md), with file paths and line
  numbers.

Not verified — nobody has run this on a phone yet:

- That `bun build --compile` under the patched Bun emits a Bionic binary from
  this configuration. The build asserts it and refuses to publish otherwise, but
  an assertion that has never fired is still an untested assertion.
- That Freebuff's TUI works against OpenTUI 0.5.x. Every symbol it imports was
  checked against 0.5.14's type declarations and is present with a compatible
  signature, but Freebuff pins 0.3.4 and this port moves it two minor versions
  forward.
- Runtime behaviour: sign-in, streaming, image input, file editing, ripgrep,
  syntax highlighting.

## Licence

Apache-2.0, matching Freebuff. See [LICENSE](LICENSE) and
[CREDITS.md](CREDITS.md) — this port redistributes nothing from CodebuffAI and
depends on other people's builds, which matters for attribution.