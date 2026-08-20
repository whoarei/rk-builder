#!/bin/bash

set -euo pipefail

# 交叉编译 Rockchip MPP 并打包 ARM64 deb:
# 运行包 rockchip-mpp + 开发包 rockchip-mpp-dev。
#
# 两种用法:
#   1. 默认: 克隆源码后用交叉工具链编译,再打 deb
#      (在 Dockerfile 的 mpp-deb 阶段使用)
#   2. BUILD_INPUT=<install-tree> 跳过编译,直接打包已有的安装产物
#      (本地已有编译结果时复用)
#
# 安装前缀为 /usr/local/ans(高于 /usr 的搜索优先级)。

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

MPP_VERSION=${MPP_VERSION:-1.1.0}
MPP_PC_VERSION=${MPP_PC_VERSION:-1.3.10}
MPP_COMMIT=${MPP_COMMIT:-c08762ebfadeb4e986d2fed993bc7a54862d3ebe}
MPP_REPOSITORY=${MPP_REPOSITORY:-https://github.com/rockchip-linux/mpp.git}
BUILD_INPUT=${BUILD_INPUT:-}
PREFIX=/usr/local/ans

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/mpp"}
SOURCE_DIR="$WORK_DIR/mpp"
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"

deb_fetch_source "$MPP_REPOSITORY" "$MPP_COMMIT" "$SOURCE_DIR"

# 编译阶段(BUILD_INPUT 为空时执行)。
# MPP 只依赖 libc/libstdc++,不需要完整 sysroot。
if [[ -n $BUILD_INPUT ]]; then
    INSTALL_DIR=$BUILD_INPUT
else
    INSTALL_DIR="$WORK_DIR/install"
    cmake -S "$SOURCE_DIR" -B "$WORK_DIR/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TEST=OFF
    cmake --build "$WORK_DIR/build" --parallel
    DESTDIR="$INSTALL_DIR" cmake --install "$WORK_DIR/build"
fi

# 校验编译产物存在
if [[ ! -e $INSTALL_DIR$PREFIX/lib/librockchip_mpp.so ]]; then
    echo "missing librockchip_mpp.so in install tree" >&2
    exit 1
fi

# ----------------------------------------------------------------------
# 运行包 rockchip-mpp:共享库实体 + soname 链接(不带开发用 .so 链接)
# ----------------------------------------------------------------------
mkdir -p \
    "$RUNTIME_ROOT$PREFIX/lib" \
    "$RUNTIME_ROOT/usr/share/doc/rockchip-mpp"

cp -a "$INSTALL_DIR$PREFIX/lib/." "$RUNTIME_ROOT$PREFIX/lib/"
rm -rf "$RUNTIME_ROOT$PREFIX/lib/pkgconfig"
find "$RUNTIME_ROOT$PREFIX/lib" -maxdepth 1 -type f -name '*.a' -delete
find "$RUNTIME_ROOT$PREFIX/lib" -maxdepth 1 -type l -name 'lib*.so' -delete

install -m 0644 "$SOURCE_DIR/LICENSES" "$RUNTIME_ROOT/usr/share/doc/rockchip-mpp/copyright" 2>/dev/null \
    || install -m 0644 "$SOURCE_DIR/LICENSE" "$RUNTIME_ROOT/usr/share/doc/rockchip-mpp/copyright" 2>/dev/null \
    || true

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$MPP_VERSION" \
    PACKAGE=rockchip-mpp \
    SECTION=libs \
    DEPENDS="libc6 (>= 2.17), libstdc++6" \
    DESCRIPTION="Rockchip MPP hardware media codec library (runtime)"
deb_add_runtime_paths "$RUNTIME_ROOT" rockchip-mpp
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" rockchip-mpp "$MPP_VERSION"

# ----------------------------------------------------------------------
# 开发包 rockchip-mpp-dev:头文件 + 链接器 .so 链接 + pkg-config
# ----------------------------------------------------------------------
mkdir -p \
    "$DEV_ROOT$PREFIX/lib/pkgconfig" \
    "$DEV_ROOT/usr/share/doc/rockchip-mpp-dev"

cp -a "$INSTALL_DIR$PREFIX/include" "$DEV_ROOT$PREFIX/"
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 -type f -name '*.a' \
    -exec cp -a {} "$DEV_ROOT$PREFIX/lib/" \;
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 -type l -name 'lib*.so' \
    -exec cp -a {} "$DEV_ROOT$PREFIX/lib/" \;

# MPP 上游不生成 pkg-config 文件,这里补上。模板同时加入 include/ 和
# include/rockchip/,兼容 #include <rockchip/rk_mpi.h> 与 <rk_mpi.h>。
sed "s/@PC_VERSION@/$MPP_PC_VERSION/g" \
    "$PACKAGING_DIR/rockchip_mpp.pc.in" \
    > "$DEV_ROOT$PREFIX/lib/pkgconfig/rockchip_mpp.pc"

install -m 0644 "$SOURCE_DIR/LICENSES" "$DEV_ROOT/usr/share/doc/rockchip-mpp-dev/copyright" 2>/dev/null \
    || install -m 0644 "$SOURCE_DIR/LICENSE" "$DEV_ROOT/usr/share/doc/rockchip-mpp-dev/copyright" 2>/dev/null \
    || true

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$MPP_VERSION" \
    PACKAGE=rockchip-mpp-dev \
    SECTION=libdevel \
    DEPENDS="rockchip-mpp (= $MPP_VERSION), libc6 (>= 2.17), libstdc++6" \
    DESCRIPTION="Rockchip MPP hardware media codec library (development files)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" rockchip-mpp-dev "$MPP_VERSION"
