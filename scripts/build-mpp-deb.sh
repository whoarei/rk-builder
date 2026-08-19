#!/bin/bash

set -euo pipefail

# 交叉编译 Rockchip MPP 并打包 ARM64 deb。
#
# 两种用法:
#   1. 默认: 克隆源码后用交叉工具链编译,再打 deb
#      (在 Dockerfile 的 mpp-deb 阶段使用)
#   2. BUILD_INPUT=<install-tree> 跳过编译,直接打包已有的安装产物
#      (本地已有编译结果时复用)

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

MPP_VERSION=${MPP_VERSION:-1.1.0}
MPP_PC_VERSION=${MPP_PC_VERSION:-1.3.10}
MPP_COMMIT=${MPP_COMMIT:-c08762ebfadeb4e986d2fed993bc7a54862d3ebe}
MPP_REPOSITORY=${MPP_REPOSITORY:-https://github.com/rockchip-linux/mpp.git}
BUILD_INPUT=${BUILD_INPUT:-}

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/mpp"}
SOURCE_DIR="$WORK_DIR/mpp"
PACKAGE_ROOT="$WORK_DIR/package"

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
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TEST=OFF
    cmake --build "$WORK_DIR/build" --parallel
    DESTDIR="$INSTALL_DIR" cmake --install "$WORK_DIR/build"
fi

# 把安装树拷进包目录,并补上 MPP 上游不生成的 pkg-config 文件
mkdir -p \
    "$PACKAGE_ROOT/usr" \
    "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/pkgconfig" \
    "$PACKAGE_ROOT/usr/share/doc/rockchip-mpp-dev"

cp -a "$INSTALL_DIR/usr/." "$PACKAGE_ROOT/usr/"

# MPP 头文件装在 include/rockchip/ 下,pkg-config 的 Cflags 需带上该子目录,
# 下游 #include <rk_mpi.h> 才能直接命中。
includedir=include
[[ -d $PACKAGE_ROOT/usr/include/rockchip ]] && includedir=include/rockchip

sed -e "s/@PC_VERSION@/$MPP_PC_VERSION/g" \
    -e "s|@INCLUDEDIR@|$includedir|g" \
    "$PACKAGING_DIR/rockchip_mpp.pc.in" \
    > "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/pkgconfig/rockchip_mpp.pc"

# 校验关键产物存在
if [[ ! -e $PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/librockchip_mpp.so ]]; then
    echo "missing librockchip_mpp.so in package" >&2
    exit 1
fi

install -m 0644 "$SOURCE_DIR/LICENSES" "$PACKAGE_ROOT/usr/share/doc/rockchip-mpp-dev/copyright" 2>/dev/null \
    || install -m 0644 "$SOURCE_DIR/LICENSE" "$PACKAGE_ROOT/usr/share/doc/rockchip-mpp-dev/copyright" 2>/dev/null \
    || true

deb_render_control "$PACKAGING_DIR/control.in" "$PACKAGE_ROOT" "$MPP_VERSION"
deb_finish_package "$PACKAGE_ROOT" "$OUT_DIR" rockchip-mpp-dev "$MPP_VERSION"
