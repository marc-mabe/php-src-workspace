#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: bench.sh [arm64|amd64|arm32|i386] [-- callgrind|memory|perf ...]

Benchmark the php-src checkout with the workloads of php-src's own BENCHMARKING
CI job -- Zend/bench.php, the Symfony Demo and WordPress, each with and without
the tracing JIT -- and store the results under bench-results/.

  callgrind  benchmark/benchmark.php: instructions per request, counted by
             valgrind's callgrind, plus the callgrind profiles. Deterministic
             and independent of the machine's speed, so comparable across
             hosts of one architecture. Slow: tens of minutes.
  memory     bin/bench-memory.php: peak RSS of the php-cgi process and the
             Zend allocator's peak per request. Fast.
  perf       bin/bench-perf.php: `perf stat` per request -- wall time,
             task-clock, cycles, instructions, branch and cache misses --
             averaged over PHP_SRC_BENCH_PERF_RUNS runs (default 5). Real
             time on the real CPU, so noisier than callgrind and only
             comparable on one machine. Fast.

callgrind and memory run by default. The release build lives in
php-src/build/<arch>-bench and is configured (bin/configure-bench.sh) and
brought up to date first.

Only an architecture the host runs natively gives meaningful numbers: arm64 on
Apple Silicon, amd64 on an x86-64 Linux host. Others are refused unless
PHP_SRC_BENCH_EMULATED=1.

Each run gets its own directory, bench-results/<time>-<host>-<arch>-<commit>/:
  callgrind.json   instructions per workload (benchmark.php's summary)
  callgrind/       callgrind.out.* profiles, for callgrind_annotate/KCachegrind
  memory.json      peak RSS and Zend peak per workload
  perf.json        perf stat events per workload
  meta.json        host, CPU, kernel, commit, compiler, valgrind and perf versions
  build.txt        php -v, php -m and the configure line
  *.log            full output

Examples:
  bench.sh
  bench.sh amd64
  bench.sh -- perf
  bench.sh -- memory
EOF
}

parse_args "$@"
arch="$(arch_canonical "${ARCH}")"

MODES=(${ARGS[@]+"${ARGS[@]}"})
[[ ${#MODES[@]} -gt 0 ]] || MODES=(callgrind memory)
for mode in "${MODES[@]}"; do
    case "${mode}" in
        callgrind|memory|perf) ;;
        *) die "Unknown benchmark '${mode}'. Expected callgrind, memory or perf." ;;
    esac
done

export PHP_SRC_BUILD_VARIANT="${PHP_SRC_BUILD_VARIANT:-bench}"

# ------------------------------------------------------------------- host side

if ! in_linux_container; then
    if [[ "${arch}" != "$(arch_host)" && "${PHP_SRC_BENCH_EMULATED:-0}" != 1 ]]; then
        die "${arch} is emulated on this $(arch_host) host, so its numbers would measure the emulator." \
            "Run it on a native ${arch} host, or force with PHP_SRC_BENCH_EMULATED=1."
    fi

    # The container's hostname is its id; name the results after this machine.
    # On macOS `hostname` follows the network (ip-192-168-...); LocalHostName
    # is the name the machine was given.
    bench_host="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname)"

    # Read the commit here rather than in the container. A submodule checkout
    # has a .git file pointing at ../.git/modules/php-src, outside the mount, so
    # git cannot follow it from /php-src.
    bench_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)" \
        || die "Cannot read the php-src commit from ${REPO_ROOT}."
    bench_branch="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"

    PHP_SRC_PROFILE=1 exec "${SCRIPT_DIR}/shell.sh" "${arch}" \
        "PHP_SRC_BENCH_HOST=$(printf '%q' "${bench_host}") PHP_SRC_BENCH_COMMIT=$(printf '%q' "${bench_commit}") PHP_SRC_BENCH_BRANCH=$(printf '%q' "${bench_branch}") PHP_SRC_BACKEND_NAME=${BACKEND} $(printf '%q ' "${CONTAINER_WORKSPACE}/bin/bench.sh" "${arch}" -- "${MODES[@]}")"
