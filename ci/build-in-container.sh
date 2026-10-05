#!/data/data/com.termux/files/usr/bin/bash
#
# Build Freebuff as a native Android/Bionic executable.
#
# Runs INSIDE termux-docker (aarch64), which is a real Termux userland. That
# matters for three reasons, all of which have bitten this build before:
#
#   * The patched Bun runtime is a Bionic executable. It cannot be run under a
#     glibc container, and it must be the *same* Bun that performs the compile,
#     because `bun build --compile --target=bun-linux-arm64` reuses the running
#     runtime as the base of the output. Running the compile under any other
#     Bun silently produces a glibc-linked binary.
#   * Bun's FFI is used to load OpenTUI's native library, and the patched runtime
#     needs its launcher wrapper rather than the raw ELF.
#   * Freebuff's build resolves `@opentui/core-linux-arm64` and friends during
#     `bun build`, which only resolve against a Linux-shaped registry view.
#
# Mounts:
#   /workspace  this repository (read-only in practice)
#   /out        writable host directory for the artifact
#
# Env (passed through /out/build-env.sh, because the container entrypoint
# discards inherited environment):
#   FREEBUFF_VERSION      version string baked into the binary
#   FREEBUFF_UPSTREAM_REF optional; build this ref instead of the versions.json pin
#   BUILD_DIR             optional; default /tmp/freebuff-build

set -euo pipefail

if [ -f /out/build-env.sh ]; then
	# shellcheck disable=SC1091
	. /out/build-env.sh
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; MUTED='\033[0;2m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "  ${MUTED}       $*${NC}"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BUILD_DIR="${BUILD_DIR:-/tmp/freebuff-build}"
WORKSPACE="${WORKSPACE:-/workspace}"

FREEBUFF_VERSION="${FREEBUFF_VERSION:-0.0.0-termux-ci}"
FREEBUFF_UPSTREAM_REF="${FREEBUFF_UPSTREAM_REF:-}"

# ---------------------------------------------------------------------------
echo "=========================================="
echo " Freebuff -> Android/Bionic (aarch64)"
echo "=========================================="
id || true
info "PREFIX=${PREFIX}"
info "version=${FREEBUFF_VERSION}"
info "ref=${FREEBUFF_UPSTREAM_REF:-<versions.json pin>}"
mount | grep -E 'workspace|out' || true
(touch /out/.w && rm -f /out/.w && echo "/out: writable") || fail "/out is not writable"
echo "=========================================="

# --- dependencies -----------------------------------------------------------

echo "deb https://packages.termux.dev/apt/termux-main stable main" \
	> "${PREFIX}/etc/apt/sources.list"
apt update -y >/dev/null
apt install -y git nodejs python curl dpkg file >/dev/null

# --- the patched Bun runtime ------------------------------------------------

BUN_VERSION="$(node -e "console.log(require('${WORKSPACE}/versions.json').bunTermux.version)")"
BUN_DEB="bun_${BUN_VERSION}_aarch64.deb"
BUN_URL="$(node -e "console.log(require('${WORKSPACE}/versions.json').bunTermux.debUrlTemplate.replace('{version}','${BUN_VERSION}'))")"

echo
echo "=== bun-termux ${BUN_VERSION} ==="
info "${BUN_URL}"
curl -fsSL -o /tmp/"${BUN_DEB}" "${BUN_URL}" || fail "could not download the patched Bun"
dpkg -i /tmp/"${BUN_DEB}" >/dev/null 2>&1 || dpkg -i /tmp/"${BUN_DEB}" || fail "dpkg -i failed for the patched Bun"
rm -f /tmp/"${BUN_DEB}"

BUN="${PREFIX}/bin/bun"
INSTALLED="$("${BUN}" --version)"
EXPECTED="${BUN_VERSION%%-patched}"
[ "${INSTALLED}" = "${EXPECTED}" ] || fail "expected bun ${EXPECTED}, got ${INSTALLED}"
ok "bun ${INSTALLED} (patched)"

# The FFI dlopen path needs the launcher script, not the raw ELF. Termux's own
# `bun` package ships the raw binary, which crashes on FFI during the build.
BUN_FILE="$(file -b "${BUN}" 2>/dev/null || echo unknown)"
info "bun is: ${BUN_FILE}"
case "${BUN_FILE}" in
	*ELF*) fail "${BUN} is a raw ELF, not the launcher. OpenTUI's FFI will crash the build.
       Install the patched runtime from versions.json, not Termux's stock bun package." ;;
esac

# --- prepare the source tree ------------------------------------------------

echo
echo "=== preparing the source tree ==="
mkdir -p "${BUILD_DIR}"
CLONE_ARGS=("${BUILD_DIR}/src")
[ -n "${FREEBUFF_UPSTREAM_REF}" ] || {
	# No ref override: let prepare-build-tree.sh use the versions.json pin.
	true
}
bash "${WORKSPACE}/ci/prepare-build-tree.sh" "${BUILD_DIR}/src" ${FREEBUFF_UPSTREAM_REF:+"${FREEBUFF_UPSTREAM_REF}"}
cd "${BUILD_DIR}/src"

