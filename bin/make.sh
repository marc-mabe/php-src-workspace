#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: make.sh [arm64|amd64|arm32|i386] [make args...]

Run make in the out-of-tree build directory for the given architecture
(/php-src/build/<arch>), inside the matching container. The architecture may be
omitted, in which case the host's is used. Defaults to -j"$(nproc)" when no
make arguments are given.

Use -- to separate this script's arguments from make's.

Examples:
  make.sh
  make.sh arm64
  make.sh i386 -- test TESTS=tests/basic
  make.sh amd64 -- clean
  make.sh -- -n
EOF
}

parse_args "$@"
arch="${ARCH}"

build_dir="$(php_build_dir "${CONTAINER_REPO}" "${arch}")"

if [[ ${#ARGS[@]} -eq 0 ]]; then
    ARGS=(-j'"$(nproc)"')
fi

exec "${SCRIPT_DIR}/shell.sh" "${arch}" \
    "cd $(printf '%q' "${build_dir}") && exec make ${ARGS[*]}"
