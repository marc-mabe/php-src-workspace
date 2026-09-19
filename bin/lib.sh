#!/usr/bin/env bash
# Shared helpers for the workspace scripts. Source this, don't execute it.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib.sh"
#
# Everything that knows about an architecture lives in the arch_* section, so a
# new target is added in one place rather than in every script's case statement.

[[ -n "${PHP_SRC_LIB_SOURCED:-}" ]] && return 0
PHP_SRC_LIB_SOURCED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Root of this workspace: the directory holding the Dockerfiles, bin/ and the
# php-src submodule.
WORKSPACE_ROOT="$(cd "${LIB_DIR}/.." && pwd)"

# The php-src checkout on the host. Inside a container it is always /php-src.
REPO_ROOT="${WORKSPACE_ROOT}/php-src"

LIMA_INSTANCE="${LIMA_INSTANCE:-php-src-docker}"

# How we reach the docker daemon.
#
#   native - the host runs Linux, so it has its own kernel and docker; no VM.
#   lima   - macOS (or anything else): engine and containers live in a Lima VM
#            and we drive them with limactl, so the host needs no docker CLI.
#
# PHP_SRC_BACKEND overrides, e.g. to use a Lima VM on a Linux host anyway.
if [[ -z "${PHP_SRC_BACKEND:-}" ]]; then
    case "$(uname -s)" in
        Linux) BACKEND=native ;;
        *) BACKEND=lima ;;
    esac
else
    BACKEND="${PHP_SRC_BACKEND}"
fi

# Where the checkout and this workspace are mounted inside the containers.
CONTAINER_REPO=/php-src
CONTAINER_WORKSPACE=/workspace

# ---------------------------------------------------------------- diagnostics

die() {
    printf '%s\n' "$@" >&2
    exit 1
}

warn() {
    printf '%s\n' "$@" >&2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$2"
}

# --------------------------------------------------------------- architecture

# Every accepted spelling, and the canonical name it maps to.
arch_canonical() {
    case "${1:-}" in
        arm64|aarch64) printf 'arm64\n' ;;
        amd64|x86_64) printf 'amd64\n' ;;
        i386|i686|x86) printf 'i386\n' ;;
        arm32|armv7|armv7l|armhf|arm) printf 'arm32\n' ;;
        *) return 1 ;;
    esac
}

arch_is_valid() {
    arch_canonical "${1:-}" >/dev/null 2>&1
}

# Docker --platform for an arch. i386 is the odd one out: Ubuntu publishes no
# 32-bit x86 image, so it is the amd64 image built with multilib. arm32 has a
# real armhf image, so it gets its own platform.
arch_platform() {
    case "$(arch_canonical "$1")" in
        arm64) printf 'linux/arm64\n' ;;
        arm32) printf 'linux/arm/v7\n' ;;
        *) printf 'linux/amd64\n' ;;
    esac
}

arch_image() {
    printf 'php-src-dev:%s\n' "$(arch_canonical "$1")"
}

arch_is_32bit() {
    case "$(arch_canonical "$1")" in
        i386|arm32) return 0 ;;
        *) return 1 ;;
    esac
}

# 32-bit x86 specifically. Several things are about multilib and the x87 FPU
# rather than about word size, so they must not catch arm32.
arch_is_i386() {
    [[ "$(arch_canonical "$1")" == i386 ]]
}

# Rosetta translates x86_64 and not 32-bit x86, so the -m32 binaries the i386
# image produces cannot run under it. Only amd64 is a candidate, and only under
# Lima's vz backend -- on a native Linux host there is no Rosetta to probe.
arch_may_use_rosetta() {
    [[ "${BACKEND}" == lima ]] || return 1
    [[ "$(arch_canonical "$1")" == amd64 ]]
}

# On i386 the x87 FPU is the platform default and computes at 80-bit extended
# precision. Set PHP_SRC_FPMATH=sse to force SSE (64-bit double) math instead.
arch_fpmath_flag() {
    printf '%s\n' "${PHP_SRC_FPMATH:+ -mfpmath=${PHP_SRC_FPMATH}}"
}

