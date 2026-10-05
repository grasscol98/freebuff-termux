# Credits and attribution

This port builds **someone else's** software. Almost all of the hard work — making
a Bun runtime and a terminal-UI library run on Android — was done by other people,
and their work is what makes this repository possible. It is credited here
precisely because none of it is this port's own.

## Freebuff

- **Upstream:** https://github.com/CodebuffAI/freebuff
- **Website:** https://freebuff.com
- **Licence:** Apache-2.0
- **What is used here:** the unmodified upstream source, plus one small source
  patch (see below).

Freebuff is the product. This repository builds it for a platform its official
release does not cover, and redistributes none of its code.

### The one source patch

`ci/apply-patches.mjs`, edit `ripgrep: honour CODEBUFF_RG_PATH in compiled mode`,
fixes a real upstream bug: the CLI's compiled-binary path never consults
`CODEBUFF_RG_PATH` before extracting its embedded glibc ripgrep, so on a non-glibc
host it silently uses a binary that cannot run.

It is written to be sent upstream — it is a four-line change with a comment
explaining why — and it would be a strict improvement for everyone. It is applied
here only because there is no release to consume that includes it.

## bun-termux — the Bionic Bun runtime

- **Upstream:** https://github.com/bd-loser/bun-termux
- **Author:** [@bd-loser](https://github.com/bd-loser)
- **Licence:** see the upstream repository
- **What is used here:** the prebuilt `bun_1.4.2-patched_aarch64.deb`, installed
  with `dpkg` at build time. Pinned in `versions.json`.

This is the single most important dependency. Stock Bun has no Android build that
works: it hits seccomp traps on `fchmodat2`/`openat2`, has no working FFI JIT path
under SELinux, and mis-remaps shebangs. `bun-termux` fixes all of that at the
source level. This port installs it and gets the benefit; it did not write it.

## @androidtui — OpenTUI's native module for Android

- **Packages:** [@androidtui/core](https://www.npmjs.com/package/@androidtui/core),
  [@androidtui/core-android-arm64](https://www.npmjs.com/package/@androidtui/core-android-arm64),
  and the matching `react`, `keymap`, `solid`
- **Upstream:** https://github.com/bd-loser/opentui (a fork of
  [anomalyco/opentui](https://github.com/anomalyco/opentui))
- **Licence:** see the upstream repositories
- **What is used here:** the prebuilt `libopentui.so` for `android-arm64` —
  Bionic ABI, 16 KiB page-size aligned — plus the JS packages that route to it.

Freebuff's TUI is powered by [OpenTUI](https://opentui.com), a Zig library loaded
through Bun FFI. Upstream `@opentui/core` publishes native builds for darwin, linux
and win32 only, and its Linux build is **glibc**, which Bionic's linker rejects.
`@androidtui` is the Android build of the same library, and this port uses it via
npm aliases rather than touching Freebuff's ~90 OpenTUI imports.

Without this the port cannot exist: there is no other way to get a terminal-UI
renderer running natively on Android.

## opencode-bionic — the reference implementation

- **Upstream:** https://github.com/bd-loser/opencode-bionic
- **Author:** [@bd-loser](https://github.com/bd-loser)
- **Licence:** MIT
- **What is used here:** the approach, and several hard-won details reproduced in
  this repository's CI.

opencode is a different coding agent that happens to use the *same* OpenTUI-based
TUI. Porting it to Termux meant solving the identical three problems, so this port
started from their design instead of inventing one. Details carried over, with
credit:

- Building inside `termux/termux-docker:aarch64` on an arm64 runner, rather than
  cross-compiling from x86_64, because the patched Bun must be the same Bun that
  performs the compile.
- Compiling with `--target=bun-linux-arm64` so Bun reuses the *running* patched
  runtime as the base of the output. Any other target silently produces a glibc
  binary.
- `splitting: false`. Bun ≥ 1.4.1 on Bionic emits broken cross-chunk bindings when
  splitting (oven-sh/bun#42837), which surfaces at runtime as
  `TypeError: undefined is not an object`. Freebuff's build script does not enable
  splitting, so no patch is needed here — but it is why this is not a thing to
  "improve" later without reading this file.
- Verifying that the runtime is the launcher rather than a raw ELF before
  building, because FFI crashes with the raw binary.
- `dpkg-deb -Zxz` when packaging. Ubuntu patches dpkg to default to zstd, which
  produces `.zst` members that Termux's dpkg often cannot decompress — and the
  resulting install error mentions nothing about compression.

Where this port differs, and why:

- Freebuff ships its own `tree-sitter.wasm` as a sibling asset and its TUI spans
  far more components than opencode's, so the build asserts the asset is in place
  before publishing.
- Freebuff's build scripts validate the OpenTUI native package by name and
  version. npm aliases break both checks, so the patch set teaches them to read an
  alias spec rather than loosening the validation.
- Freebuff has no self-updater path worth keeping here, so installation is a plain
  `.deb` with a `curl | bash` front end.

## Termux

- **Upstream:** https://github.com/termux/termux-app
- **Licence:** GPL-3.0

Not vendored or modified — this port targets Termux and packages according to its
conventions (`data/data/com.termux/files/usr`, `dpkg`, `$PREFIX`).

One Termux detail that shapes everything here: `os.tmpdir()` is patched to
`$PREFIX/tmp` rather than `/tmp`, and `process.platform` is `"android"`. The
latter is why npm's `os` check rejects the official Freebuff package, and the
former is why the per-launch library leak lands on internal storage instead of a
tmpfs.

## Summary

| Component | Author | Used as |
| --- | --- | --- |
| Freebuff | CodebuffAI | source, one patch |
| bun-termux | bd-loser | prebuilt `.deb` |
| @androidtui/* | bd-loser | prebuilt `.so` + JS |
| Approach and CI lessons | bd-loser / opencode-bionic | reference design |
| This port | whoever publishes this repo | config delta, patches, packaging, installer |