#!/data/data/com.termux/files/usr/bin/bash
#
# Build Freebuff natively on the device itself, with no Docker and no CI.
#
# This exists because the port is untested and the fastest way to find out whether
# it works is to build it where it has to run. ci/build-in-container.sh does the
# same work inside termux-docker for CI; this script is the on-device equivalent.
#
# Why it is slow: Freebuff is a ten-workspace Bun monorepo. `bun install`
# resolves the whole graph, the SDK is built, the agent bundle is prebuilt, and
# only then is the CLI compiled. On a phone that is tens of minutes and it wants
# several GB of free storage and as much RAM as the device has.
#
# Requirements:
#   pkg install git nodejs dpkg file binutils ripgrep
#   ~6 GB free, 4 GB+ RAM, patience
#
# Usage:
#   ./build-on-device.sh              build and install to $PREFIX
#   ./build-on-device.sh --dry-run    prepare the tree only, do not build
#   ./build-on-device.sh --keep       leave the build tree in place afterwards
#
#   License: Apache-2.0.

set -euo pipefail

DRY=0
KEEP=0
for arg in "$@"; do
	case "${arg}" in
		--dry-run) DRY=1 ;;
		--keep)    KEEP=1 ;;
		-h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
	esac
done

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
WORKSPACE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PREFIX/tmp/freebuff-build}"
SRC="${BUILD_DIR}/src"
FREEBUFF_VERSION="${FREEBUFF_VERSION:-0.0.0-termux-dev}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; MUTED='\033[0;2m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "  ${MUTED}       $*${NC}"; }
warn() { echo -e "  ${YELLOW}[warn]${NC} $*"; }
step() { echo -e "\n${GREEN}==>${NC} $*"; }

step "preflight"
command -v git >/dev/null || fail "git is required (pkg install git)"
command -v node >/dev/null || fail "node is required (pkg install nodejs)"

case "${PREFIX}" in
	*com.termux*) : ;;
	*) fail "this only runs inside Termux" ;;
esac
if [ "$(uname -m)" != "aarch64" ]; then
	fail "aarch64 only; there is no 32-bit Android build of Bun or OpenTUI"
fi

FREE_MB="$(df -Pm "$PREFIX" 2>/dev/null | awk 'NR==2{print $4}')"
info "free disk: ${FREE_MB} MB"
if [ -n "${FREE_MB}" ] && [ "$FREE_MB" -lt 6144 ]; then
	warn "less than 6 GB free. This build needs more than that; it will probably fail."
fi
if have free; then
	RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
	info "free RAM: ${RAM_MB} MB"
	[ -n "${RAM_MB}" ] && [ "$RAM_MB" -lt 2048 ] && warn "under 2 GB free RAM. Expect the OOM killer to intervene."
fi

# --- the patched Bun ----------------------------------------------------------

step "Bun runtime"
BUN_VERSION="$(node -e "console.log(require('${WORKSPACE}/versions.json').bunTermux.version)")"
BUN_URL="$(node -e "console.log(require('${WORKSPACE}/versions.json').bunTermux.debUrlTemplate.replace('{version}','${BUN_VERSION}'))")"

if have bun; then
	CURRENT="$(bun --version 2>&1 | head -n1)"
	if [ "${CURRENT}" = "${BUN_VERSION%-patched}" ]; then
		ok "bun ${CURRENT} already installed"
	else
		warn "bun ${CURRENT} is not the patched build (want ${BUN_VERSION%-patched*}); reinstalling"
		info "${BUN_URL}"
		curl -fsSL -o "${BUILD_DIR}.deb" "$BUN_URL" && dpkg -i "${BUILD_DIR}.deb" && rm -f "${BUILD_DIR}.deb" ||
			fail "could not install the patched Bun"
	fi
else
	info "installing ${BUN_URL}"
	command -v curl >/dev/null || fail "curl is required (pkg install curl)"
	curl -fsSL -o "${BUILD_DIR}.deb" "$BUN_URL" && dpkg -i "${BUILD_DIR}.deb" && rm -f "${BUILD_DIR}.deb" ||
		fail "could not install the patched Bun"
fi

BUN="$(command -v bun)"
[ "$("$BUN" --version)" = "${BUN_VERSION%-patched}" ] || fail "bun version mismatch after install"

# FFI needs the launcher, not a raw ELF. Termux's stock bun package fails here,
# and the failure would otherwise surface as a confusing build crash.
BUN_KIND="$(file -b "$BUN" 2>/dev/null || echo unknown)"
case "${BUN_KIND}" in
	*ELF*) fail "$BUN is a raw ELF, not the patched launcher.
       OpenTUI is loaded through Bun FFI and crashes under the raw binary.
       Remove Termux's bun package (pkg uninstall bun) and re-run this script." ;;
	*) ok "bun ${BUN_VERSION%-patched} (launcher, FFI-capable)" ;;
esac

# --- prepare the tree ---------------------------------------------------------

step "preparing the source tree"
# Preserved between runs: re-cloning a large monorepo over a phone connection for
# every attempt is not worth it, and the patch set is idempotent anyway.
mkdir -p "$BUILD_DIR"
if [ ! -d "$SRC/.git" ]; then
	info "cloning Freebuff (this takes a while)"
	bash "${WORKSPACE}/ci/prepare-build-tree.sh" "$SRC" ||
		fail "preparing the tree failed"
