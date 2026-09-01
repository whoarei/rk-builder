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
# 运行包 librga:共享库实体 + 开发符号链接。
# 上游官方预编译 ELF 的 SONAME 是 librga.so(无版本号),而 Rockchip
# BSP 与设备端约定使用版本化 SONAME librga.so.2。打包时用 patchelf 把
# SONAME 改为 librga.so.2,并以 librga.so.2 为实体、librga.so 为开发
# 符号链接,与设备端标准布局一致:
#   librga.so.2  实体库,SONAME=librga.so.2(运行时 NEEDED=librga.so.2)
#   librga.so    -> librga.so.2(链接器 -lrga 使用)
# ----------------------------------------------------------------------
LIBRGA_SONAME=2

mkdir -p \
    "$RUNTIME_ROOT$PREFIX/lib" \
    "$RUNTIME_ROOT/usr/share/doc/librga"

install -m 0644 \
    "$SOURCE_DIR/libs/Linux/gcc-aarch64/librga.so" \
    "$RUNTIME_ROOT$PREFIX/lib/librga.so.$LIBRGA_SONAME"

# 把 SONAME 从上游的 librga.so 改为版本化的 librga.so.2。
patchelf --set-soname "librga.so.$LIBRGA_SONAME" \
    "$RUNTIME_ROOT$PREFIX/lib/librga.so.$LIBRGA_SONAME"

# 自检:修改后的实体库 SONAME 必须是 librga.so.2,防止 patchelf 静默失效。
if ! readelf -d "$RUNTIME_ROOT$PREFIX/lib/librga.so.$LIBRGA_SONAME" \
        | grep -q "SONAME.*\[librga\.so\.$LIBRGA_SONAME\]"; then
    echo "librga SONAME 修改失败,期望 librga.so.$LIBRGA_SONAME" >&2
    exit 1
fi

# 开发符号链接,链接器经 -lrga 找到它,产物 NEEDED 记录 SONAME(librga.so.2)。
ln -s "librga.so.$LIBRGA_SONAME" "$RUNTIME_ROOT$PREFIX/lib/librga.so"

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
# 链接器需要的 librga.so 符号链接由运行包提供(指向 librga.so.2)。
# pkg-config 的 Libs 仍为 -lrga,链接产物 NEEDED 记录 SONAME(librga.so.2)。
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
