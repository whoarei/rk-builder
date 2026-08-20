#!/bin/bash

set -euo pipefail

# 打包 librga ARM64 deb:运行包 librga + 开发包 librga-dev。
# librga 只发布官方预编译 .so 和头文件,没有库源码,
# 所以脚本直接把 airockchip/librga 仓库里的产物拷进包目录,
# 不做任何编译。
#
# 安装前缀为 /usr/local/ans(高于 /usr 的搜索优先级),
# 运行包装到目标设备后动态链接器优先命中本包。

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

LIBRGA_VERSION=${LIBRGA_VERSION:-1.10.6}
LIBRGA_COMMIT=${LIBRGA_COMMIT:-2b32edcb97b601b25683e2941d888c8515da6d55}
LIBRGA_REPOSITORY=${LIBRGA_REPOSITORY:-https://github.com/airockchip/librga.git}
PREFIX=/usr/local/ans

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/librga"}
SOURCE_DIR="$WORK_DIR/librga"
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"

deb_fetch_source "$LIBRGA_REPOSITORY" "$LIBRGA_COMMIT" "$SOURCE_DIR"

# ----------------------------------------------------------------------
# 运行包 librga:共享库实体。上游 ELF 的 SONAME 就是 librga.so，
# 不能人为改成版本化文件，否则运行时 NEEDED=librga.so 无法解析。
# ----------------------------------------------------------------------
mkdir -p \
    "$RUNTIME_ROOT$PREFIX/lib" \
    "$RUNTIME_ROOT/usr/share/doc/librga"

install -m 0644 \
    "$SOURCE_DIR/libs/Linux/gcc-aarch64/librga.so" \
    "$RUNTIME_ROOT$PREFIX/lib/librga.so"
install -m 0644 "$SOURCE_DIR/COPYING" "$RUNTIME_ROOT/usr/share/doc/librga/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$LIBRGA_VERSION" \
    PACKAGE=librga \
    SECTION=libs \
    DEPENDS="libc6 (>= 2.17), libstdc++6" \
    DESCRIPTION="Rockchip RGA userspace library (runtime)"
deb_add_runtime_paths "$RUNTIME_ROOT" librga
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" librga "$LIBRGA_VERSION"

# ----------------------------------------------------------------------
# 开发包 librga-dev:头文件 + pkg-config。
# 链接器需要的 librga.so 由运行包提供(上游 SONAME 也是该名称)。
# ----------------------------------------------------------------------
mkdir -p \
    "$DEV_ROOT$PREFIX/include/rga" \
    "$DEV_ROOT$PREFIX/lib/pkgconfig" \
    "$DEV_ROOT/usr/share/doc/librga-dev"

cp -a "$SOURCE_DIR/include/." "$DEV_ROOT$PREFIX/include/rga/"
install -m 0644 "$SOURCE_DIR/COPYING" "$DEV_ROOT/usr/share/doc/librga-dev/copyright"

sed "s/@VERSION@/$LIBRGA_VERSION/g" \
    "$PACKAGING_DIR/librga.pc.in" \
    > "$DEV_ROOT$PREFIX/lib/pkgconfig/librga.pc"

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$LIBRGA_VERSION" \
    PACKAGE=librga-dev \
    SECTION=libdevel \
    DEPENDS="librga (= $LIBRGA_VERSION), libc6 (>= 2.17), libstdc++6" \
    DESCRIPTION="Rockchip RGA userspace library (development files)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" librga-dev "$LIBRGA_VERSION"
