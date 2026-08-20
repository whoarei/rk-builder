#!/bin/bash

set -euo pipefail

PROJECT_DIR=$PWD
IMAGE=${RK_BUILDER_IMAGE:-ghcr.io/whoarei/rk-builder:latest}
BUILD_TYPE=Release
CMAKE_ARGS=()
PROJECT_DIR_SET=false
SCRIPT_MODE=false

usage()
{
    cat <<'EOF'
Usage: rk-builder.sh [OPTIONS] [PROJECT_DIR] [-- CMAKE_ARGS...]

Arguments:
  PROJECT_DIR          CMake project directory (default: current directory)

Options:
  -d, --debug          Build in Debug mode (default: Release)
  --release            Build in Release mode
  --script             Skip the interactive confirmation
  -h, --help           Show this help

Environment:
  RK_BUILDER_IMAGE     Builder image (default: ghcr.io/whoarei/rk-builder:latest)
  JOBS                 Parallel build jobs (default: container CPU count)

Build artifacts are written to PROJECT_DIR/build/<release|debug>/.
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
        --script)
            SCRIPT_MODE=true
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
            if [[ $PROJECT_DIR_SET == true ]]; then
                echo "Only one PROJECT_DIR argument is supported" >&2
                usage >&2
                exit 2
            fi
            PROJECT_DIR=$(cd "$1" && pwd)
            PROJECT_DIR_SET=true
            shift
            ;;
    esac
done

command -v docker >/dev/null 2>&1 || {
    echo "docker is required" >&2
    exit 1
}

PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
if [[ ! -f $PROJECT_DIR/CMakeLists.txt ]]; then
    echo "CMakeLists.txt not found in $PROJECT_DIR" >&2
    exit 1
fi

BUILD_DIR=$PROJECT_DIR/build/${BUILD_TYPE,,}
CCACHE_DIR=$PROJECT_DIR/.ccache
mkdir -p "$BUILD_DIR" "$CCACHE_DIR"

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Using local image $IMAGE"
else
    echo "Pulling $IMAGE"
    docker pull "$IMAGE"
fi

IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || echo "unknown")
IMAGE_CREATED=$(docker image inspect --format '{{.Created}}' "$IMAGE" 2>/dev/null || echo "unknown")
IMAGE_DIGEST=$(docker image inspect --format '{{join .RepoDigests ", "}}' "$IMAGE" 2>/dev/null || true)
[[ -n $IMAGE_DIGEST ]] || IMAGE_DIGEST="(none, image not pushed or pulled by digest)"

cat <<EOF
=== Build environment ===
  Image          : $IMAGE
  Image ID       : $IMAGE_ID
  Image digest   : $IMAGE_DIGEST
  Image created  : $IMAGE_CREATED
  Project dir    : $PROJECT_DIR
  Build dir      : $BUILD_DIR
  Build type     : $BUILD_TYPE
  Jobs           : ${JOBS:-<auto>}
  CMake args     : ${CMAKE_ARGS[*]:-<none>}
===========================
EOF

if [[ $SCRIPT_MODE == false && -t 0 ]]; then
    read -r -p "Proceed with the build? [Y/n] " answer
    case "$answer" in
        N|n)
            echo "Build cancelled."
            exit 0
            ;;
    esac
fi

echo "Building $PROJECT_DIR ($BUILD_TYPE)"
RUN_ARGS=(
    --rm
    --user "$(id -u):$(id -g)"
    --mount "type=bind,source=$PROJECT_DIR,target=/workspace/project"
    --mount "type=bind,source=$BUILD_DIR,target=/workspace/build/${BUILD_TYPE,,}"
    --mount "type=bind,source=$CCACHE_DIR,target=/workspace/ccache"
    --env HOME=/tmp
    --env "BUILD_TYPE=$BUILD_TYPE"
)

if [[ -n ${JOBS:-} ]]; then
    RUN_ARGS+=(--env "JOBS=$JOBS")
fi

docker run "${RUN_ARGS[@]}" "$IMAGE" "${CMAKE_ARGS[@]}"
