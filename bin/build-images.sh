#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: build-images.sh [-h|--help]

Rebuild the four php-src development images (arm64, amd64, arm32, i386) from
Dockerfiles in the workspace root. Takes no other arguments; bin/setup.sh runs
this as its last step unless given --no-build.
EOF
}

case "${1:-}" in
    "") ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        warn "Unexpected argument: $1"
        usage >&2
        exit 1
        ;;
esac

BUILDER=php-src-builder

build_image() {
    local arch="$1"
    local dockerfile="$2"
    local platform tag

    platform="$(arch_platform "${arch}")"
    tag="$(arch_image "${arch}")"

    echo "Building ${tag} (${platform})..."
    run_docker buildx build --builder "${BUILDER}" \
        --platform "${platform}" --load \
        -t "${tag}" -f "${WORKSPACE_ROOT}/${dockerfile}" "${WORKSPACE_ROOT}"
}

ensure_docker_ready

# Cross-platform builds need buildx. Docker Engine ships it as a plugin, but
# some distro packages leave it out.
run_docker buildx version >/dev/null 2>&1 || die \
    "docker buildx is not available." \
    "Install it (on Debian/Ubuntu: the docker-buildx-plugin package)."

# Named builder, selected per build with --builder rather than `buildx use`, so
# this never changes which builder the rest of your docker usage defaults to.
run_docker buildx inspect "${BUILDER}" >/dev/null 2>&1 \
    || run_docker buildx create --name "${BUILDER}" >/dev/null

build_image arm64 Dockerfile
build_image amd64 Dockerfile
build_image arm32 Dockerfile
build_image i386 Dockerfile.i386

echo "All images built."