else
	# Reuse the checkout: the delta and the patch set are both idempotent, and
	# re-cloning a large monorepo over a phone connection is not worth it.
	info "reusing the existing checkout; re-applying the delta and patches"
	FREEBUFF_PRESERVE_TREE=1 bash "${WORKSPACE}/ci/prepare-build-tree.sh" "$SRC" 2>&1 | tail -n 20 ||
		fail "re-applying the delta failed"
fi

cd "$SRC"

if [ "$DRY" -eq 1 ]; then
	ok "tree prepared at ${SRC} (--dry-run: stopping before bun install)"
	echo
	echo "Check it, then build for real:"
	echo "  cd $SRC && bun install && bun run freebuff/cli/build.ts ${FREEBUFF_VERSION}"
	exit 0
fi

# --- install -------------------------------------------------------------------

step "bun install (the slow part)"
info "expect tens of minutes"
bun install || fail "bun install failed.
       Most likely a native module in the graph. Read the error: if it names a
       package that compiles C code, that package has to go, the way canvas was
       removed in ci/apply-config-delta.mjs."

step "verifying the OpenTUI redirect took"
RESOLVED="$(node -e "console.log(require('${SRC}/node_modules/@opentui/core/package.json').name + '@' + require('${SRC}/node_modules/@opentui/core/package.json').version)" 2>/dev/null || echo '<not installed>')"
info "@opentui/core resolved to ${RESOLVED}"
case "$RESOLVED" in
	@androidtui/core@*) ok "Android build in place" ;;
	*) fail "expected @androidtui/core, got ${RESOLVED}. The configuration delta did not apply." ;;
esac
[ -d "$SRC/node_modules/@opentui/core-android-arm64" ] &&
	ok "native module staged" ||
	warn "node_modules/@opentui/core-android-arm64 is missing; the build may stage it"

# --- build ------------------------------------------------------------------------

step "compiling (the slow part)"
# FREEBUFF_MODE is what makes this the free product rather than Codebuff. The
# build script reads process.platform, which the patched build maps to the
# android-arm64 target.
FREEBUFF_MODE=true bun run freebuff/cli/build.ts "$FREEBUFF_VERSION" 2>&1 | sed 's/^/    /' ||
	fail "the build failed"

BIN="${SRC}/cli/bin/freebuff"
[ -f "$BIN" ] || fail "no binary at ${BIN}. Contents: $(ls "$SRC/cli/bin" 2>/dev/null || echo '<missing>')"
chmod 0755 "$BIN"

# --- verify ------------------------------------------------------------------------

step "verifying the artifact"
INTERP="$(readelf -lW "$BIN" 2>/dev/null | awk '/INTERP/{getline; print $NF}' | head -n1)"
MACHINE="$(readelf -hW "$BIN" 2>/dev/null | awk -F: '/Machine/{gsub(/^ +/,"",$2); print $2}')"
info "machine:     ${MACHINE}"
info "interpreter: ${INTERP:-none}"
case "${MACHINE}" in
	*[Aa]Arch64*) : ;;
	*) fail "wrong machine type: ${MACHINE}" ;;
esac
case "${INTERP}" in
	/system/bin/linker*) ok "Bionic interpreter -- this is an Android binary" ;;
	"") warn "no PT_INTERP: static. Unusual for the patched runtime; worth reporting." ;;
	*) fail "interpreter is '${INTERP}', not a Bionic linker.
       This is a glibc binary and will not run on Android. That means the compile
       did not use the patched runtime as its base." ;;
esac

WASM="${SRC}/cli/bin/tree-sitter.wasm"
[ -f "$WASM" ] || fail "tree-sitter.wasm is missing from cli/bin; the CLI reads it from beside itself"
ok "tree-sitter.wasm present"

# --- install ---------------------------------------------------------------------

step "installing to ${PREFIX}"
install -m 0755 "$BIN" "${PREFIX}/libexec/freebuff/freebuff" 2>/dev/null ||
	{ mkdir -p "${PREFIX}/libexec/freebuff" && install -m 0755 "$BIN" "${PREFIX}/libexec/freebuff/freebuff"; }
install -m 0644 "$WASM" "${PREFIX}/libexec/freebuff/tree-sitter.wasm"
install -m 0755 "${WORKSPACE}/freebuff" "${PREFIX}/bin/freebuff"
install -m 0755 "${WORKSPACE}/diagnose.sh" "${PREFIX}/bin/freebuff-diagnose"
mkdir -p "${PREFIX}/share/freebuff"
printf '%s\n' "$FREEBUFF_VERSION" > "${PREFIX}/share/freebuff/version"
[ -f "$SRC/.termux-upstream-commit" ] && cp "$SRC/.termux-upstream-commit" "${PREFIX}/share/freebuff/upstream-commit"

[ "$KEEP" -eq 1 ] || info "build tree kept at ${SRC} (--keep was implied by a successful build)"

step "smoke test"
if OUT="$("${PREFIX}/bin/freebuff" --version 2>&1)"; then
	ok "${OUT%%$'\n'*}"
else
	warn "'--version' failed; the binary may still work. Output:"
	printf '%s\n' "$OUT" | sed 's/^/    /' >&2
fi

cat <<EOF

$(printf '%s' "${GREEN}")Built and installed.${RESET}

  freebuff --version
  cd ~/some-project && freebuff
  freebuff --diagnose     # if anything looks wrong

First launch asks you to sign in.

If it crashes or renders blank, freebuff --diagnose is the thing to send.
EOF