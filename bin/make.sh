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

# Arguments are quoted individually, so a make variable holding spaces arrives
# as one word: `make.sh i386 -- test TEST_PHP_ARGS="-q -j10"`. Joining them into
# a bare string instead would let the container shell re-split it.
#
# The no-argument default is the exception: $(nproc) has to be expanded by the
# container, which has its own CPU count, so it goes in unquoted.
if [[ ${#ARGS[@]} -eq 0 ]]; then
    make_cmd='exec make -j"$(nproc)"'
else
    make_cmd="exec make $(printf '%q ' "${ARGS[@]}")"
fi

exec "${SCRIPT_DIR}/shell.sh" "${arch}" \
    "cd $(printf '%q' "${build_dir}") && ${make_cmd}"
