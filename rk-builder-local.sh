#!/bin/bash

set -euo pipefail

BUILDER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE=${RK_BUILDER_LOCAL_IMAGE:-rk-builder:debian11-arm64}

usage()
{
    cat <<'EOF'
Usage: rk-builder-local.sh [OPTIONS] [PROJECT_DIR] [-- CMAKE_ARGS...]

Build the rk-builder image from the Dockerfile in this repository, then build
the specified CMake project. Build options are the same as rk-builder.sh.

Environment:
  RK_BUILDER_LOCAL_IMAGE   Local image name (default: rk-builder:debian11-arm64)
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        --)
            break
            ;;
    esac
done

command -v docker >/dev/null 2>&1 || {
    echo "docker is required" >&2
    exit 1
}

echo "Building local image $IMAGE"
docker build --tag "$IMAGE" "$BUILDER_DIR"

RK_BUILDER_IMAGE=$IMAGE exec "$BUILDER_DIR/rk-builder.sh" "$@"
