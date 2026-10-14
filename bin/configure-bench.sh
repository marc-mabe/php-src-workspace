#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: configure-bench.sh [arm64|amd64|arm32|i386] [extra configure args...]

Run ./buildconf and ./configure for a release build fit for benchmarking and
profiling: the configuration of php-src's own BENCHMARKING CI job, which is
what benchmark/benchmark.php expects (cli and cgi SAPIs, mbstring, sockets,
mysqli, openssl, gmp, pdo_sqlite, no debug).

Configures php-src/build/<arch>-bench (PHP_SRC_BUILD_VARIANT=bench), next to
the debug build rather than over it. bin/bench.sh runs this when the directory
is not configured yet.

When run on the host, this automatically executes inside the matching Docker
container. The architecture may be omitted, in which case the host's is used.
Use -- to separate this script's arguments from ./configure's.

Examples:
  configure-bench.sh
  configure-bench.sh amd64 -- --disable-opcache-jit
EOF
}

parse_args "$@"
arch="${ARCH}"

export PHP_SRC_BUILD_VARIANT="${PHP_SRC_BUILD_VARIANT:-bench}"

configure_delegate_to_container "$(basename "$0")" "${arch}" ${ARGS[@]+"${ARGS[@]}"}

# Mirrors the ./configure step of the BENCHMARKING job in
# .github/workflows/test-suite.yml, minus --prefix and the ini scan dir: the
# build is run from its build directory, and bench.sh supplies the ini.
BENCH_CONFIGURE_ARGS=(
    --enable-option-checking=fatal
    --disable-debug
    --enable-werror
    --enable-mbstring
    --enable-sockets
    --with-gmp
    --with-mysqli=mysqlnd
    --with-openssl
    --with-pdo-sqlite
)

# --with-valgrind tells the Zend allocator and the JIT about valgrind, so
# callgrind attributes JIT code and memcheck understands the heap. Only the
# 64-bit images install valgrind.
if [[ -f /usr/include/valgrind/valgrind.h ]]; then
    BENCH_CONFIGURE_ARGS+=(--with-valgrind)
else
    warn "valgrind is not installed in this image; configuring without --with-valgrind."
fi

configure_run "${arch}" "${BENCH_CONFIGURE_ARGS[@]}" ${ARGS[@]+"${ARGS[@]}"}
