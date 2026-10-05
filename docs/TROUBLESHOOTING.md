# Troubleshooting

Start here, whatever the symptom:

```bash
freebuff --diagnose
```

It is the fastest route to the actual cause. This page covers what the messages
mean and what to do about them.

---

## It will not install

### `Unsupported platform: android arm64`

You installed the npm package, not this `.deb`. The npm wrapper derives its
download target from `process.platform`, which is `android` on Termux.

```bash
dpkg -r freebuff 2>/dev/null
curl -fsSL https://raw.githubusercontent.com/grasscol98/freebuff-termux/main/install.sh | bash
```

The npm package cannot work on Termux even with `--force` — it downloads a glibc
binary. See [PORTING-NOTES](PORTING-NOTES.md#4-why-the-binary-cannot-run--the-part-that-cannot-be-configured-away).

### `dpkg -i` fails mentioning `zstd`

```bash
unable to execute decompressing archive ... member "control.tar" (zstd): No such file or directory
```

The `.deb` was built with zstd compression, which some Termux `dpkg` builds cannot
decompress. This port's `ci/package-deb.sh` forces `-Zxz` for exactly this reason;
if you are installing a `.deb` built elsewhere, rebuild it with
`dpkg-deb -Zxz`, or install a newer Termux bootstrap.

### `No such file or directory` on the .deb

Usually a truncated download. Re-run `install.sh --force`. If it persists, check
free space with `df -h "$PREFIX"`.

### 32-bit device

There is no build to install: neither Bun nor OpenTUI publishes a 32-bit Android
build. On a 32-bit device, use `proot-distro` with the stock
`npm install -g freebuff`.

---

## It installs but will not start

### `Exec format error`

```bash
file "$PREFIX/libexec/freebuff/freebuff"
```

- **x86-64** — wrong architecture. You are on an aarch64 device with an x86 build.
- **ELF 64-bit LSB pie executable, for GNU/Linux …** with an interpreter of
  `/lib64/ld-linux-x86-64.so.2` — this is a **glibc** binary and cannot run on
  Android. Reinstall from this project's Releases.

The diagnostics print the interpreter explicitly for exactly this case.

### `No such file or directory` when running the binary, even though the file exists

This is the loader. A glibc or musl binary reports `ENOENT` on exec when its
`PT_INTERP` is missing — which on Android it always is. Confirm with
`readelf -l` and check for `/system/bin/linker64`.

### `cannot execute binary file: Exec format error` on a 16 KiB-page device

Android 15 devices may use 16 KiB memory pages, and every `LOAD` segment must be
16 KiB aligned or the loader refuses the image. OpenTUI's Android build is
aligned for this; the main Freebuff executable comes from the patched Bun, which
should be too. If it is not, `freebuff --diagnose` reports the misalignment
directly under the `elf` section — please include that.

### Blank screen, or it exits immediately

Usually the terminal, not the binary.

```bash
export TERM=xterm-256color
freebuff
```

OpenTUI reads `TERM` for capabilities. Also try a wider window: a terminal narrower
than about 40 columns cannot lay the TUI out. `freebuff --version` is the way to
isolate this — if that works, the executable is fine and the problem is rendering.

### `opentui is not supported on the current platform`

A stock `@opentui/core` got compiled in instead of the Android build. Confirm the
config delta ran; `docs/PORTING-NOTES.md` §7 explains the two layers.

### `Failed to get CPU information`

```
Unhandled rejection: Error: Failed to get CPU information
    at cpus (unknown)
    ...
    at model (node:os:27:21)
```

`os.cpus()` threw. Upstream traced this to
[proot-distro issue 717](https://github.com/termux/proot-distro/issues/717):
proot-distro binds a hardcoded **eight-core** `/proc/stat` over the real one, while
`/proc/cpuinfo` stays live. On a device that is not 8-core the guest sees two
different answers permanently, and the crash is deterministic a few seconds after
startup. Freebuff fixed their side ([#1374](https://github.com/CodebuffAI/freebuff/issues/1374)).

This port does not use proot, so you should not hit it — unless something else on
the device is emulating `/proc`. `freebuff --diagnose` compares
`/proc/stat` against `/proc/cpuinfo` and will say so explicitly.

---

## It runs but is not useful

### Code search finds nothing, agents cannot read files

Ripgrep is missing or unusable. Freebuff shells out to `rg` for its file-finding
agents.

```bash
pkg install ripgrep
rg --version        # must print a version
```

The wrapper sets `CODEBUFF_RG_PATH` to whatever `rg` resolves to, and the
`ripgrep:` edit in `ci/apply-patches.mjs` is what makes the compiled CLI read that
variable. If `freebuff --diagnose` reports an `extracted rg` next to the binary,
this build lacks that edit and the glibc copy is being used.

### Syntax highlighting is missing or crashes

`tree-sitter.wasm` is read from `dirname(process.execPath)` at startup. It ships in
`$PREFIX/libexec/freebuff/`. Confirm:

```bash
ls -la "$PREFIX/libexec/freebuff/"
```

If it is missing, reinstall. Interacting with the Android native module is one of
the unverified areas of this port — see the README's Status section.

### Sign-in fails, or requests hang

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://codebuff.com/
```

A `000` means no connectivity. Anything other than 2xx/3xx suggests a captive
portal or a DNS filter. Also check the CA bundle — the wrapper adds Termux's via
`NODE_EXTRA_CA_CERTS`:

```bash
pkg install ca-certificates
```

### Terminal commands in the chat do nothing

The CLI spawns a shell for them. Termux has no `/system/bin/sh` in the usual
place; the wrapper exports `SHELL=$PREFIX/bin/bash`. Check that `$PREFIX/bin/bash`
exists, and that `PATH` includes `$PREFIX/bin`.

### Everything is slow

Expected to a degree, and unquantified — this is Bun running under Bionic with FFI
routed through TinyCC, which is not a native-speed JIT. It is still much faster
than a glibc binary under proot. Reduce the work per turn rather than expecting
native speed.

---

## Disk filling up over time

Every launch unpacks a fresh ~10 MB `libopentui.so` into `TMPDIR` with a unique
name and never deletes it ([upstream #1443](https://github.com/CodebuffAI/freebuff/issues/1443),
still open). The wrapper sweeps stale copies on every launch, but files left by
runs that bypassed the wrapper accumulate:

```bash
find "${TMPDIR:-$PREFIX/tmp}" -maxdepth 1 -name '.*.so' -type f -delete
freebuff --diagnose | grep -A2 opentui
```

If you invoke the binary directly rather than through `bin/freebuff`, none of that
cleanup happens. The real fix belongs upstream.

---

## Reporting a bug

Include:

1. `freebuff --diagnose` output (`--redact` if you prefer).
2. The version: `cat "$PREFIX/share/freebuff/version"`.
3. The transcript of a failing launch, including any panic text.
4. Whether it happens in the TUI or before it — `freebuff --version` isolates the
   executable from the renderer.

Panic text matters. The launcher upstream keeps the last few KB of a crashed
child's stderr for exactly this reason, and Bun's own crash report usually names
the missing CPU feature or the failing load.