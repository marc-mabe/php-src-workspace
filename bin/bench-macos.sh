#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: bench-macos.sh

Run bench.sh's perf benchmark natively on an Apple Silicon Mac, with the CPU's
own cycle and instruction counters -- which the Lima VM cannot see.

The same workloads as bench.sh (Zend/bench.php, the Symfony Demo and
WordPress, each with and without the tracing JIT) run in a release build
configured for macOS in php-src/build/macos-bench. bin/macos/pmcstat stands
in for perf stat: it reads the counters macOS keeps per process, no root
needed. Per request, averaged over PHP_SRC_BENCH_PERF_RUNS runs (default 5):

  duration_time   wall time (ns)
  task-clock      CPU time (msec)
  user-time       the part of it spent in PHP itself
  system-time     the part spent in the kernel on PHP's behalf
  cycles          CPU cycles, all cores
  instructions    instructions retired, all cores
  p-cycles        the part of those on performance cores
  p-instructions
  energy          the kernel's energy estimate (nJ)

cycles and instructions include the kernel's work for the process, which
varies between runs for the file-heavy workloads (Symfony, WordPress); see
system-time and the README before reading much into small changes.

The Symfony Demo and WordPress are cloned into php-src/build/macos-bench/repos
rather than shared with the containers' php-src/benchmark/repos: Symfony keeps
its cache inside the project, and a cache built on one side and cleared on the
other breaks. WordPress gets a throwaway MariaDB of its own (Homebrew's
mariadbd, on port 33306 with a temporary data directory); a MariaDB or MySQL
you run yourself is left alone.

Needs the Xcode command line tools and, from Homebrew: autoconf, bison, re2c,
pkg-config, openssl@3, gmp, sqlite, oniguruma, libiconv and mariadb.

Results go to bench-results/<time>-<host>-macos-arm64-<commit>/, next to those
of bench.sh: perf.json, meta.json, build.txt and the logs.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 1 ;;
esac

[[ "$(uname -s)" == Darwin ]] || die "bench-macos.sh runs on macOS; use bench.sh elsewhere."
[[ "$(uname -m)" == arm64 ]] || die "The per-process cycle and instruction counters need Apple Silicon."
require_cmd brew "Homebrew is needed for the build dependencies and MariaDB: https://brew.sh"

brew_prefix() {
    brew --prefix "$1" 2>/dev/null || die "Homebrew's $1 is not installed: brew install $1"
}

# Next to the containers' build/<arch> directories, as php_build_dir names them.
build_dir="${PHP_SRC_BUILD_DIR:-${REPO_ROOT}/build/macos-bench}"
php="${build_dir}/sapi/cli/php"
php_cgi="${build_dir}/sapi/cgi/php-cgi"
pmcstat="${build_dir}/pmcstat"

# Homebrew's bison and the keg-only libraries are not on the default paths.
bison_prefix="$(brew_prefix bison)"
export PATH="${bison_prefix}/bin:${PATH}"
PKG_CONFIG_PATH=""
for formula in openssl@3 sqlite oniguruma libxml2 zlib; do
    PKG_CONFIG_PATH+="${PKG_CONFIG_PATH:+:}$(brew_prefix "${formula}")/lib/pkgconfig"
done
export PKG_CONFIG_PATH

commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
branch="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
bench_host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
results_dir="${WORKSPACE_ROOT}/bench-results/$(date -u +%Y%m%d-%H%M%S)-${bench_host}-macos-arm64-${commit:0:12}"
mkdir -p "${results_dir}"
echo "Results: ${results_dir#"${WORKSPACE_ROOT}/"}"

# The release flags of bench.sh's configure-bench.sh, minus what has no
# meaning here: valgrind does not run on macOS, and -Werror would trip over
# clang warnings php-src's Linux CI never sees.
if [[ ! -f "${build_dir}/Makefile" ]]; then
    echo "Configuring ${build_dir}..."
    (
        cd "${REPO_ROOT}"
        ./buildconf --force
        mkdir -p "${build_dir}"
        cd "${build_dir}"
        "${REPO_ROOT}/configure" \
            --disable-debug \
            --enable-mbstring \
            --enable-sockets \
            --with-gmp="$(brew_prefix gmp)" \
            --with-mysqli=mysqlnd \
            --with-openssl \
            --with-pdo-sqlite \
            --with-iconv="$(brew_prefix libiconv)"
    ) > "${results_dir}/configure.log" 2>&1 \
        || die "configure failed; see ${results_dir}/configure.log"
fi

echo "Building ${build_dir}..."
make -C "${build_dir}" -j"$(sysctl -n hw.ncpu)" > "${results_dir}/make.log" 2>&1 \
    || die "make failed; see ${results_dir}/make.log"

