#!/usr/bin/env node
// Freebuff-for-Termux configuration delta.
//
// Redirects Freebuff's OpenTUI dependency at the Android build of the same
// package, without touching the ~90 source files that import "@opentui/core".
//
// How the redirection works, and why it is two layers:
//
//   1. Root package.json `overrides` rewrites the *specifier* "@opentui/core" to
//      "npm:@androidtui/core@<v>". Every existing import now resolves to the
//      Android build. An npm alias installs the target's files under the
//      requested name, so the tree keeps `node_modules/@opentui/core` — which is
//      what the CLI's own build scripts resolve by path.
//
//   2. cli/package.json's version pins move to the OpenTUI release that the
//      Android build tracks. This matters more than it looks: the build script
//      reads these pins and asserts the installed version matches, so leaving
//      them at Freebuff's pin would fail every build with "does not match
//      cli/package.json". See ci/apply-patches.mjs.
//
// react-reconciler moves with it: @androidtui/react depends on ^0.33.0, and
// Freebuff pins ^0.32.0, which would otherwise install two reconcilers.
//
// Usage:  node ci/apply-config-delta.mjs <path-to-freebuff-checkout> <opentui-version>

import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const root = process.argv[2]
const otuiVersion = process.argv[3]

if (!root || !otuiVersion) {
  console.error(
    'usage: node ci/apply-config-delta.mjs <path-to-freebuff-checkout> <opentui-version>',
  )
  process.exit(2)
}
if (!/^\d+\.\d+\.\d+/.test(otuiVersion)) {
  console.error(`refusing to continue: "${otuiVersion}" is not a version`)
  process.exit(2)
}

const changes = []

function editJson(relativePath, mutate) {
  const path = join(root, relativePath)
  const original = readFileSync(path, 'utf8')
  const data = JSON.parse(original)
  const before = JSON.stringify(data)
  mutate(data)
  if (JSON.stringify(data) === before) {
    console.log(`skip  ${relativePath} (already at the target configuration)`)
    return
  }
  // Preserve upstream indentation and trailing newline.
  const indentMatch = original.match(/\n(\s+)"/)
  const indent = indentMatch ? indentMatch[1].length : 2
  writeFileSync(path, JSON.stringify(data, null, indent) + '\n')
  console.log(`apply ${relativePath}`)
  changes.push(relativePath)
}

// --- root package.json: the resolution redirect -----------------------------

editJson('package.json', (pkg) => {
  pkg.overrides = pkg.overrides ?? {}

  pkg.overrides['@opentui/core'] = `npm:@androidtui/core@${otuiVersion}`
  pkg.overrides['@opentui/react'] = `npm:@androidtui/react@${otuiVersion}`
  // The Android native module is not published under the @opentui scope at all,
  // so pin the alias here too. Freebuff's build script stages this package into
  // node_modules/@opentui/core-android-arm64 and Bun resolves the runtime import
  // through the same name.
  pkg.overrides['@opentui/core-android-arm64'] =
    `npm:@androidtui/core-android-arm64@${otuiVersion}`

  // Freebuff's root overrides pin React 19; @androidtui/react is built against
  // it, so leave the existing entry alone unless it is missing.
  if (!pkg.overrides.react) pkg.overrides.react = '^19.0.0'
})

// --- cli/package.json: version pins the build script asserts ----------------

editJson('cli/package.json', (pkg) => {
  const deps = pkg.dependencies ?? {}
  deps['@opentui/core'] = otuiVersion
  deps['@opentui/react'] = otuiVersion
  // Must match @androidtui/react's own react-reconciler range.
  deps['react-reconciler'] = '^0.33.0'
  pkg.dependencies = deps
})

// --- root package.json: drop deps that cannot install on Android ------------

editJson('package.json', (pkg) => {
  // "canvas" is a native module: it compiles against cairo, pango and their
  // headers, none of which exist in an Android Bionic sysroot, so `bun install`
  // fails outright trying to build it. It is reachable only from
  // scripts/tmux/mux-viewer/gif-exporter.ts, a development tool for viewing tmux
  // session recordings that has no dependency entry of its own -- both packages
  // are declared solely by the root manifest.
  //
  // Neither is imported from the CLI entry point, so `bun build src/entry.ts
  // --compile` never bundles them. Dropping them costs nothing that the shipped
  // binary could have used, and removes the only native build from the graph.
  for (const native of ['canvas', 'gif-encoder-2']) {
    if (pkg.dependencies?.[native]) {
      delete pkg.dependencies[native]
    }
  }
})

// --- report -----------------------------------------------------------------

console.log(`\nOpenTUI redirected to the Android build at ${otuiVersion}.`)
if (changes.length) {
  console.log(`Files changed: ${[...new Set(changes)].join(', ')}`)
} else {
  console.log('No changes were needed.')
}
console.log(
  '\nNext: node ci/apply-patches.mjs <checkout>   (or it has already run)',
)