# The compiler environment an arch needs, as NAME=VALUE lines. Single source of
# truth: bin/shell.sh passes these to docker -e, and configure_run exports them
# when it runs outside that container.
arch_build_env() {
    local arch fpmath
    arch="$(arch_canonical "$1")"
    fpmath="$(arch_fpmath_flag)"

    # Only i386 needs this: it is a multilib build inside the amd64 image. The
    # armhf image is native, so its default toolchain is already correct.
    [[ "${arch}" == i386 ]] || return 0

    cat <<EOF
PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig
CFLAGS=-m32 -msse2${fpmath}
CXXFLAGS=-m32 -msse2${fpmath}
LDFLAGS=-L/usr/lib/i386-linux-gnu
EOF
}

# Extra ./configure arguments an arch needs. Only the i386 multilib build has
# to be told what it is building for; in the native armhf image config.guess
# already reports armv7l.
arch_configure_args() {
    if arch_is_i386 "$1" && [[ "$(uname -m)" != i?86 ]]; then
        printf '%s\n' --build=i686-pc-linux-gnu
    fi
}

# Logical CPUs on the host. The Lima VM is sized from this so container builds
# get the whole machine; lima's own default caps it at 4.
host_cpus() {
    if [[ -n "${PHP_SRC_VM_CPUS:-}" ]]; then
        printf '%s\n' "${PHP_SRC_VM_CPUS}"
        return 0
    fi

    local n
    case "$(uname -s)" in
        Darwin) n="$(sysctl -n hw.ncpu 2>/dev/null)" ;;
        *) n="$(nproc 2>/dev/null)" ;;
    esac

    [[ "${n}" =~ ^[1-9][0-9]*$ ]] || n=4
    printf '%s\n' "${n}"
}

# The architecture of the machine running this script.
arch_host() {
    arch_canonical "$(uname -m)"
}

# --------------------------------------------------------------- command line