if [[ ! -x "${pmcstat}" || "${SCRIPT_DIR}/macos/pmcstat.c" -nt "${pmcstat}" ]]; then
    cc -O2 -o "${pmcstat}" "${SCRIPT_DIR}/macos/pmcstat.c" \
        || die "Could not build ${pmcstat}."
fi

# As in bench.sh: opcache is built in on current branches; older ones build it
# shared and need loading.
ini="${build_dir}/bench.ini"
{
    [[ -f "${build_dir}/modules/opcache.so" ]] && echo "zend_extension=${build_dir}/modules/opcache.so"
    echo "opcache.enable=1"
    echo "opcache.enable_cli=1"
} > "${ini}"
export PHPRC="${ini}"

# A private MariaDB for WordPress, gone when this script exits. Grant tables
# are skipped, so wp-config.php's user needs no account; it only listens on
# loopback.
mariadb_prefix="$(brew_prefix mariadb)"
db_dir="$(mktemp -d "${TMPDIR:-/tmp}/php-src-bench-db.XXXXXX")"
db_pid=""
cleanup() {
    [[ -n "${db_pid}" ]] && kill "${db_pid}" 2>/dev/null && wait "${db_pid}" 2>/dev/null
    rm -rf "${db_dir}"
}
trap cleanup EXIT

echo "Starting MariaDB..."
"${mariadb_prefix}/bin/mariadb-install-db" --no-defaults --datadir="${db_dir}/data" \
    --auth-root-authentication-method=normal > "${results_dir}/mariadb.log" 2>&1 \
    || die "mariadb-install-db failed; see ${results_dir}/mariadb.log"
"${mariadb_prefix}/bin/mariadbd" --no-defaults --datadir="${db_dir}/data" \
    --socket="${db_dir}/mysqld.sock" --port=33306 --bind-address=127.0.0.1 \
    --skip-grant-tables >> "${results_dir}/mariadb.log" 2>&1 &
db_pid=$!
for _ in $(seq 100); do
    [[ -S "${db_dir}/mysqld.sock" ]] && break
    kill -0 "${db_pid}" 2>/dev/null || die "MariaDB did not start; see ${results_dir}/mariadb.log"
    sleep 0.1
done
"${mariadb_prefix}/bin/mariadb" --no-defaults --socket="${db_dir}/mysqld.sock" -uroot \
    -e 'CREATE DATABASE IF NOT EXISTS wordpress' \
    || die "Could not create the wordpress database; see ${results_dir}/mariadb.log"
export WORDPRESS_DB_HOST=127.0.0.1:33306

"${php}" -v > "${results_dir}/build.txt"
{ echo; "${php}" -m; echo; cat "${build_dir}/config.nice"; } >> "${results_dir}/build.txt"

PHP_SRC_BENCH_HOST="${bench_host}" \
PHP_SRC_BENCH_COMMIT="${commit}" \
PHP_SRC_BENCH_BRANCH="${branch}" \
"${php}" -r '
    echo json_encode([
        "host" => getenv("PHP_SRC_BENCH_HOST"),
        "backend" => "macos",
        "arch" => "arm64",
        "cpu" => trim(shell_exec("sysctl -n machdep.cpu.brand_string")),
        "cpus" => (int) trim(shell_exec("sysctl -n hw.ncpu")),
        "cpus_performance" => (int) trim(shell_exec("sysctl -n hw.perflevel0.logicalcpu")),
        "os" => "macOS " . trim(shell_exec("sw_vers -productVersion")),
        "kernel" => php_uname("r"),
        "commit" => getenv("PHP_SRC_BENCH_COMMIT"),
        "branch" => getenv("PHP_SRC_BENCH_BRANCH"),
        "php" => PHP_VERSION,
        "compiler" => trim(strtok(shell_exec("cc --version"), "\n")),
        "date" => gmdate("c"),
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
' > "${results_dir}/meta.json"

echo "Running perf benchmarks (bin/bench-perf.php with pmcstat)..."
PHP_SRC_BENCH_STAT="${pmcstat}" \
PHP_SRC_BENCH_DIR="${REPO_ROOT}/benchmark" \
PHP_SRC_BENCH_REPOS="${build_dir}/repos" \
"${php}" "${SCRIPT_DIR}/bench-perf.php" "${php_cgi}" "${results_dir}/perf.json" \
    > "${results_dir}/perf.log" 2>&1 \
    || die "bench-perf.php failed; see ${results_dir}/perf.log"
cat "${results_dir}/perf.json"

echo "Results: ${results_dir#"${WORKSPACE_ROOT}/"}"
