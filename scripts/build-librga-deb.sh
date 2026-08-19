#!/bin/bash

set -euo pipefail

# 打包 librga ARM64 deb。
# librga 只发布官方预编译 .so 和头文件,没有库源码,
# 所以脚本直接把 airockchip/librga 仓库里的产物拷进包目录,
# 不做任何编译。

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

LIBRGA_VERSION=${LIBRGA_VERSION:-1.10.6}
LIBRGA_COMMIT=${LIBRGA_COMMIT:-2b32edcb97b601b25683e2941d888c8515da6d55}
LIBRGA_REPOSITORY=${LIBRGA_REPOSITORY:-https://github.com/airockchip/librga.git}

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/librga"}
SOURCE_DIR="$WORK_DIR/librga"
PACKAGE_ROOT="$WORK_DIR/package"

deb_fetch_source "$LIBRGA_REPOSITORY" "$LIBRGA_COMMIT" "$SOURCE_DIR"

# 包目录布局:头文件 + 官方预编译共享库 + pkg-config
mkdir -p \
    "$PACKAGE_ROOT/usr/include/rga" \
    "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/pkgconfig" \
    "$PACKAGE_ROOT/usr/share/doc/librga-dev"

cp -a "$SOURCE_DIR/include/." "$PACKAGE_ROOT/usr/include/rga/"
install -m 0644 \
    "$SOURCE_DIR/libs/Linux/gcc-aarch64/librga.so" \
    "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/librga.so"
install -m 0644 "$SOURCE_DIR/COPYING" "$PACKAGE_ROOT/usr/share/doc/librga-dev/copyright"

sed "s/@VERSION@/$LIBRGA_VERSION/g" \
    "$PACKAGING_DIR/librga.pc.in" \
    > "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/pkgconfig/librga.pc"

deb_render_control "$PACKAGING_DIR/control.in" "$PACKAGE_ROOT" "$LIBRGA_VERSION"
deb_finish_package "$PACKAGE_ROOT" "$OUT_DIR" librga-dev "$LIBRGA_VERSION"
