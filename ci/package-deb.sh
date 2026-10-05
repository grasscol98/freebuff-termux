#!/usr/bin/env bash
#
# Package the build output as a Termux .deb.
#
# Layout, following Termux conventions:
#
#   data/data/com.termux/files/usr/bin/freebuff            the wrapper
#   data/data/com.termux/files/usr/bin/freebuff-diagnose   diagnostics
#   data/data/com.termux/files/usr/libexec/freebuff/freebuff        the binary
#   data/data/com.termux/files/usr/libexec/freebuff/tree-sitter.wasm
#
# The binary goes in libexec rather than bin so that `bin/freebuff` can be the
# wrapper: the CLI reads tree-sitter.wasm from dirname(process.execPath), so the
# asset has to sit beside the executable, and libexec is where an implementation
# detail belongs.
#
# Usage:
#   package-deb.sh <payload-dir> <version> <outdir>
#     <payload-dir>  directory produced by build-in-container.sh
#     <version>      e.g. "0.1.0"
#     <outdir>       directory to write freebuff_<version>_aarch64.deb into

set -euo pipefail

usage() { echo "usage: $0 <payload-dir> <version> <outdir>" >&2; exit 2; }

PAYLOAD="${1:-}"
VERSION="${2:-}"
OUTDIR="${3:-}"
[ -n "${PAYLOAD}" ] && [ -n "${VERSION}" ] && [ -n "${OUTDIR}" ] || usage

for required in freebuff tree-sitter.wasm freebuff-wrapper freebuff-diagnose; do
	[ -f "${PAYLOAD}/${required}" ] || {
		echo "error: ${PAYLOAD}/${required} is missing" >&2
		exit 1
	}
done
command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is not on PATH" >&2; exit 1; }

ARCH=aarch64
PKG=freebuff
# Some runners and Termux installs default to umask 077, which makes dpkg-deb
# reject DEBIAN/ for being mode 0700.
umask 0022

STAGE="$(mktemp -d)"
chmod 0755 "${STAGE}"
trap 'rm -rf "${STAGE}"' EXIT

P=data/data/com.termux/files/usr
mkdir -p "${STAGE}/${P}/bin" "${STAGE}/${P}/libexec/freebuff"

install -m 0755 "${PAYLOAD}/freebuff" "${STAGE}/${P}/libexec/freebuff/freebuff"
install -m 0644 "${PAYLOAD}/tree-sitter.wasm" "${STAGE}/${P}/libexec/freebuff/tree-sitter.wasm"
install -m 0755 "${PAYLOAD}/freebuff-wrapper" "${STAGE}/${P}/bin/freebuff"
install -m 0755 "${PAYLOAD}/freebuff-diagnose" "${STAGE}/${P}/bin/freebuff-diagnose"

# Record provenance next to the binary: a bug report that says which upstream
# commit and which OpenTUI build it came from is worth ten that do not.
mkdir -p "${STAGE}/${P}/share/freebuff"
[ -f "${PAYLOAD}/version" ] && install -m 0644 "${PAYLOAD}/version" "${STAGE}/${P}/share/freebuff/version"
[ -f "${PAYLOAD}/upstream-commit" ] && install -m 0644 "${PAYLOAD}/upstream-commit" "${STAGE}/${P}/share/freebuff/upstream-commit"

SIZE_KB=$(( ($(stat -c%s "${PAYLOAD}/freebuff") + 1023) / 1024 ))

mkdir -p "${STAGE}/DEBIAN"
cat > "${STAGE}/DEBIAN/control" <<EOF
Package: ${PKG}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: freebuff-termux <noreply@github.com>
Installed-Size: ${SIZE_KB}
Section: devel
Priority: optional
Homepage: https://github.com/CodebuffAI/freebuff
Description: The free coding agent, native Termux/Bionic build
 Freebuff compiled with a patched Bun runtime against the Android build of
 OpenTUI, so it runs on Android/Termux (aarch64) with no glibc userland and
 no proot. Not an official CodebuffAI release; see CREDITS.md.
EOF

# -Zxz is not optional. Ubuntu patches dpkg to default to zstd, which emits
# control.tar.zst + data.tar.zst. Termux's dpkg handles zstd only if it was built
# against libzstd, and otherwise shells out to a zstd binary that no Termux
# bootstrap ships, so installing such a deb on a device fails with
# "unable to execute decompressing archive ... member control.tar (zstd)".
# xz is the widest intersection: every Termux dpkg links liblzma.
mkdir -p "${OUTDIR}"
DEB="${OUTDIR}/${PKG}_${VERSION}_${ARCH}.deb"
dpkg-deb -Zxz --build --root-owner-group "${STAGE}" "${DEB}" >/dev/null
( cd "${OUTDIR}" && sha256sum "$(basename "${DEB}")" > "${PKG}_${VERSION}_${ARCH}.deb.sha256" )
echo "${DEB}"