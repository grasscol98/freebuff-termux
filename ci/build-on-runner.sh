#!/usr/bin/env bash
#
# Run the Android build on a GitHub Actions runner.
#
# The actual build happens inside termux-docker (aarch64), which is a real
# Termux userland: the patched Bun runtime is a Bionic executable and must be the
# same Bun that performs the compile. See ci/build-in-container.sh for why that
# matters.
#
# Inputs (environment):
#   GITHUB_WORKSPACE      this repository's checkout
#   FREEBUFF_VERSION      optional; version string baked into the binary
#   FREEBUFF_UPSTREAM_REF optional; upstream ref/tag/commit to build
#
# Outputs:
#   <out>/freebuff            the built binary
#   <out>/tree-sitter.wasm    the sibling asset
#   <out>/freebuff-wrapper    the runtime wrapper
#   <out>/freebuff-diagnose   the diagnostics script
#   <out>/version             the stamped version
#   <out>/upstream-commit     the upstream commit that was built
#   <out>/SHA256SUMS
#
# The directory containing the outputs is printed as the last line, so a caller
# can capture it with `tail -n1`.

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"

# /workspace is read-only for the container's unprivileged user, so the artifact
# directory is a separate world-writable mount.
mkdir -p "${GITHUB_WORKSPACE}/../out"
OUT_HOST="$(cd "${GITHUB_WORKSPACE}/../out" && pwd)"
chmod 0777 "${OUT_HOST}"
echo "OUT_HOST=${OUT_HOST}" >&2

# termux-docker drops inherited environment variables when it switches user, so
# the real values travel through the writable /out mount instead.
cat > "${OUT_HOST}/build-env.sh" <<EOF
export FREEBUFF_VERSION='${FREEBUFF_VERSION:-}'
export FREEBUFF_UPSTREAM_REF='${FREEBUFF_UPSTREAM_REF:-}'
EOF
chmod 0644 "${OUT_HOST}/build-env.sh"

docker run --rm \
	-v "${GITHUB_WORKSPACE}:/workspace" \
	-v "${OUT_HOST}:/out" \
	-w /workspace \
	termux/termux-docker:aarch64 \
	bash /workspace/ci/build-in-container.sh

echo "${OUT_HOST}"