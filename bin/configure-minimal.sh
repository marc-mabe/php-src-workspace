#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: configure-minimal.sh [arm64|amd64|i386] [extra configure args...]

Run ./buildconf and ./configure with a minimal debug build:
  --disable-all --enable-debug --enable-zend-test --enable-zend-int64

Configures an out-of-tree build in php-src/build/<arch> (override with
PHP_SRC_BUILD_DIR); run make from there.

When run on the host, this automatically executes inside the matching Docker
container.

The architecture may be omitted, in which case the host's is used. Use -- to
separate this script's arguments from ./configure's.

Examples:
  configure-minimal.sh
  configure-minimal.sh arm64
  configure-minimal.sh i386
EOF
}

parse_args "$@"
arch="${ARCH}"

configure_delegate_to_container "$(basename "$0")" "${arch}" ${ARGS[@]+"${ARGS[@]}"}

MINIMAL_CONFIGURE_ARGS=(
    --disable-all
    --enable-debug
    --enable-zend-test
)

configure_run "${arch}" "${MINIMAL_CONFIGURE_ARGS[@]}" ${ARGS[@]+"${ARGS[@]}"}
