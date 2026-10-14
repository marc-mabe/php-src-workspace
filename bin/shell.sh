#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: shell.sh [arm64|amd64|arm32|i386] [command...]

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

# How x86_64 code in the container is translated, fastest first:
#
#   cached - Rosetta with its ahead-of-time translation cache (the CDI device)
#   plain  - Rosetta alone, through the VM's binfmt handler
#   qemu   - QEMU, with the Rosetta binfmt handler switched off
#
# Rosetta does not always work. On macOS 27.0 (26A428) the cached mode aborts
# on signal return as soon as the guest does anything non-trivial, while plain
# Rosetta is fine:
#
#   assertion failed [sw_reserved_ptr->magic1 == kFpXstateMagic1]:
#   (ThreadContextSignals.cpp:411 rt_sigreturn)
#
# So probe each mode in turn and use the first that works. The verdict is
# cached per Lima instance and macOS build, so an OS update re-probes.
rosetta_probe_cmd='cd /tmp && echo "int main(){return 0;}" > p.c && gcc p.c -o p && ./p'

# Run the probe; with $3 = rosetta, also require that Rosetta ran it rather than
# QEMU, which would otherwise make a broken Rosetta look like a working one.
rosetta_probe_run() {
    local image="$1" device="$2" want="$3" cmd="${rosetta_probe_cmd}"
    [[ "${want}" == rosetta ]] && cmd+=' && grep -q /rosetta /proc/$$/maps'
    # shellcheck disable=SC2086 # ${device} is empty or a single word
    run_docker run --rm --platform linux/amd64 ${device} "${image}" \
        bash -lc "${cmd}" >/dev/null 2>&1
}

# Switch the VM's Rosetta binfmt handler on (1) or off (0). Rosetta is
# registered after QEMU, so while it is on it wins every x86_64 binary and
# leaving out the device does not get you QEMU. This is VM-wide: it changes the
# mode for any x86 container started afterwards, not just ours. Lima re-enables
# it on VM boot, which is why every run applies it rather than only the probe.
rosetta_binfmt() {
    limactl shell "${LIMA_INSTANCE}" -- sudo -n sh -c '
        f=/proc/sys/fs/binfmt_misc/rosetta
        [ -e "$f" ] || exit 0
        [ "$(head -n1 "$f")" = enabled ] && cur=1 || cur=0
        [ "$cur" = "$1" ] || echo "$1" > "$f"
    ' sh "$1" || warn "Could not switch the Rosetta binfmt handler in '${LIMA_INSTANCE}'."
}

rosetta_probe() {
    local image="$1" cache_dir cache_file key mode

    if ! run_docker image inspect "${image}" >/dev/null 2>&1; then
        # Nothing to probe with yet; assume Rosetta and let the build say
        # otherwise. Don't cache this.
        echo cached
        return 0
    fi

    key="${LIMA_INSTANCE}-$(sw_vers -buildVersion 2>/dev/null || uname -r)"
    cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/php-src-workspace"
    cache_file="${cache_dir}/rosetta-${key}"

    if [[ -f "${cache_file}" ]]; then
        mode="$(cat "${cache_file}")"
        case "${mode}" in
            cached|plain|qemu) echo "${mode}"; return 0 ;;
        esac
        # Anything else is from an older version of this script: re-probe.
    fi

    # A trivial command can succeed even when Rosetta is broken, so the probe
    # forks and compiles: that is what actually trips the rt_sigreturn abort.
    mkdir -p "${cache_dir}"
    rosetta_binfmt 1
    if rosetta_probe_run "${image}" "${ROSETTA_DEVICE}" rosetta; then
        mode=cached
    elif rosetta_probe_run "${image}" "" rosetta; then
        mode=plain
        warn "Rosetta's translation cache is not working in '${LIMA_INSTANCE}';" \
             "using Rosetta without it."
    else
        mode=qemu
        rosetta_binfmt 0
        warn "Rosetta is not working in '${LIMA_INSTANCE}'; falling back to QEMU."
        rosetta_probe_run "${image}" "" any \
            || warn "The QEMU fallback failed the probe too; x86 containers may not work."
    fi

    echo "${mode}" > "${cache_file}"
    [[ "${mode}" == cached ]] \
        || warn "Re-probe by deleting ${cache_file}, or force with PHP_SRC_ROSETTA."
    echo "${mode}"
}