# ---------------------------------------------------------------------------
# bun install
#
# The lockfile is committed upstream but was resolved for glibc platforms, and
# the override redirects @opentui/* to @androidtui/*, so the tree has to be
# re-resolved rather than installed from the frozen lockfile.
# ---------------------------------------------------------------------------
echo
echo "=== bun install ==="
bun install || fail "bun install failed"

info "resolving @opentui/core ..."
RESOLVED="$(node -e "
const p = require('${BUILD_DIR}/src/node_modules/@opentui/core/package.json');
console.log(p.name + '@' + p.version);
" 2>/dev/null || echo '<not installed>')"
info "-> ${RESOLVED}"
case "${RESOLVED}" in
	@androidtui/core@*) ok "OpenTUI redirected to the Android build" ;;
	*) fail "expected @opentui/core to resolve to @androidtui/core, got ${RESOLVED}.
       The configuration delta did not take effect." ;;
esac

# The Android native module must be present or bun build --compile cannot
# resolve the FFI import.
if [ -d "${BUILD_DIR}/src/node_modules/@opentui/core-android-arm64" ]; then
	ok "native module staged at node_modules/@opentui/core-android-arm64"
	find "${BUILD_DIR}/src/node_modules/@opentui/core-android-arm64" -name '*.so' -exec ls -la {} \;
else
	warn "node_modules/@opentui/core-android-arm64 is missing; the build script"
	warn "will stage it, but if this persists check versions.json's opentui pin."
fi

# --- compile ----------------------------------------------------------------

echo
echo "=== compiling ==="
# freebuff/cli/build.ts wraps cli/scripts/build-binary.ts with FREEBUFF_MODE=true,
# which is what makes the result the free, ad-supported product rather than
# Codebuff. It reads process.platform, which the patched build script maps to the
# android-arm64 target.
export FREEBUFF_MODE=true
bun run freebuff/cli/build.ts "${FREEBUFF_VERSION}" 2>&1 | sed 's/^/    /' ||
	fail "the build failed"

BINARY="${BUILD_DIR}/src/cli/bin/freebuff"
[ -f "${BINARY}" ] || fail "expected a binary at ${BINARY}, found: $(ls -la "${BUILD_DIR}/src/cli/bin" 2>/dev/null || echo '<no bin dir>')"
[ -x "${BINARY}" ] || chmod 0755 "${BINARY}"

ok "built $(du -h "${BINARY}" | cut -f1)"

# --- verify it is really Bionic --------------------------------------------
#
# A build that silently came out glibc is the single most likely failure of this
# whole exercise, and it fails on the user's phone rather than here. Refuse to
# publish it.
echo
echo "=== verifying the artifact ==="
INTERP="$(readelf -lW "${BINARY}" 2>/dev/null | awk '/INTERP/{getline; print $NF}' | head -n1)"
MACHINE="$(readelf -hW "${BINARY}" 2>/dev/null | awk -F: '/Machine/{gsub(/^ +/,"",$2); print $2}')"
info "machine:    ${MACHINE}"
info "interpreter: ${INTERP:-none}"
case "${MACHINE}" in
	*AArch64*|*aarch64*) : ;;
	*) fail "wrong machine type: ${MACHINE}" ;;
esac
case "${INTERP}" in
	/system/bin/linker*) ok "Bionic interpreter -- this is an Android binary" ;;
	"")                  warn "no PT_INTERP: the binary is static. That may be fine, but it is not what this build expects from the patched runtime." ;;
	*)                   fail "interpreter is '${INTERP}', not a Bionic linker. This is a glibc build and will not run on Android. Refusing to publish it." ;;
esac

# tree-sitter.wasm has to sit next to the binary; the CLI reads it from
# dirname(process.execPath) at startup.
WASM="${BUILD_DIR}/src/cli/bin/tree-sitter.wasm"
if [ -f "${WASM}" ]; then
	ok "tree-sitter.wasm staged beside the binary"
else
	fail "tree-sitter.wasm is missing from cli/bin; the CLI reads it from beside itself at startup"
fi

# --- smoke test -------------------------------------------------------------
echo
echo "=== smoke test ==="
if OUT="$("${BINARY}" --version 2>&1)"; then
	ok "${OUT%%$'\n'*}"
else
	warn "'--version' failed; the binary may still work. Output:"
	printf '%s\n' "${OUT}" | sed 's/^/    /' >&2
	warn "Termux disallows executing from noexec mounts; check the path if this"
	warn "looks like a loader error rather than an application error."
fi

# --- publish ----------------------------------------------------------------
echo
echo "=== publishing ==="
STAGE="/out/payload"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp "${BINARY}" "${STAGE}/freebuff"
cp "${WASM}" "${STAGE}/tree-sitter.wasm"
chmod 0755 "${STAGE}/freebuff"
cp "${WORKSPACE}/freebuff" "${STAGE}/freebuff-wrapper"
cp "${WORKSPACE}/diagnose.sh" "${STAGE}/freebuff-diagnose"
cp "${BUILD_DIR}/src/.termux-upstream-commit" "${STAGE}/upstream-commit" 2>/dev/null || true
printf '%s\n' "${FREEBUFF_VERSION}" > "${STAGE}/version"

( cd "${STAGE}" && sha256sum freebuff tree-sitter.wasm > /out/SHA256SUMS )
ls -la "${STAGE}"
echo "done."