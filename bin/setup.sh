#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: setup.sh [options]

Prepare the container environment and build the php-src development images.

On Linux the host's own docker is used and no VM is involved; setup registers
QEMU binfmt handlers for the foreign architectures. On macOS it starts (or
creates) a Lima VM sized to the host's CPUs and does the same inside it.

Options:
  --name NAME   Lima instance name (default: php-src-docker, macOS only)
  --no-build    Skip building the development images
  -h, --help    Show this help

Environment:
  LIMA_INSTANCE     Same as --name
  PHP_SRC_BACKEND   'native' or 'lima'; overrides the per-OS default
  PHP_SRC_VM_CPUS   CPUs for the Lima VM (default: all host CPUs)
EOF
}

NO_BUILD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            LIMA_INSTANCE="$2"
            shift 2
            ;;
        --no-build)
            NO_BUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

build_images() {
    if [[ "${NO_BUILD}" -eq 0 ]]; then
        echo "Building php-src development images..."
        "${SCRIPT_DIR}/build-images.sh"
    fi
}

if [[ "${BACKEND}" == native ]]; then
    ensure_docker_ready

    # Foreign architectures need binfmt handlers on the host. Only register the
    # ones this host cannot run natively; it is a system-wide change, undone
    # with `docker run --privileged --rm tonistiigi/binfmt --uninstall <list>`.
    FOREIGN=()
    [[ "$(arch_host)" == arm64 ]] || FOREIGN+=(arm64)
    [[ "$(arch_host)" == amd64 ]] || FOREIGN+=(amd64)

    if [[ ${#FOREIGN[@]} -gt 0 ]]; then
        echo "Registering QEMU binfmt handlers for: ${FOREIGN[*]}..."
        docker run --privileged --rm tonistiigi/binfmt \
            --install "$(IFS=,; echo "${FOREIGN[*]}")" || true
    fi

    build_images

    cat <<EOF

Container environment is ready (native docker, no VM).

  Host:      $(uname -s) $(arch_host), $(host_cpus) CPUs
  Emulated:  ${FOREIGN[*]:-none}

Configure and build PHP:
  ${SCRIPT_DIR}/configure-minimal.sh
  ${SCRIPT_DIR}/make.sh

EOF
    exit 0
fi

require_cmd limactl "lima is not installed. Install from https://lima-vm.io/docs/installation/"

CPUS="$(host_cpus)"

echo "Starting Lima instance '${LIMA_INSTANCE}' with ${CPUS} CPUs..."
if limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${LIMA_INSTANCE}"; then
    # The CPU count is fixed at boot, so changing it means a restart. Only pay
    # for that when it actually differs.
    CURRENT_CPUS="$(limactl list "${LIMA_INSTANCE}" --format '{{.CPUs}}' 2>/dev/null || true)"
    if [[ -n "${CURRENT_CPUS}" && "${CURRENT_CPUS}" != "${CPUS}" ]]; then
        echo "Resizing ${CURRENT_CPUS} -> ${CPUS} CPUs (restarting)..."
        limactl stop "${LIMA_INSTANCE}" || true
        limactl edit "${LIMA_INSTANCE}" --cpus "${CPUS}"
    fi
    limactl start "${LIMA_INSTANCE}" --mount-writable || true
else
    limactl start --name="${LIMA_INSTANCE}" --mount-writable \
        --cpus "${CPUS}" "${WORKSPACE_ROOT}/lima.yaml"
fi

echo "Re-registering QEMU binfmt handlers (needed after VM reboot)..."
limactl shell "${LIMA_INSTANCE}" -- docker run --privileged --rm tonistiigi/binfmt --install all || true

echo "Ensuring Docker CDI is enabled for Rosetta (amd64 on Apple Silicon)..."
limactl shell "${LIMA_INSTANCE}" -- bash -lc '
    mkdir -p ~/.config/docker
    cat > ~/.config/docker/daemon.json <<EOF
{
  "features": {
    "cdi": true,
    "containerd-snapshotter": false
  }
}
EOF
    systemctl --user restart docker.service
    sleep 2
'

build_images

cat <<EOF

Lima Docker environment is ready.

  Instance:  ${LIMA_INSTANCE}
  Repo:      ${REPO_ROOT}

Open a shell in a container:
  ${WORKSPACE_ROOT}/bin/shell.sh arm64
  ${WORKSPACE_ROOT}/bin/shell.sh amd64
  ${WORKSPACE_ROOT}/bin/shell.sh i386

Configure and build PHP:
  ${WORKSPACE_ROOT}/bin/configure-minimal.sh arm64
  ${WORKSPACE_ROOT}/bin/make.sh arm64

EOF
