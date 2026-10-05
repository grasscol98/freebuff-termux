# Porting notes

The research behind this port, with sources. Written down because the reasoning is
the reusable part — the next person who asks "why not just install it with npm?"
should not have to re-derive any of this.

Everything below was checked against published sources while writing this port.
Where a claim was verified by downloading and inspecting an artifact, that is
said.

---

## 1. What the official package actually is

`npm install -g freebuff` installs **five files**, 102 KB unpacked, one dependency
(`tar`). It is a bootstrapper, not the product.

| File | Role |
| --- | --- |
| `index.js` | Reads `package.json`, calls `createLauncher()` |
| `launcher.js` | 80 KB: download, verify, install, spawn, self-update |
| `http.js` | Download client with retries |
| `package.json` | Version, `os`, `cpu`, and the `binaryChecksums` map |

At runtime `launcher.js`:

1. Resolves a platform key from `process.platform` + `process.arch`
   (`getPlatformKey()`).
2. Maps it to an archive name — `freebuff-linux-arm64.tar.gz` — from
   `PLATFORM_TARGET_KEYS`, which is `linux-x64`, `linux-x64-baseline`,
   `linux-arm64`, `darwin-*`, `win32-*`.
3. Downloads it from `<origin>/api/releases/download/<version>/<file>`.
4. Verifies the archive's sha256 against the checksum published on **npm**, which
   it treats as a separate trust root from the download host. Good design.
5. Extracts only `freebuff` and `tree-sitter.wasm`, via an allowlist filter.
6. Execs `~/.config/manicode/freebuff`.

The `binaryChecksums` map in the published `package.json` at v0.2.15 lists
exactly eight targets. There is no Android or musl entry.

## 2. Why npm refuses it

```json
"os":   ["darwin", "linux", "win32"],
"cpu":  ["x64", "arm64"],
```

Termux's Node reports `process.platform === "android"`. This is not folklore — it
is visible in Termux's own patch to Node's `child_process`:

```diff
--- node-v18.0.0.orig/lib/child_process.js
+++ node-v18.0.0/lib/child_process.js
@@ -578,7 +578,7 @@
       if (typeof options.shell === 'string')
         file = options.shell;
       else if (process.platform === 'android')
-        file = '/system/bin/sh';
+        file = '@TERMUX_PREFIX@/bin/sh';
```

(from `termux/termux-packages`, `packages/nodejs/lib-child_process.js.patch`.)

So `npm install -g freebuff` fails `EBADPLATFORM`. `--force` bypasses that, which
leads to the next problem.

## 3. Why the launcher cannot pick a target

`getPlatformKey()` returns `android-arm64`. That is not in
`PLATFORM_TARGET_KEYS`, so `PLATFORM_TARGETS['android-arm64']` is `undefined` and
`stageBinary()` throws:

```
Unsupported platform: android arm64
```

Patching this is *not* a real fix, because of the next section.

## 4. Why the binary cannot run — the part that cannot be configured away

`freebuff-linux-arm64` is a **glibc**-linked Bun executable. Android's libc is
Bionic. Android's linker is `/system/bin/linker64`, and it rejects non-Bionic ELFs
outright. There is no environment variable, flag, or loader shim that makes this
work. The stock CLI needs a glibc userland, which on Termux means proot-distro.

### 4a. The static-musl escape hatch does not exist

The obvious idea is `bun build --compile --target=bun-linux-arm64-musl`: musl
binaries are often static, and a static binary needs no dynamic loader at all, so
it would sidestep the whole problem.

That target is real. Bun's `--compile` target list includes `bun-linux-arm64-musl`.

It does not produce a static binary. Downloaded `bun-linux-aarch64-musl.zip` from
the `bun-v1.3.14` release and parsed the program headers of the `bun` binary
inside:

```
e_phoff=64 e_phentsize=56 e_phnum=9
  ph[0] type=0x6 (PHDR)     off=64
  ph[1] type=0x3 (INTERP)   off=568      filesz=26
  ph[2] type=0x1 (LOAD)     off=0
  ph[3] type=0x1 (LOAD)     off=34974720
  ph[4] type=0x1 (LOAD)     off=87025520
  ph[5] type=0x7 (TLS)
  ph[6] type=0x2 (DYNAMIC)  off=87359488 filesz=464
  ph[7] type=0x6474e551 (GNU_STACK)
  ph[8] type=0x4 (NOTE)

PT_INTERP present : True
  interpreter      : /lib/ld-musl-aarch64.so.1
PT_DYNAMIC present: True
```