fi

# -------------------------------------------------------------- container side

build_dir="$(php_build_dir "${CONTAINER_REPO}" "${arch}")"
php="${build_dir}/sapi/cli/php"
php_cgi="${build_dir}/sapi/cgi/php-cgi"

# The host side passes the commit and branch in. Run directly in a container,
# git has to read them itself, which works for a plain clone but not for a
# submodule, whose git directory lies outside the mount.
#
# The checkout is bind-mounted and, under rootful docker, owned by someone else
# than the container's root; git refuses to read it without safe.directory.
git_src() {
    git -c safe.directory='*' -C "${CONTAINER_REPO}" "$@"
}

commit="${PHP_SRC_BENCH_COMMIT:-$(git_src rev-parse HEAD)}" \
    || die "Cannot read the php-src commit; run bench.sh from the host."
branch="${PHP_SRC_BENCH_BRANCH:-$(git_src rev-parse --abbrev-ref HEAD)}"
results_dir="${CONTAINER_WORKSPACE}/bench-results/$(date -u +%Y%m%d-%H%M%S)-${PHP_SRC_BENCH_HOST:-unknown}-${arch}-${commit:0:12}"
mkdir -p "${results_dir}"
echo "Results: ${results_dir#"${CONTAINER_WORKSPACE}/"}"

# Hand the results to whoever owns the workspace. Under rootful docker they are
# otherwise root's on the host; under rootless (Lima) this is a no-op.
trap 'chown -R "$(stat -c %u:%g "${CONTAINER_WORKSPACE}")" "${results_dir}" 2>/dev/null || true' EXIT

if [[ ! -f "${build_dir}/Makefile" ]]; then
    echo "Configuring ${build_dir}..."
    "${SCRIPT_DIR}/configure-bench.sh" "${arch}" > "${results_dir}/configure.log" 2>&1 \
        || die "configure failed; see ${results_dir}/configure.log"
fi

echo "Building ${build_dir}..."
make -C "${build_dir}" -j"$(nproc)" > "${results_dir}/make.log" 2>&1 \
    || die "make failed; see ${results_dir}/make.log"

if grep -q -- '--enable-debug' "${build_dir}/config.nice" 2>/dev/null; then
    die "${build_dir} is a debug build; benchmark a release build (bin/configure-bench.sh)."
fi

# The ini every php and php-cgi below picks up through PHPRC, also those that
# benchmark.php starts: proc_open passes the environment on. opcache is built
# in on current branches; older ones build it shared and need loading.
ini="${build_dir}/bench.ini"
{
    [[ -f "${build_dir}/modules/opcache.so" ]] && echo "zend_extension=${build_dir}/modules/opcache.so"
    echo "opcache.enable=1"
    echo "opcache.enable_cli=1"
    echo "mysqli.default_socket=/run/mysqld/mysqld.sock"
} > "${ini}"
export PHPRC="${ini}"

# The container runs as root, which wp-cli refuses unless told otherwise.
# benchmark.php does not pass --allow-root (CI is not root); the environment
# variable reaches wp-cli through proc_open all the same.
export WP_CLI_ALLOW_ROOT=1

# WordPress needs a database. Its wp-config.php connects to 127.0.0.1 over TCP,
# wp-cli and mysqli defaults may use the socket; the user exists for both. It lives in the container's own layer and goes
# away with it, so every run installs WordPress into an empty one, like CI.
echo "Starting MariaDB..."
service mariadb start > "${results_dir}/mariadb.log" 2>&1 \
    || die "MariaDB did not start; see ${results_dir}/mariadb.log"
