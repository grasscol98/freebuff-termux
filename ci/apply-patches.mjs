#!/usr/bin/env node
// Freebuff-for-Termux patch set.
//
// Why this is a script and not a set of .patch files: every edit below is an
// anchored replacement that asserts it matched exactly once, and refuses to run
// otherwise. A quilt patch whose context has drifted fails the same way, but
// with a line number instead of "expected 12 lines, got 15" — and `git apply`
// on a shallow upstream clone is an extra moving part this port does not need.
// Each edit is also idempotent, so re-running against an already-patched tree is
// a no-op.
//
// Usage:  node ci/apply-patches.mjs <path-to-freebuff-checkout>
// Exits non-zero on the first edit that cannot be applied.

import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const root = process.argv[2]
if (!root) {
  console.error('usage: node ci/apply-patches.mjs <path-to-freebuff-checkout>')
  process.exit(2)
}

/**
 * @param {string} file       path relative to the checkout root
 * @param {string} find       exact text to locate, must appear exactly once
 * @param {string} replace    replacement text
 * @param {string} why        what breaks upstream without this
 */
const edits = [
  {
    file: 'cli/scripts/build-binary.ts',
    id: 'build-binary: teach the target table about android-arm64',
    find: `    'linux-arm64': {
      bunTarget: 'bun-linux-arm64',
      platform: 'linux',
      arch: 'arm64',
    },`,
    replace: `    'linux-arm64': {
      bunTarget: 'bun-linux-arm64',
      platform: 'linux',
      arch: 'arm64',
    },
    // Termux reports process.platform === 'android'. The bun target stays
    // 'bun-linux-arm64' on purpose: that is what makes Bun embed the *running*
    // patched runtime instead of downloading a stock glibc one, so the compiled
    // binary comes out Bionic-linked. See docs/PORTING-NOTES.md.
    'android-arm64': {
      bunTarget: 'bun-linux-arm64',
      platform: 'android',
      arch: 'arm64',
    },`,
    why: 'the build aborts with "Unsupported build target: android-arm64"',
  },

  {
    file: 'cli/scripts/build-binary.ts',
    id: 'build-binary: resolve native modules declared as npm aliases',
    find: `    const version = corePackage.packageJson.optionalDependencies?.[packageName]
    if (version !== expectedCoreVersion) {`,
    replace: `    // OpenTUI's Android build declares its native modules through npm
    // aliases -- e.g. "@opentui/core-android-arm64":
    // "npm:@androidtui/core-android-arm64@0.5.14" -- because those packages
    // exist only in another scope. The alias names the same version this target
    // implies, and its target is the name that resolves on the registry, so
    // install the target rather than the declared key.
    const declared =
      corePackage.packageJson.optionalDependencies?.[packageName]
    const alias = parseNpmAlias(declared)
    const version = alias ? alias.version : declared
    const installName = alias ? alias.name : packageName
    if (version !== expectedCoreVersion) {`,
    why: 'the declared spec is an alias string, so the version equality check fails and the build throws',
  },

  {
    file: 'cli/scripts/build-binary.ts',
    id: 'build-binary: install the alias target, not the declared key',
    find: `            ...(registry ? [\`--registry=\${registry}\`] : []),
            \`\${packageName}@\${version}\`,`,
    replace: `            ...(registry ? [\`--registry=\${registry}\`] : []),
            \`\${installName}@\${version}\`,`,
    why: 'bun install would request @opentui/core-android-arm64, which is not published, and 404',
  },

  {
    file: 'cli/scripts/build-binary.ts',
    id: 'build-binary: parseNpmAlias helper',
    find: `function getInstalledOpenTuiPackage(
  packageFolder: 'core' | 'react',`,
    replace: `/**
 * Split an npm alias dependency spec into the package it points at and its
 * version: "npm:@androidtui/core-android-arm64@0.5.14" becomes
 * { name: "@androidtui/core-android-arm64", version: "0.5.14" }.
 *
 * The final '@' separates the version, so a scoped name's leading '@' is not
 * mistaken for one.
 */
function parseNpmAlias(
  spec: unknown,
): { name: string; version: string } | null {
  if (typeof spec !== 'string') return null
  const match = /^npm:(.+)@([^@]+)$/.exec(spec)
  return match ? { name: match[1], version: match[2] } : null
}

function getInstalledOpenTuiPackage(
  packageFolder: 'core' | 'react',`,
    why: 'the alias parser referenced above has to exist',
  },

  {
    file: 'cli/scripts/build-binary.ts',
    id: 'build-binary: accept an aliased OpenTUI install',
    find: `  if (
    packageJson.name !== packageName ||
    packageJson.version !== expectedVersion
  ) {`,
    replace: `  // A package reached through an npm alias carries the *target's* name in its
  // own package.json, so requesting "@opentui/core" can legitimately yield
  // "@androidtui/core". Same package and version under a different scope; treat
  // that as a match rather than failing a build that is in fact consistent.
  const installedNameMatches =
    packageJson.name === packageName ||
    (typeof packageJson.name === 'string' &&
      packageJson.name.endsWith(\`/\${packageFolder}\`))

  if (
    !installedNameMatches ||
    packageJson.version !== expectedVersion
  ) {`,
    why: 'the name check rejects @androidtui/core even though the version is correct',
  },

  {
    file: 'cli/scripts/open-tui-native-bundle.ts',
    id: 'opentui-bundle: name libopentui.so on android',
    find: `    case 'linux':
      return 'libopentui.so'
    default:
      return null`,
    replace: `    case 'linux':
      return 'libopentui.so'
    // Bionic uses the same SONAME as glibc; only the ABI behind it differs.
    case 'android':
      return 'libopentui.so'
    default:
      return null`,
    why: 'readCompleteBundle() sees no library name and treats every android install as incomplete',
  },

  {
    file: 'cli/scripts/open-tui-native-bundle.ts',
    id: 'opentui-bundle: accept an aliased package name',
    find: `    return packageJson.name === getOpenTuiNativePackageName(targetInfo) &&`,
    replace: `    // The expected name may be an npm alias ("@opentui/core-android-arm64"),
    // in which case the installed package reports the alias target's name.
    const expectedName = getOpenTuiNativePackageName(targetInfo)
    const nameMatches =
      packageJson.name === expectedName ||
      (typeof packageJson.name === 'string' &&
        packageJson.name.endsWith('-android-arm64'))

    return nameMatches &&`,
    why: 'the completeness check rejects the installed @androidtui package',
  },

  {
    file: 'cli/src/native/ripgrep.ts',
    id: 'ripgrep: honour CODEBUFF_RG_PATH in compiled mode',
    find: `  if (!env.CODEBUFF_IS_BINARY) {
    return getBundledRgPath()
  }

  // Compiled mode - self-extract the embedded binary to the same directory as the current binary`,
    replace: `  if (!env.CODEBUFF_IS_BINARY) {
    return getBundledRgPath()
  }

  // An explicit override wins here too. Every embedded copy is a glibc build,
  // so on a host whose libc is not glibc the extracted binary cannot run at
  // all -- and because the extraction is only a write and a chmod it succeeds,
  // which means the failure surfaces later as a spawn error instead of being
  // routed to the working \`rg\` already on PATH.
  if (env.CODEBUFF_RG_PATH) {
    return env.CODEBUFF_RG_PATH
  }

  // Compiled mode - self-extract the embedded binary to the same directory as the current binary`,
    why: 'the CLI extracts a glibc rg that cannot exec on Bionic, silently disabling code search',
  },
]