`PT_INTERP` and `PT_DYNAMIC` are both present. The binary wants
`/lib/ld-musl-aarch64.so.1`, a path that does not exist on Android, that an
unprivileged app cannot create, and that Bionic would not load in any case.

Strings in the file (`ld-musl-aarch64`, `GLIBC_`, `libstdc++`) are *not* evidence
either way — a statically linked Bun can carry them for unrelated reasons. Only
the program headers are decisive.

**This is why the port uses a patched Android-ABI Bun rather than a musl build of
Freebuff.** There is no such thing as a droppable-in static Freebuff binary.

## 5. Why the TUI is the real problem

Even with a working Bionic Bun, the TUI would not start.

`@opentui/core` is a Zig library loaded through Bun FFI, selected by a static
`import()` inside a platform switch. From `@opentui/core@0.3.4`:

```js
async function resolveNativePackage() {
  if (process.platform === "darwin") { ... }
  if (process.platform === "linux") {
    if (process.arch === "arm64") {
      if (process.env.OPENTUI_LIBC === "musl") return await import("@opentui/core-linux-arm64-musl");
      else                                    return await import("@opentui/core-linux-arm64");
    }
    ...
  }
  throw new Error(`opentui is not supported on the current platform: ${process.platform}-${process.arch}`);
}
```

Two independent failures:

1. `process.platform === "android"` is not `"linux"`, so it reaches the `throw`.
2. Even as `"linux"`, the default is the **glibc** `libopentui.so`.

`OPENTUI_LIBC=musl` is a real, undocumented lever — it selects the musl build —
and it is tempting to reach for. It does not help: the musl `.so` is not the
`PT_INTERP` problem's answer either, and Android has no musl.

Published native packages for `@opentui/core@0.5.14`:

```
@opentui/core-linux-x64        @opentui/core-darwin-x64
@opentui/core-linux-arm64      @opentui/core-darwin-arm64
@opentui/core-linux-x64-musl   @opentui/core-linux-arm64-musl
@opentui/core-win32-x64        @opentui/core-win32-arm64
```

**No Android build.** That is the gap this port fills, using the prebuilt one from
`@androidtui/core-android-arm64`.

## 6. The two pieces that already exist

