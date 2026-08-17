#!/bin/bash

set -euo pipefail

SOURCE_DIR=${SOURCE_DIR:-/workspace/project}
BUILD_TYPE=${BUILD_TYPE:-Release}
BUILD_DIR=${BUILD_DIR:-/workspace/build/${BUILD_TYPE,,}}
JOBS=${JOBS:-$(nproc)}

case "$BUILD_TYPE" in
    Debug|Release|RelWithDebInfo|MinSizeRel)
        ;;
    *)
        echo "Unsupported BUILD_TYPE: $BUILD_TYPE" >&2
        exit 2
        ;;
esac

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_TOOLCHAIN_FILE=/opt/rk-builder/aarch64-linux-gnu.cmake \
    "$@"

cmake --build "$BUILD_DIR" --parallel "$JOBS"
