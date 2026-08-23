#!/bin/bash

set -euo pipefail

# 封装 rknn_model_zoo 发布的 RKNPU2 AArch64 预编译 runtime：
# 运行包 rknn-runtime + 开发包 rknn-runtime-dev。
# 上游不发布 runtime 源码，因此这里只收集官方 librknnrt.so 与 API 头文件。

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

RKNN_RUNTIME_VERSION=${RKNN_RUNTIME_VERSION:-2.3.2}
RKNN_RUNTIME_COMMIT=${RKNN_RUNTIME_COMMIT:-bad6c7334531becaf90a561988519b7bec34d0ab}
RKNN_RUNTIME_REPOSITORY=${RKNN_RUNTIME_REPOSITORY:-https://github.com/airockchip/rknn_model_zoo.git}
PREFIX=/usr/local/ans

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/rknn-runtime"}
SOURCE_DIR="$WORK_DIR/rknn_model_zoo"
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"

# model zoo 很大，只拉取 RKNPU2 runtime 与根许可证。
deb_fetch_sparse_source \
    "$RKNN_RUNTIME_REPOSITORY" \
    "$RKNN_RUNTIME_COMMIT" \
    "$SOURCE_DIR" \
    /3rdparty/rknpu2/include/ \
    /3rdparty/rknpu2/Linux/aarch64/ \
    /LICENSE

RKNN_ROOT="$SOURCE_DIR/3rdparty/rknpu2"

# ----------------------------------------------------------------------
# 运行包 rknn-runtime：官方 AArch64 librknnrt.so。
# 上游 SONAME 本身就是未版本化的 librknnrt.so，不能另行拆出链接器符号链接。
# ----------------------------------------------------------------------
mkdir -p \
    "$RUNTIME_ROOT$PREFIX/lib" \
    "$RUNTIME_ROOT/usr/share/doc/rknn-runtime"

install -m 0644 \
    "$RKNN_ROOT/Linux/aarch64/librknnrt.so" \
    "$RUNTIME_ROOT$PREFIX/lib/librknnrt.so"
install -m 0644 "$SOURCE_DIR/LICENSE" \
    "$RUNTIME_ROOT/usr/share/doc/rknn-runtime/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$RKNN_RUNTIME_VERSION" \
    PACKAGE=rknn-runtime \
    SECTION=libs \
    DEPENDS="libc6 (>= 2.17), libgcc-s1, libstdc++6" \
    DESCRIPTION="Rockchip RKNN neural network runtime (RKNPU2)"
deb_add_runtime_paths "$RUNTIME_ROOT" rknn-runtime
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" rknn-runtime "$RKNN_RUNTIME_VERSION"

# ----------------------------------------------------------------------
# 开发包 rknn-runtime-dev：C API 头文件与 pkg-config 元数据。
# 链接所需的 librknnrt.so 由运行包提供。
# ----------------------------------------------------------------------
mkdir -p \
    "$DEV_ROOT$PREFIX/include" \
    "$DEV_ROOT$PREFIX/lib/pkgconfig" \
    "$DEV_ROOT/usr/share/doc/rknn-runtime-dev"

cp -a "$RKNN_ROOT/include/." "$DEV_ROOT$PREFIX/include/"
install -m 0644 "$SOURCE_DIR/LICENSE" \
    "$DEV_ROOT/usr/share/doc/rknn-runtime-dev/copyright"

sed "s/@VERSION@/$RKNN_RUNTIME_VERSION/g" \
    "$PACKAGING_DIR/rknnrt.pc.in" \
    > "$DEV_ROOT$PREFIX/lib/pkgconfig/rknnrt.pc"

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$RKNN_RUNTIME_VERSION" \
    PACKAGE=rknn-runtime-dev \
    SECTION=libdevel \
    DEPENDS="rknn-runtime (= $RKNN_RUNTIME_VERSION), libc6 (>= 2.17), libgcc-s1, libstdc++6" \
    DESCRIPTION="Rockchip RKNN neural network runtime development files (RKNPU2)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" rknn-runtime-dev "$RKNN_RUNTIME_VERSION"
