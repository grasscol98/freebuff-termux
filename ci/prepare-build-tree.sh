#!/data/data/com.termux/files/usr/bin/bash
#
# Prepare a Freebuff checkout for an Android/Bionic build.
#
#   fetch upstream -> apply the configuration delta -> apply the patch set
#
# Both mutating steps are idempotent and fail loudly, so this is safe to re-run
# against a tree that was already prepared.
#
# Usage:
#   prepare-build-tree.sh <destination-dir> [ref]
#
#   destination-dir   where to clone/build. Wiped and recreated.
#   ref               upstream git ref. Defaults to $FREEBUFF_REF, then to the
#                     `freebuff.ref` pin in versions.json.

set -euo pipefail

DEST="${1:-}"
[ -n "${DEST}" ] || { echo "usage: $0 <destination-dir> [ref]" >&2; exit 2; }

WORKSPACE="${WORKSPACE:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
FREEBUFF_REPO="${FREEBUFF_REPO:-https://github.com/CodebuffAI/freebuff.git}"

if [ -z "${2:-}" ] && [ -z "${FREEBUFF_REF:-}" ]; then
	FREEBUFF_REF="$(node -e "console.log(require('${WORKSPACE}/versions.json').freebuff.ref)")"
fi
FREEBUFF_REF="${2:-${FREEBUFF_REF}}"
[ -n "${FREEBUFF_REF}" ] || { echo "error: no upstream ref given" >&2; exit 2; }

OTUI_VERSION="$(node -e "console.log(require('${WORKSPACE}/versions.json').opentui.core)")"

echo "upstream   ${FREEBUFF_REPO} @ ${FREEBUFF_REF}"
echo "opentui    ${OTUI_VERSION} (android build)"
echo "destination ${DEST}"

command -v git >/dev/null || { echo "error: git is required" >&2; exit 1; }
command -v node >/dev/null || { echo "error: node is required" >&2; exit 1; }

# Re-cloning a large monorepo over a phone connection costs real time, and both
# mutating steps are idempotent, so an existing tree can be reused. Opt in with
# FREEBUFF_PRESERVE_TREE=1. CI leaves this off and always builds from clean.
if [ "${FREEBUFF_PRESERVE_TREE:-0}" = "1" ] && [ -d "${DEST}/.git" ]; then
	echo "preserving the existing checkout at ${DEST}"
	cd "${DEST}"
else
	rm -rf "${DEST}"
	mkdir -p "${DEST}"

	# Shallow, single-branch. The lockfile is committed upstream, so this is enough
	# for a reproducible install and keeps the clone to a few tens of megabytes.
	git clone --depth 1 --single-branch --branch "${FREEBUFF_REF}" \
		"${FREEBUFF_REPO}" "${DEST}" 2>/dev/null ||
		git clone --depth 1 "${FREEBUFF_REPO}" "${DEST}"
fi

cd "${DEST}"
git rev-parse HEAD > .termux-upstream-commit 2>/dev/null || true

echo
echo "=== configuration delta ==="
node "${WORKSPACE}/ci/apply-config-delta.mjs" "${DEST}" "${OTUI_VERSION}"

echo
echo "=== patch set ==="
node "${WORKSPACE}/ci/apply-patches.mjs" "${DEST}"

echo
echo "Prepared $(basename "${DEST}") at $(git rev-parse --short HEAD) + termux delta."