# PHP_SRC_ROSETTA picks the mode: cached (or 1), plain, qemu (or 0), or auto
# (default), which probes.
rosetta_mode() {
    case "${PHP_SRC_ROSETTA:-auto}" in
        cached|1) echo cached ;;
        plain) echo plain ;;
        qemu|0) echo qemu ;;
        auto) rosetta_probe "$1" ;;
        *) die "PHP_SRC_ROSETTA must be auto, cached, plain or qemu, not '${PHP_SRC_ROSETTA}'." ;;
    esac
}

# ccache sits in front of the compiler through /usr/lib/ccache, which holds
# gcc/cc/g++ shims, so configure and the Makefiles need no CC change and a
# build dir configured without it keeps working. The cache is a named volume
# in the VM: shared by every arch (compiler and flags are part of the key, so
# they never collide), on the VM's own disk rather than the slower host mount,
# and surviving the --rm containers. 2G holds about ten full builds of all four
# archs. PHP_SRC_CCACHE=0 bypasses it.
CCACHE_VOLUME=php-src-ccache

ENV_ARGS=(
    -e PHP_SRC_DOCKER=1
    -e PATH=/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    -e CCACHE_DIR=/ccache
    -e CCACHE_MAXSIZE=2G
    # Hash the compiler binary rather than its mtime, so an image rebuild that
    # leaves gcc unchanged does not throw the whole cache away.
    -e CCACHE_COMPILERCHECK=content
)
[[ "${PHP_SRC_CCACHE:-1}" == 0 ]] && ENV_ARGS+=(-e CCACHE_DISABLE=1)
while IFS= read -r line; do
    [[ -n "${line}" ]] && ENV_ARGS+=(-e "${line}")
done < <(arch_build_env "${ARCH}")

# Forward the knobs the in-container scripts read. Without this a host-side
# `PHP_SRC_BUILD_DIR=... ./bin/configure-minimal.sh arm64` is silently ignored,
# because configure_run evaluates it on the far side of docker run.
for var in PHP_SRC_BUILD_DIR PHP_SRC_BUILD_VARIANT PHP_SRC_FPMATH \
           PHP_SRC_BENCH_PERF_RUNS PHP_SRC_BENCH_PERF_EVENTS; do
    [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "${var}=${!var}")
done

EXTRA_ARGS=()
if arch_may_use_rosetta "${ARCH}"; then
    ROSETTA_MODE="$(rosetta_mode "${IMAGE}")"
    case "${ROSETTA_MODE}" in
        cached) rosetta_binfmt 1; EXTRA_ARGS=("${ROSETTA_DEVICE}") ;;
        plain) rosetta_binfmt 1 ;;
        qemu) rosetta_binfmt 0 ;;
    esac
fi

# --init puts docker's tini at PID 1 in front of the command. Without it the
# command itself is PID 1 (make, via `exec make`), which gets no default signal
# handling and reaps nothing it did not start. A make that hangs under qemu-user
# then outlives the terminal that started it, and --rm never fires because the
# container never exits.
RUN_ARGS=(
    --rm
    --init
    --platform "$(arch_platform "${ARCH}")"
    -v "${REPO_ROOT}:${CONTAINER_REPO}:rw"
    -v "${WORKSPACE_ROOT}:${CONTAINER_WORKSPACE}:rw"
    -v "${CCACHE_VOLUME}:/ccache:rw"
    -w "${CONTAINER_REPO}"
    "${ENV_ARGS[@]}"
)

if [[ ${#ARGS[@]} -eq 0 ]]; then
    RUN_ARGS+=(-it)
fi

# PHP_SRC_PROFILE=1 lets perf, valgrind and heaptrack work in the container.
# Opt-in, since it drops docker's seccomp profile.
if [[ "${PHP_SRC_PROFILE:-0}" == 1 ]]; then
    profile_warn_if_emulated "${ARCH}"
    profile_prepare_host
    while IFS= read -r line; do
        RUN_ARGS+=("${line}")
    done < <(profile_docker_args)
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
