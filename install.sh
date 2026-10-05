#!/data/data/com.termux/files/usr/bin/bash
#
# Freebuff for Termux — installer
#
# Installs the prebuilt Bionic .deb published by this repository's Releases.
# Deliberately does NOT use `npm install -g freebuff`, for two independent
# reasons, either of which is fatal on its own:
#
#   1. The npm package declares os: ["darwin","linux","win32"], and Node on
#      Termux reports process.platform === "android", so npm refuses it with
#      EBADPLATFORM.
#   2. More fundamentally, that package downloads a glibc-linked Bun binary
#      (freebuff-linux-arm64.tar.gz) which Android's Bionic linker cannot
#      execute. There is no flag that makes it work; it needs a glibc userland.
#
# The .deb here is a real Bionic executable, built with a patched Bun runtime and
# the @androidtui OpenTUI build. See CREDITS.md and docs/PORTING-NOTES.md.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/grasscol98/freebuff-termux/main/install.sh | bash
#   ./install.sh                     install or upgrade to the latest release
#   ./install.sh --version X.Y.Z     install a specific release
#   ./install.sh --force             reinstall even if the same version is present
#   ./install.sh --uninstall         remove the package, keep logins and settings
#   ./install.sh --help
#
#   License: Apache-2.0.

set -eu

REPO="${FREEBUFF_TERMUX_REPO:-grasscol98/freebuff-termux}"
PACKAGE="freebuff"
PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
DEB_NAME() { printf '%s_%s_aarch64.deb' "${PACKAGE}" "$1"; }

FORCE=0
REQUESTED_VERSION=""
MODE="install"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
	YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
	BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info() { printf '%s==>%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '%swarn:%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "${RED}" "${RESET}" "$*" >&2; exit 1; }
step() { printf '%s->%s %s\n' "${BOLD}" "${RESET}" "$*"; }

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required. Install it with: pkg install $2"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--version|-v) REQUESTED_VERSION="${2:-}"; [ -n "${REQUESTED_VERSION}" ] || fail "--version needs a value"; shift 2 ;;
		--force|-f)   FORCE=1; shift ;;
		--uninstall)  MODE="uninstall"; shift ;;
		--help|-h)    usage ;;
		*)            fail "unknown argument: $1 (try --help)" ;;
	esac
done

# --- preflight --------------------------------------------------------------

case "${PREFIX:-}" in
	*com.termux*) : ;;
	*) fail "this installer only runs inside Termux.
  On a normal Linux host, install Freebuff the supported way instead:
    npm install -g freebuff" ;;
esac

case "$(uname -m)" in
	aarch64|arm64) : ;;
	*) fail "this port is aarch64 only (you have $(uname -m)).
  There is no 32-bit Android build of Bun or of OpenTUI, so there is nothing to
  install. On a 32-bit device the supported route is proot-distro." ;;
esac

if [ "${MODE}" = "uninstall" ]; then
	step "Removing Freebuff (logins and settings are kept)"
	dpkg -r "${PACKAGE}" 2>/dev/null || warn "dpkg -r reported an error; continuing"
	rm -f "${PREFIX_DIR}/bin/freebuff-diagnose"
	info "Done. ${HOME}/.config/manicode was left in place; delete it to remove logins and settings."
	exit 0
fi

need curl curl
need dpkg dpkg
need tar tar

# --- installed version ------------------------------------------------------

installed_version() {
	# The .deb records its own version; do not execute the binary just to ask.
	dpkg-query -W -f='${Version}' "${PACKAGE}" 2>/dev/null || true
}

if [ "${FORCE}" -eq 0 ] && [ -z "${REQUESTED_VERSION}" ]; then
	INSTALLED="$(installed_version)"
	if [ -n "${INSTALLED}" ]; then
		info "Freebuff ${INSTALLED} is already installed."
		info "Re-run with --force to reinstall, or --version <tag> for a specific release."
		exit 0
	fi
fi

# --- version resolution -----------------------------------------------------

api() {
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H 'Accept: application/vnd.github+json' "$1"
	else
		curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
	fi
}

if [ -n "${REQUESTED_VERSION}" ]; then
	TAG="v${REQUESTED_VERSION}"
	VERSION="${REQUESTED_VERSION}"
