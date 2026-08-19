#!/bin/bash

set -euo pipefail

BUILDER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

REMOTE_IMAGE=${RK_BUILDER_IMAGE:-ghcr.io/whoarei/rk-builder:latest}
LOCAL_IMAGE=rk-builder:debian11-arm64
PROJECT_DIR=$PWD
BUILD_TYPE=Release
IMAGE_MODE=auto
CMAKE_ARGS=()

usage()
{
    cat <<'EOF'
Usage: build.sh [OPTIONS] [PROJECT_DIR] [-- CMAKE_ARGS...]

Arguments:
  PROJECT_DIR          CMake source tree to build (default: current directory)

Options:
  -d, --debug          Debug build (default: Release)
  --release            Release build
  --rebuild-image      Build the local image and use it
  --pull-image         Pull RK_BUILDER_IMAGE and use it
  -h, --help           Show this help

Environment:
  RK_BUILDER_IMAGE     Remote image name (default: ghcr.io/whoarei/rk-builder:latest)
  JOBS                 Parallel build jobs

Build artifacts go to PROJECT_DIR/build/<release|debug>/.
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
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ $PROJECT_DIR != "$PWD" ]]; then
                echo "Only one PROJECT_DIR argument is supported" >&2
                usage >&2
                exit 2
            fi
            PROJECT_DIR=$(cd "$1" && pwd)
            shift
            ;;
    esac
done

build_local_image()
{
    docker build --tag "$LOCAL_IMAGE" "$BUILDER_DIR"
    IMAGE=$LOCAL_IMAGE
}

case "$IMAGE_MODE" in
    build)
        build_local_image
        ;;
    pull)
        docker pull "$REMOTE_IMAGE"
        IMAGE=$REMOTE_IMAGE
        ;;
    auto)
        if docker image inspect "$REMOTE_IMAGE" >/dev/null 2>&1; then
            IMAGE=$REMOTE_IMAGE
        elif docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
            IMAGE=$LOCAL_IMAGE
        else
            if docker pull "$REMOTE_IMAGE"; then
                IMAGE=$REMOTE_IMAGE
            else
                echo "Falling back to building the local image" >&2
                build_local_image
            fi
        fi
        ;;
esac

BUILD_TYPE_LOWER=${BUILD_TYPE,,}
mkdir -p "$PROJECT_DIR/build/$BUILD_TYPE_LOWER" "$PROJECT_DIR/.ccache"

RUN_ARGS=(
    --rm
    --user "$(id -u):$(id -g)"
    --mount "type=bind,source=$PROJECT_DIR,target=/workspace/project"
    --mount "type=bind,source=$PROJECT_DIR/build/$BUILD_TYPE_LOWER,target=/workspace/build/$BUILD_TYPE_LOWER"
    --mount "type=bind,source=$PROJECT_DIR/.ccache,target=/workspace/ccache"
    --env HOME=/tmp
    --env "BUILD_TYPE=$BUILD_TYPE"
)

if [[ -n ${JOBS:-} ]]; then
    RUN_ARGS+=(--env "JOBS=$JOBS")
fi

docker run "${RUN_ARGS[@]}" "$IMAGE" "${CMAKE_ARGS[@]}"