# Parse a script's arguments into the architecture it should use and the
# arguments to pass on:
#
#   parse_args "$@"
#   ... use "${ARCH}" and "${ARGS[@]}"
#
# `--` separates the helper's own arguments from the pass-through ones, and is
# the unambiguous form:
#
#   make.sh arm64 -- test     arch arm64, make gets `test`
#   make.sh -- test           host arch,  make gets `test`
#   shell.sh amd64 -- --help  runs `--help` in the container, not ours
#
# Before the separator only an architecture is accepted, so a misspelling is an
# error rather than a silently wrong target. Without a separator the first
# argument is still taken as the architecture when it is one, which keeps
# `shell.sh amd64 make -j4` working; anything else starts the pass-through
# arguments and the host architecture is used.
#
# Sets variables rather than printing, deliberately: called as $(parse_args)
# the exits below would only leave the command substitution's subshell.
parse_args() {
    local head=() sep=0

    ARGS=()

    # Our own --help, before the separator can hide it.
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
    esac

    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -- ]]; then
            sep=1
            shift
            ARGS=("$@")
            break
        fi
        head+=("$1")
        shift
    done

    if [[ "${sep}" -eq 0 ]]; then
        # No separator: a leading architecture is optional, the rest passes on.
        if [[ ${#head[@]} -gt 0 ]] && arch_is_valid "${head[0]}"; then
            ARGS=("${head[@]:1}")
            head=("${head[0]}")
        else
            ARGS=(${head[@]+"${head[@]}"})
            head=()
        fi
    fi

    if [[ ${#head[@]} -gt 1 ]]; then
        warn "Expected at most one architecture before --, got: ${head[*]}"
        usage >&2
        exit 1
    fi

    if [[ ${#head[@]} -eq 1 ]]; then
        if ! arch_is_valid "${head[0]}"; then
            warn "Unsupported architecture: ${head[0]}" \
                 "Expected arm64, amd64, arm32 or i386."
            usage >&2
            exit 1
        fi
        ARCH="${head[0]}"
        return 0
    fi

    ARCH="$(arch_host)" || die \
        "Cannot map the host architecture '$(uname -m)' to a container." \
        "Pass one explicitly: arm64, amd64, arm32 or i386."
    warn "Using host architecture ${ARCH} (no architecture given)."
}

# ------------------------------------------------------------------ container

in_linux_container() {
    [[ "$(uname -s)" == Linux ]] && [[ -n "${PHP_SRC_DOCKER:-}" || -f /.dockerenv ]]
}

# Run docker, wherever the daemon is.
#
# Under the lima backend this goes through `limactl shell`, so the host needs no
# docker CLI at all. limactl escapes argv properly, so arguments with spaces
# survive, and it forwards a tty when there is one.
run_docker() {
    case "${BACKEND}" in
        native) docker "$@" ;;
        *) limactl shell "${LIMA_INSTANCE}" -- docker "$@" ;;
    esac
}

exec_docker() {
    case "${BACKEND}" in
        native) exec docker "$@" ;;
        *) exec limactl shell "${LIMA_INSTANCE}" -- docker "$@" ;;
    esac
}

ensure_docker_ready() {
    if [[ "${BACKEND}" == native ]]; then
        require_cmd docker \
            "docker is not installed. See https://docs.docker.com/engine/install/"
        docker info >/dev/null 2>&1 || die \
            "Cannot reach the docker daemon." \
            "Is it running, and is your user in the 'docker' group?"
        return 0
    fi

    require_cmd limactl \
        "lima is not installed. Install from https://lima-vm.io/docs/installation/"

    local status
    status="$(limactl list "${LIMA_INSTANCE}" --format '{{.Status}}' 2>/dev/null || true)"

    case "${status}" in
        Running) return 0 ;;
        "") die "Lima instance '${LIMA_INSTANCE}' does not exist. Run ./bin/setup.sh first." ;;
        *) die "Lima instance '${LIMA_INSTANCE}' is ${status}. Run ./bin/setup.sh first." ;;
    esac
}

# ------------------------------------------------------------- the php-src tree

# Locate the php-src tree by walking up from the current directory.
php_src_root() {
    if [[ -n "${PHP_SRC_ROOT:-}" ]]; then
        printf '%s\n' "${PHP_SRC_ROOT}"
        return 0
    fi

    local dir="${PWD}"
    while [[ "${dir}" != / ]]; do
        if [[ -f "${dir}/buildconf" && -f "${dir}/Zend/Zend.m4" ]]; then
            printf '%s\n' "${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done

    return 1
}

# Out-of-tree build directory for an arch, below the given source root.
# php-src/build/ is upstream's build-system directory; it contains only files,
# so per-arch subdirectories sit alongside them without colliding.
php_build_dir() {
    local root="$1" arch="$2"
    printf '%s\n' "${PHP_SRC_BUILD_DIR:-${root}/build/$(arch_canonical "${arch}")}"
}

# --------------------------------------------------------------------- configure

# Re-exec inside the matching container when called from the host, so the same
# script works from either side.
configure_delegate_to_container() {
    local script_name="$1"
    local arch="$2"
    shift 2

    if ! in_linux_container; then
        exec "${LIB_DIR}/shell.sh" "${arch}" \
            "${CONTAINER_WORKSPACE}/bin/${script_name}" "${arch}" "$@"
    fi
}

configure_run() {
    local arch="$1"
    shift

    local src_root build_dir
    src_root="$(php_src_root)" || die \
        "Cannot find the php-src tree from ${PWD}." \
        "Run this from inside the checkout, or set PHP_SRC_ROOT."
    build_dir="$(php_build_dir "${src_root}" "${arch}")"

    cd "${src_root}"

    # An older in-tree configure leaves a Makefile in the source root that
    # shadows the out-of-tree ones: `shell.sh <arch> make` runs in /php-src and
    # would build with those flags instead. Catch it here rather than three
    # minutes into a build with the wrong -m32.
    if [[ -f Makefile ]]; then
        warn "Warning: ${src_root}/Makefile is left over from an in-tree build." \
             "         Remove it with 'make distclean' in ${src_root}," \
             "         or it will shadow the per-arch build directories."
    fi

    # Only present on branches that implement the int64 zend_long feature.
    local int64_args=()
    if grep -q ZEND_CHECK_INT64 Zend/Zend.m4; then
        int64_args=(--enable-zend-int64)
    fi
    set -- ${int64_args[@]+"${int64_args[@]}"} "$@"

    # bin/shell.sh already puts these in the container environment; this covers
    # running the script directly on a Linux host. Anything the caller set
    # deliberately wins.
    local line name
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        name="${line%%=*}"
        [[ -n "${!name:-}" ]] || export "${line?}"
    done < <(arch_build_env "${arch}")

    ./buildconf --force

    mkdir -p "${build_dir}"
    cd "${build_dir}"
    echo "Build directory: ${build_dir}"

    local arch_args=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && arch_args+=("${line}")
    done < <(arch_configure_args "${arch}")
    set -- ${arch_args[@]+"${arch_args[@]}"} "$@"

    echo "Exec ${src_root}/configure $*"
    exec "${src_root}/configure" "$@"
}
