#!/bin/bash

set -euo pipefail

BUILDER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_PROJECT_DIR=$(cd "$BUILDER_DIR/.." && pwd)

IMAGE=${RK_BUILDER_IMAGE:-rk-builder:debian11-arm64}
PROJECT_DIR=${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}
BUILD_TYPE=Release
IMAGE_MODE=auto
CMAKE_ARGS=()

usage()
{
    cat <<'EOF'
Usage: ./rk-builder/build.sh [OPTIONS] [-- CMAKE_ARGS...]

Options:
  -d, --debug          Debug build (default: Release)
  --release            Release build
  --rebuild-image      Always build the local image first
  --pull-image         Pull RK_BUILDER_IMAGE instead of building it
  -h, --help           Show this help

Environment:
  PROJECT_DIR          CMake source tree (default: parent of rk-builder)
  RK_BUILDER_IMAGE     Image name (default: rk-builder:debian11-arm64)
  JOBS                 Parallel build jobs
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--debug)
            BUILD_TYPE=Debug
            shift
            ;;
        --release)
            BUILD_TYPE=Release
            shift
            ;;
        --rebuild-image)
            IMAGE_MODE=build
            shift
            ;;
        --pull-image)
            IMAGE_MODE=pull
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            CMAKE_ARGS+=("$@")
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$IMAGE_MODE" in
    build)
        docker build --tag "$IMAGE" "$BUILDER_DIR"
        ;;
    pull)
        docker pull "$IMAGE"
        ;;
    auto)
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            docker build --tag "$IMAGE" "$BUILDER_DIR"
        fi
        ;;
esac

mkdir -p "$BUILDER_DIR/build" "$BUILDER_DIR/.ccache"

RUN_ARGS=(
    --rm
    --user "$(id -u):$(id -g)"
    --mount "type=bind,source=$PROJECT_DIR,target=/workspace/project"
    --mount "type=bind,source=$BUILDER_DIR/build,target=/workspace/build"
    --mount "type=bind,source=$BUILDER_DIR/.ccache,target=/workspace/ccache"
    --env HOME=/tmp
    --env "BUILD_TYPE=$BUILD_TYPE"
)

if [[ -n ${JOBS:-} ]]; then
    RUN_ARGS+=(--env "JOBS=$JOBS")
fi

docker run "${RUN_ARGS[@]}" "$IMAGE" "${CMAKE_ARGS[@]}"