Both are by [bd-loser](https://github.com/bd-loser), who ported
[opencode](https://opencode.ai) — a different agent using the *same* OpenTUI TUI —
and hit the identical wall.

### bun-termux

`https://github.com/bd-loser/bun-termux` — Bun 1.4.2 with source patches:

- TinyCC-backed JIT, because the usual path trips SELinux
- seccomp-trap bypasses for `fchmodat2` and `openat2`
- shebang remapping
- FFI paths
- a **launcher script** rather than a raw ELF, because FFI crashes with the raw
  binary

Published as `bun_1.4.2-patched_aarch64.deb`, installed with `dpkg -i`. This port
pins an exact version and refuses to track `/latest`.

Termux's own `bun` package is a different thing: built from upstream source with
kernel-feature patches, but no FFI launcher and no Android-specific fixes. It is
not a substitute — see `ci/build-in-container.sh`, which checks for the raw-ELF
case and aborts.

### @androidtui

`libopentui.so` rebuilt for `android-arm64`: Bionic ABI, **16 KiB page-size
aligned** (Android 15 devices may use 16 KiB pages, and a binary whose LOAD
segments are not aligned cannot load there). Published as
`@androidtui/core-android-arm64`.

The JS side is the same package with the native module redirected. It has a
dedicated Android resolver:

```js
// src/platform/android-native.ts
var PREBUILT_DIR_BY_ARCH = { arm64: "aarch64-android", arm: "arm-android", x64: "x86_64-android" };
async function resolveAndroidNativeLibraryPath(packageName, arch = process.arch) {
  // 1. prebuilt/<triple>/libopentui.so next to the package
  // 2. import("@opentui/core-android-arm64")
  // 3. import(packageName)  where packageName is "@androidtui-<arch>"
}

async function resolveNativeLibraryPath() {
  if (target.platform === "android") {
    const androidPath = await resolveAndroidNativeLibraryPath(asset.packageName, target.arch);
    if (androidPath !== undefined) return androidPath;
    throw new Error(`OpenTUI native library for Android is missing...`);
  }
  ...
}
```

That `android` branch is the whole reason this port is small. Everything else
still behaves exactly like upstream OpenTUI.

## 7. What this port had to add

With both prerequisites in hand, the Freebuff-specific work is small but not
nothing.

### OpenTUI 0.3.4 → 0.5.14

Freebuff's `cli/package.json` pins `@opentui/core` and `@opentui/react` at `0.3.4`.
`@androidtui/*` starts at `0.5.1`. So the port moves Freebuff two minor versions
forward on its TUI library.

Checked rather than assumed — every OpenTUI symbol Freebuff imports, against
`0.5.14`'s type declarations:

| Import | Symbol | In 0.5.14 |
| --- | --- | --- |
| `@opentui/react` | `createRoot` | `createRoot(renderer: CliRenderer): Root` |
| `@opentui/react` | `flushSync` | present |
| `@opentui/react` | `useKeyboard` | `(handler: (key: KeyEvent) => void, options?) => void` |
| `@opentui/react` | `useRenderer` | `() => CliRenderer` |
| `@opentui/react` | `useTerminalDimensions` | `() => { width, height }` |
| `@opentui/react` | `useAppContext` | `() => AppContext` |
| `@opentui/core` | `createCliRenderer` | present |
| `@opentui/core` | `decodePasteBytes`, `stripAnsiSequences`, `TextAttributes` | present |
| `@opentui/core` (types) | `KeyEvent`, `MouseEvent`, `PasteEvent`, `CliRenderer`, `BoxRenderable`, `ScrollBoxRenderable`, `TextRenderable`, `TextBufferView`, `ScrollAcceleration`, `BorderCharacters` | all present |

All present with compatible signatures. Type compatibility is not the same as
behavioural compatibility, though — this is the largest untested risk in the port,
and it is why `opentui` is its own field in `versions.json`.

### Why the config delta is two layers

Redirecting the dependency has to satisfy Freebuff's build scripts, which are
stricter than they first appear:

`cli/scripts/build-binary.ts` reads the pins out of `cli/package.json` and asserts
the installed version equals them:

```ts
const expectedCoreVersion = cliPackageJson.dependencies?.['@opentui/core']
...
if (packageJson.name !== packageName || packageJson.version !== expectedVersion) {
  throw new Error(`Installed ${packageName}@${...} does not match cli/package.json ...`);
}
```

It also validates the native package by exact name:

```ts
const version = corePackage.packageJson.optionalDependencies?.[packageName]
if (version !== expectedCoreVersion) { throw new Error(`does not declare ...`) }
```

An npm alias breaks both, twice over:

- The installed `package.json` reports the *alias target's* name
  (`@androidtui/core`), not the requested one.
- The declared optional dependency is an alias **spec**, not a version:
  `"@opentui/core-android-arm64": "npm:@androidtui/core-android-arm64@0.5.14"`,
  which fails a string equality check against `0.5.14`.
- And the alias target is the name that exists on the registry —
  `@opentui/core-android-arm64` is not published, so a `bun install` for the
  declared key 404s.

So the delta is:

1. **root `package.json` `overrides`** — `"@opentui/core": "npm:@androidtui/core@0.5.14"`.
   An alias installs the target's files under the requested name, so the tree keeps
   `node_modules/@opentui/core` and every existing import resolves with no source
   edits.
2. **`cli/package.json` pins** — moved to `0.5.14`, and `react-reconciler` to
   `^0.33.0` to match `@androidtui/react`'s own range. Two reconcilers otherwise.

and the patch set teaches the two validation sites to read an alias spec.

### The eight edits

All in `ci/apply-patches.mjs`, each anchored and asserted. Summarised:

| File | Edit | Why |
| --- | --- | --- |
| `cli/scripts/build-binary.ts` | add `android-arm64` to the target table | build aborts: `Unsupported build target: android-arm64` |
| `cli/scripts/build-binary.ts` | parse `npm:` alias specs | version equality check fails on an alias string |
| `cli/scripts/build-binary.ts` | install the alias target | declared key is unpublished; `bun install` 404s |
| `cli/scripts/build-binary.ts` | `parseNpmAlias` helper | supports the above |
| `cli/scripts/build-binary.ts` | accept an aliased package name | name check rejects `@androidtui/core` |
| `cli/scripts/open-tui-native-bundle.ts` | `libopentui.so` on android | every Android install reads as incomplete |
| `cli/scripts/open-tui-native-bundle.ts` | accept an aliased package name | completeness check rejects the installed package |
| `cli/src/native/ripgrep.ts` | honour `CODEBUFF_RG_PATH` in compiled mode | glibc `rg` extracted and spawned; code search silently dead |

Two of these are worth calling out.

**The `bunTarget` for Android is `bun-linux-arm64`.** That looks wrong and is
deliberate: it is what makes `bun build --compile` embed the *running* patched
runtime as the base of the output. Naming a different target makes Bun download a
stock runtime and produce a glibc binary. `platform` is set to `android` so the
rest of the script — the OpenTUI native package folder, the `--os` filter — takes
the Android path.

**The ripgrep edit is a genuine upstream bug**, not an Android workaround.
`getBundledRgPath()` in the SDK honours `CODEBUFF_RG_PATH`, and the CLI's
compiled path reaches it only from a `catch` — after extraction has already
"succeeded", because extraction is a write and a chmod. On any non-glibc host the
variable is therefore ignored and a dead binary is returned. The four-line fix
would be an improvement for everyone.

### Ripgrep, in more detail

Freebuff's file-finding agents are built on ripgrep. `cli/src/native/ripgrep.ts`
extracts the embedded copy:

```ts
if (!env.CODEBUFF_IS_BINARY) return getBundledRgPath()   // dev: honours the override
// compiled: extracts sdk/dist/vendor/ripgrep/arm64-linux/rg
```

`arm64-linux` is a glibc build. On Bionic it cannot exec, and the failure appears
as a spawn error deep inside an agent turn rather than as a clear message. Termux
has a working `rg` (`pkg install ripgrep`), so the fix is to use it.

## 8. Lessons carried over from the reference port

Not Freebuff-specific, but each one cost real debugging time upstream:

- **Compile inside `termux/termux-docker:aarch64`** on an arm64 runner. Not
  cross-compiled from x86_64: the patched Bun is a Bionic executable and must be
  the same Bun doing the compile.
- **Verify the interpreter before publishing.** A build that silently came out
  glibc passes every local check and fails on the user's phone.
  `ci/build-in-container.sh` refuses to publish a non-`/system/bin/linker` binary.
- **Check for the Bun launcher, not a raw ELF,** before building. FFI crashes
  otherwise, at build time, confusingly.
- **`dpkg-deb -Zxz`.** Ubuntu's dpkg defaults to zstd; Termux's often cannot
  decompress it, and the error does not mention compression.
- **16 KiB page alignment** matters from Android 15. Diagnosed by checking LOAD
  segment alignment against `getconf PAGESIZE`.
- **Pin the Bun runtime exactly.** A regression that reaches users is worse than a
  release that does not exist. `versions.json` says so.

## 9. What is still unknown

Stated plainly, because a port that hides this is worse than one that does not.

- Whether Freebuff's TUI *behaves* correctly on OpenTUI 0.5.x. Type-compatible is
  not behaviour-compatible.
- Whether `tree-sitter.wasm` highlighting works against the Android native module.
  The build ships the asset and asserts it is in place.
- Whether Freebuff's own libc-sensitive code paths (`systeminformation`,
  `node-machine-id`) behave under Bionic. `node-machine-id` in particular reads
  machine identifiers that Android may not expose.
- How much slower this is than a phone-native agent. A glibc binary under proot is
  worse, but Bun-on-Bionic with FFI through TinyCC is not free either.

`freebuff --diagnose` exists to turn any of these into a report rather than a
guess.