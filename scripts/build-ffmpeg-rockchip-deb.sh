#!/bin/bash

set -euo pipefail

# 打包 ffmpeg-rockchip ARM64 deb。
#
# 编译在 Dockerfile 的 ffmpeg-deb 阶段完成(需要交叉编译环境和
# librga/mpp sysroot),本脚本只负责把 DESTDIR 安装好的产物封成 deb。
#
# 用法:
#   BUILD_INPUT=<install-tree>              必传,DESTDIR 安装树
#   FFMPEG_SRC_DIR=<源码目录>               可选,用于取 license 和
#                                            SOURCE_DATE_EPOCH,不传则跳过
#   ./build-ffmpeg-rockchip-deb.sh

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

FFMPEG_VERSION=${FFMPEG_VERSION:-6.1}
FFMPEG_COMMIT=${FFMPEG_COMMIT:-d547c18f18c744bc5e2180ce028fe1a6bd23ddad}
FFMPEG_REPOSITORY=${FFMPEG_REPOSITORY:-https://github.com/nyanmisaka/ffmpeg-rockchip.git}
BUILD_INPUT=${BUILD_INPUT:-}

if [[ -z $BUILD_INPUT ]]; then
    echo "BUILD_INPUT (ffmpeg DESTDIR install tree) is required" >&2
    exit 2
fi

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/ffmpeg-rockchip"}
PACKAGE_ROOT="$WORK_DIR/package"
INSTALL_DIR=$BUILD_INPUT

# 如果提供了源码目录,从中取 license 和 commit 时间戳;
# 否则用当前时间(不影响功能,只是 deb 内容时间戳不可复现)。
FFMPEG_SRC_DIR=${FFMPEG_SRC_DIR:-}
if [[ -n $FFMPEG_SRC_DIR && -d $FFMPEG_SRC_DIR/.git ]]; then
    SOURCE_DATE_EPOCH=$(git -C "$FFMPEG_SRC_DIR" show -s --format=%ct HEAD)
    export SOURCE_DATE_EPOCH
fi

# 只打包开发所需的共享库、头文件和 pkg-config,跳过二进制/文档/静态库
mkdir -p \
    "$PACKAGE_ROOT/usr" \
    "$PACKAGE_ROOT/usr/share/doc/ffmpeg-rockchip-dev"

cp -a "$INSTALL_DIR/usr/lib" "$PACKAGE_ROOT/usr/"
cp -a "$INSTALL_DIR/usr/include" "$PACKAGE_ROOT/usr/"

if [[ -n $FFMPEG_SRC_DIR ]]; then
    install -m 0644 "$FFMPEG_SRC_DIR/COPYING.LGPLv2.1" \
        "$PACKAGE_ROOT/usr/share/doc/ffmpeg-rockchip-dev/copyright" 2>/dev/null \
        || install -m 0644 "$FFMPEG_SRC_DIR/LICENSE.md" \
            "$PACKAGE_ROOT/usr/share/doc/ffmpeg-rockchip-dev/copyright" 2>/dev/null \
        || true
fi

deb_render_control "$PACKAGING_DIR/control.in" "$PACKAGE_ROOT" "$FFMPEG_VERSION"
deb_finish_package "$PACKAGE_ROOT" "$OUT_DIR" ffmpeg-rockchip-dev "$FFMPEG_VERSION"