else
	step "Resolving the latest release"
	TAG="$(api "https://api.github.com/repos/${REPO}/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
	[ -n "${TAG}" ] || fail "could not resolve the latest release from ${REPO}.
  Check access to api.github.com, or pass --version <tag>.
  There are no published releases yet: this port is untested, so no .deb has been
  built. Once you have built one, publish it as a release asset named
  freebuff_<version>_aarch64.deb plus a SHA256SUMS, and this installer will find
  it. See 'Building from source' in README.md."
	VERSION="${TAG#v}"
fi

info "Freebuff ${VERSION} for Termux (aarch64, native Bionic build)"

# --- download and verify ----------------------------------------------------

TMP="$(mktemp -d "${TMPDIR:-${PREFIX_DIR}/tmp}/freebuff-install.XXXXXX")"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

BASE="https://github.com/${REPO}/releases/download/${TAG}"
DEB="$(DEB_NAME "${VERSION}")"

step "Downloading ${DEB}"
curl -fL --progress-bar -o "${TMP}/${DEB}" "${BASE}/${DEB}" || fail \
"download failed: ${BASE}/${DEB}

If you are building this port yourself, publish an artifact first:
  ./ci/build-in-container.sh && ./ci/package-deb.sh"

step "Verifying checksum"
# Guards against a truncated or corrupted download. Not a supply-chain boundary:
# whoever can replace the asset can replace the file beside it. If that matters,
# verify SHA256SUMS against a copy you trust.
if curl -fsSL -o "${TMP}/SHA256SUMS" "${BASE}/SHA256SUMS" 2>/dev/null; then
	( cd "${TMP}" && grep " ${DEB}\$" SHA256SUMS | sha256sum -c - ) ||
		fail "checksum mismatch for ${DEB} — refusing to install"
else
	warn "no SHA256SUMS published for ${TAG}; skipping verification"
fi

# --- install ----------------------------------------------------------------

step "Installing with dpkg"
# dpkg -i is used rather than `pkg install` because this package is not in the
# Termux repository; it comes from this project's GitHub Releases.
dpkg -i "${TMP}/${DEB}" 2>&1 | sed 's/^/    /' || fail "dpkg -i failed. Try manually: dpkg -i ${DEB}"

# The .deb ships the wrapper as a postinst hook, but a reinstall that skips
# maintainer scripts would leave it missing, so make sure it is there.
if [ ! -x "${PREFIX_DIR}/bin/freebuff-diagnose" ] && [ -f "$(dirname "$0")/diagnose.sh" ]; then
	install -m 755 "$(dirname "$0")/diagnose.sh" "${PREFIX_DIR}/bin/freebuff-diagnose"
fi

# --- dependency hints -------------------------------------------------------

MISSING=""
command -v git >/dev/null 2>&1 || MISSING="${MISSING} git"
command -v rg  >/dev/null 2>&1 || MISSING="${MISSING} ripgrep"
if [ -n "${MISSING}" ]; then
	warn "missing:${MISSING}"
	warn "Freebuff shells out to both. Without ripgrep, code search and the"
	warn "file-finding agents are disabled. Install with:"
	warn "  pkg install${MISSING}"
fi

# --- smoke test -------------------------------------------------------------

step "Smoke test"
if OUT="$("${PREFIX_DIR}/bin/freebuff" --version 2>&1)"; then
	info "OK — $(printf '%s' "${OUT}" | head -n1)"
else
	warn "'freebuff --version' failed. Output:"
	printf '%s\n' "${OUT}" | sed 's/^/    /' >&2 || true
	warn "This is usually a missing CA bundle or an old Android page size."
	warn "Run 'freebuff --diagnose' and open an issue with the output."
fi

cat <<EOF

$(printf '%s' "${GREEN}")Installed Freebuff ${VERSION}.${RESET}

  cd ~/your-project
  freebuff

First launch asks you to sign in.

If anything misbehaves, start with:

  freebuff --diagnose

Docs: README.md, docs/TROUBLESHOOTING.md, docs/PORTING-NOTES.md
Credits: CREDITS.md
EOF