mariadb -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS wordpress;
CREATE USER IF NOT EXISTS 'wordpress'@'localhost' IDENTIFIED BY 'wordpress';
CREATE USER IF NOT EXISTS 'wordpress'@'127.0.0.1' IDENTIFIED BY 'wordpress';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'localhost';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# Record what produced the numbers. lscpu shows the real CPU on a native host
# and whatever the hypervisor admits to inside the Lima VM.
"${php}" -v > "${results_dir}/build.txt"
{ echo; "${php}" -m; echo; cat "${build_dir}/config.nice"; } >> "${results_dir}/build.txt"
lscpu > "${results_dir}/lscpu.txt" 2>/dev/null || true

PHP_SRC_BENCH_COMMIT="${commit}" \
PHP_SRC_BENCH_BRANCH="${branch}" \
PHP_SRC_BENCH_ARCH="${arch}" \
"${php}" -r '
    $cpu = trim((string) shell_exec("lscpu | sed -n \"s/^Model name: *//p\" | head -n1"));
    echo json_encode([
        "host" => getenv("PHP_SRC_BENCH_HOST") ?: null,
        "backend" => getenv("PHP_SRC_BACKEND_NAME") ?: null,
        "arch" => getenv("PHP_SRC_BENCH_ARCH"),
        "cpu" => $cpu !== "" && $cpu !== "-" ? $cpu : null,
        "cpus" => (int) trim(shell_exec("nproc")),
        "kernel" => php_uname("r"),
        "commit" => getenv("PHP_SRC_BENCH_COMMIT"),
        "branch" => getenv("PHP_SRC_BENCH_BRANCH"),
        "php" => PHP_VERSION,
        "compiler" => trim(strtok(shell_exec("cc --version"), "\n")),
        "valgrind" => trim((string) shell_exec("valgrind --version 2>/dev/null")) ?: null,
        "perf" => trim((string) shell_exec("perf --version 2>/dev/null")) ?: null,
        "date" => gmdate("c"),
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
' > "${results_dir}/meta.json"

# ASLR moves buffers to different alignments from run to run, which changes
# which memcpy/SIMD paths are taken; CI switches it off machine-wide for that.
# setarch -R does it for this process tree only.
no_aslr=(setarch "$(uname -m)" -R)

for mode in "${MODES[@]}"; do
    case "${mode}" in
        callgrind)
            command -v valgrind >/dev/null || die "valgrind is not installed in this image."
            echo "Running callgrind benchmarks (benchmark/benchmark.php); this takes a while..."
            rm -rf "${CONTAINER_REPO}/benchmark/profiles"
            (cd "${CONTAINER_REPO}" && "${no_aslr[@]}" "${php}" benchmark/benchmark.php false "${php_cgi}") \
                > "${results_dir}/callgrind.log" 2>&1 \
                || die "benchmark.php failed; see ${results_dir}/callgrind.log"
            # Progress lines ("> cmd") and the summary share stdout; the summary
            # is the JSON object at the end.
            sed -n '/^{$/,$p' "${results_dir}/callgrind.log" > "${results_dir}/callgrind.json"
            mv "${CONTAINER_REPO}/benchmark/profiles" "${results_dir}/callgrind"
            cat "${results_dir}/callgrind.json"
            ;;
        memory)
            echo "Running memory benchmarks (bin/bench-memory.php)..."
            "${no_aslr[@]}" "${php}" "${SCRIPT_DIR}/bench-memory.php" "${php_cgi}" "${results_dir}/memory.json" \
                > "${results_dir}/memory.log" 2>&1 \
                || die "bench-memory.php failed; see ${results_dir}/memory.log"
            cat "${results_dir}/memory.json"
            ;;
        perf)
            command -v perf >/dev/null || die "perf is not installed in this image."
            echo "Running perf benchmarks (bin/bench-perf.php)..."
            "${no_aslr[@]}" "${php}" "${SCRIPT_DIR}/bench-perf.php" "${php_cgi}" "${results_dir}/perf.json" \
                > "${results_dir}/perf.log" 2>&1 \
                || die "bench-perf.php failed; see ${results_dir}/perf.log"
            cat "${results_dir}/perf.json"
            ;;
    esac
done

echo "Results: ${results_dir#"${CONTAINER_WORKSPACE}/"}"