let failed = false
let applied = 0
let skipped = 0

for (const edit of edits) {
  const path = join(root, edit.file)
  let source
  try {
    source = readFileSync(path, 'utf8')
  } catch {
    console.error(`FAIL  ${edit.id}\n      cannot read ${edit.file}`)
    failed = true
    continue
  }

  // Idempotence: if the replacement is already present, the edit is done.
  if (source.includes(edit.replace)) {
    console.log(`skip  ${edit.id} (already applied)`)
    skipped++
    continue
  }

  const first = source.indexOf(edit.find)
  if (first === -1) {
    console.error(
      `FAIL  ${edit.id}\n      anchor not found in ${edit.file} — upstream has changed.\n      Without it: ${edit.why}`,
    )
    failed = true
    continue
  }
  if (source.indexOf(edit.find, first + 1) !== -1) {
    console.error(
      `FAIL  ${edit.id}\n      anchor is ambiguous in ${edit.file} (matched more than once) — refusing to guess.`,
    )
    failed = true
    continue
  }

  const next =
    source.slice(0, first) + edit.replace + source.slice(first + edit.find.length)
  writeFileSync(path, next)
  console.log(`apply ${edit.id}`)
  applied++
}

console.log(
  `\n${applied} applied, ${skipped} already present, ${edits.length} total.`,
)
if (failed) {
  console.error('\nOne or more edits did not apply. Not writing a partial tree silently —')
  console.error('fix the anchors above, or pin FREEBUFF_REF to a commit these edits match.')
  process.exit(1)
}