#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: shell.sh [arm64|amd64|i386] [command...]

Open an interactive shell (default) or run a command in the php-src container
for the given architecture. The architecture may be omitted, in which case the
host's is used.

Use -- to separate this script's arguments from the command, which is needed
when the command starts with something that looks like an option.

The working directory is /php-src, the source tree. Builds are out of tree in
/php-src/build/<arch>, so running make here needs a cd first -- or use make.sh,
which does that for you.

Quote anything the container should expand. Unquoted, your own shell expands it
first: 'make -j$(nproc)' counts the container's CPUs, make -j$(nproc) counts the
host's (and needs nproc on the host, which macOS does not have by default).

Examples:
  shell.sh
  shell.sh arm64
  shell.sh arm64 uname -m
  shell.sh amd64 -- gcc --version
  shell.sh amd64 'cd /php-src/build/amd64 && make -j"$(nproc)"'
  shell.sh i386 -- /workspace/bin/configure-minimal.sh i386

A single argument is run verbatim by the container shell; several arguments are
treated as a command and its arguments.
EOF
}

parse_args "$@"

IMAGE="$(arch_image "${ARCH}")"

# The Rosetta probe runs a container, so the VM has to be up.
ensure_docker_ready

ROSETTA_DEVICE="--device=lima-vm.io/rosetta=cached"

# Rosetta translates amd64 far faster than QEMU, so use it whenever it works.
# It does not always: on macOS 27.0 (26A428) it aborts on signal return as soon
# as the guest does anything non-trivial, 10/10 runs on a fresh VM:
#
#   assertion failed [sw_reserved_ptr->magic1 == kFpXstateMagic1]:
#   (ThreadContextSignals.cpp:411 rt_sigreturn)
#
# So probe it once and fall back to QEMU only when the probe fails. The result
# is cached per Lima instance and macOS build, so an OS update re-probes.
rosetta_probe() {
    local image="$1" cache_dir cache_file key

    if ! run_docker image inspect "${image}" >/dev/null 2>&1; then
        # Nothing to probe with yet; assume Rosetta and let the build say
        # otherwise. Don't cache this.
        return 0
    fi

    key="${LIMA_INSTANCE}-$(sw_vers -buildVersion 2>/dev/null || uname -r)"
    cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/php-src-workspace"
    cache_file="${cache_dir}/rosetta-${key}"

    if [[ -f "${cache_file}" ]]; then
        [[ "$(cat "${cache_file}")" == ok ]]
        return
    fi

    # A trivial command can succeed even when Rosetta is broken, so the probe
    # forks and compiles: that is what actually trips the rt_sigreturn abort.
    mkdir -p "${cache_dir}"
    if run_docker run --rm --platform linux/amd64 ${ROSETTA_DEVICE} "${image}" \
            bash -lc 'cd /tmp && echo "int main(){return 0;}" > p.c \
                      && gcc p.c -o p && ./p' >/dev/null 2>&1; then
        echo ok > "${cache_file}"
        return 0
    fi

    echo broken > "${cache_file}"
    warn "Rosetta is not working in '${LIMA_INSTANCE}'; falling back to QEMU." \
         "Re-probe by deleting ${cache_file}, or force with PHP_SRC_ROSETTA=1."
    return 1
}

# PHP_SRC_ROSETTA=1 forces it on, =0 forces QEMU, =auto (default) probes.
use_rosetta() {
    arch_may_use_rosetta "${ARCH}" || return 1
    case "${PHP_SRC_ROSETTA:-auto}" in
        1) return 0 ;;
        0) return 1 ;;
        *) rosetta_probe "$1" ;;
    esac
}

ENV_ARGS=(
    -e PHP_SRC_DOCKER=1
    -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
)
while IFS= read -r line; do
    [[ -n "${line}" ]] && ENV_ARGS+=(-e "${line}")
done < <(arch_build_env "${ARCH}")

# Forward the knobs the in-container scripts read. Without this a host-side
# `PHP_SRC_BUILD_DIR=... ./bin/configure-minimal.sh arm64` is silently ignored,
# because configure_run evaluates it on the far side of docker run.
for var in PHP_SRC_BUILD_DIR PHP_SRC_FPMATH; do
    [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "${var}=${!var}")
done

EXTRA_ARGS=()
if use_rosetta "${IMAGE}"; then
    EXTRA_ARGS=("${ROSETTA_DEVICE}")
fi

RUN_ARGS=(
    --rm
    --platform "$(arch_platform "${ARCH}")"
    -v "${REPO_ROOT}:${CONTAINER_REPO}:rw"
    -v "${WORKSPACE_ROOT}:${CONTAINER_WORKSPACE}:rw"
    -w "${CONTAINER_REPO}"
    "${ENV_ARGS[@]}"
)

if [[ ${#ARGS[@]} -eq 0 ]]; then
    RUN_ARGS+=(-it)
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    RUN_ARGS+=("${EXTRA_ARGS[@]}")
fi

if [[ ${#ARGS[@]} -eq 0 ]]; then
    exec_docker run "${RUN_ARGS[@]}" "${IMAGE}" bash
fi

# A single argument is passed to the container shell verbatim, so pipelines and
# `cd x && make` work:  shell.sh amd64 'cd /php-src/build/amd64 && make -j8'
# Multiple arguments are a command and its argv, quoted individually:
#                       shell.sh amd64 make -j8
#
# `bash -c --` rather than `bash -c`: without the terminator a command string
# starting with a dash is parsed as an option to bash itself, so `-- --version`
# would fail with "bash: --: invalid option" instead of running.
if [[ ${#ARGS[@]} -eq 1 ]]; then
    exec_docker run "${RUN_ARGS[@]}" "${IMAGE}" bash -c -- "${ARGS[0]}"
fi

exec_docker run "${RUN_ARGS[@]}" "${IMAGE}" bash -c -- "$(printf '%q ' "${ARGS[@]}")"
