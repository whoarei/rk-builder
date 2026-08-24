#!/bin/bash

set -euo pipefail

# 打包 ffmpeg-rockchip ARM64 deb:运行包 ffmpeg-rockchip + 开发包
# ffmpeg-rockchip-dev。
#
# 编译在 Dockerfile 的 ffmpeg-deb 阶段完成(需要交叉编译环境和
# librga/mpp sysroot),本脚本只负责把 DESTDIR 安装好的产物封成 deb。
#
# 用法:
#   BUILD_INPUT=<install-tree>              必传,DESTDIR 安装树
#   FFMPEG_SRC_DIR=<源码目录>               可选,用于取 license 和
#                                            SOURCE_DATE_EPOCH,不传则跳过
#   ./build-ffmpeg-rockchip-deb.sh
#
# 安装前缀为 /usr/local/ans(高于 /usr 的搜索优先级)。

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

FFMPEG_VERSION=${FFMPEG_VERSION:-6.1.6}
FFMPEG_COMMIT=${FFMPEG_COMMIT:-705345ee866866d3ea5521c89c5abd9d0b0a245b}
FFMPEG_REPOSITORY=${FFMPEG_REPOSITORY:-https://github.com/nyanmisaka/ffmpeg-rockchip.git}
BUILD_INPUT=${BUILD_INPUT:-}
PREFIX=/usr/local/ans

if [[ -z $BUILD_INPUT ]]; then
    echo "BUILD_INPUT (ffmpeg DESTDIR install tree) is required" >&2
    exit 2
fi

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/ffmpeg-rockchip"}
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"
INSTALL_DIR=$BUILD_INPUT

# 如果提供了源码目录,从中取 license 和 commit 时间戳;
# 否则用当前时间(不影响功能,只是 deb 内容时间戳不可复现)。
FFMPEG_SRC_DIR=${FFMPEG_SRC_DIR:-}
if [[ -n $FFMPEG_SRC_DIR && -d $FFMPEG_SRC_DIR/.git ]]; then
    SOURCE_DATE_EPOCH=$(git -C "$FFMPEG_SRC_DIR" show -s --format=%ct HEAD)
    export SOURCE_DATE_EPOCH
fi

copy_license()
{
    local dest=$1
    if [[ -n $FFMPEG_SRC_DIR ]]; then
        install -m 0644 "$FFMPEG_SRC_DIR/COPYING.LGPLv2.1" "$dest" 2>/dev/null \
            || install -m 0644 "$FFMPEG_SRC_DIR/LICENSE.md" "$dest" 2>/dev/null \
            || true
    fi
}

# ----------------------------------------------------------------------
# 运行包 ffmpeg-rockchip:共享库实体 + soname 链接 + ffmpeg/ffprobe 等
# 二进制,不带头文件/pkg-config/开发用 .so 链接
# ----------------------------------------------------------------------
mkdir -p \
    "$RUNTIME_ROOT$PREFIX" \
    "$RUNTIME_ROOT/usr/share/doc/ffmpeg-rockchip"

cp -a "$INSTALL_DIR$PREFIX/lib" "$RUNTIME_ROOT$PREFIX/"
if [[ -d $INSTALL_DIR$PREFIX/bin ]]; then
    cp -a "$INSTALL_DIR$PREFIX/bin" "$RUNTIME_ROOT$PREFIX/"
fi
rm -rf "$RUNTIME_ROOT$PREFIX/lib/pkgconfig"
# 开发用链接器符号链接(libfoo.so)不进运行包
find "$RUNTIME_ROOT$PREFIX/lib" -maxdepth 1 -type l -name 'lib*.so' -delete

copy_license "$RUNTIME_ROOT/usr/share/doc/ffmpeg-rockchip/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$FFMPEG_VERSION" \
    PACKAGE=ffmpeg-rockchip \
    SECTION=libs \
    DEPENDS="rockchip-mpp (>= 1.3.10), librga (>= 1.10.6), libdrm-ans (>= 2.4.124), libgnutls30, libx264-160, libc6 (>= 2.17)" \
    DESCRIPTION="FFmpeg with Rockchip hardware acceleration, rkmpp/rkrga (runtime)"
deb_add_runtime_paths "$RUNTIME_ROOT" ffmpeg-rockchip
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" ffmpeg-rockchip "$FFMPEG_VERSION"

# ----------------------------------------------------------------------
# 开发包 ffmpeg-rockchip-dev:头文件 + pkg-config + 链接器 .so 链接
# ----------------------------------------------------------------------
mkdir -p \
    "$DEV_ROOT$PREFIX/lib/pkgconfig" \
    "$DEV_ROOT/usr/share/doc/ffmpeg-rockchip-dev"

cp -a "$INSTALL_DIR$PREFIX/include" "$DEV_ROOT$PREFIX/"
cp -a "$INSTALL_DIR$PREFIX/lib/pkgconfig/." "$DEV_ROOT$PREFIX/lib/pkgconfig/"
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 -type l -name 'lib*.so' \
    -exec cp -a {} "$DEV_ROOT$PREFIX/lib/" \;

copy_license "$DEV_ROOT/usr/share/doc/ffmpeg-rockchip-dev/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$FFMPEG_VERSION" \
    PACKAGE=ffmpeg-rockchip-dev \
    SECTION=libdevel \
    DEPENDS="ffmpeg-rockchip (= $FFMPEG_VERSION), rockchip-mpp-dev (>= 1.3.10), librga-dev (>= 1.10.6), libdrm-ans-dev (>= 2.4.124), libgnutls28-dev, libx264-dev, libc6-dev" \
    DESCRIPTION="FFmpeg with Rockchip hardware acceleration, rkmpp/rkrga (development files)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" ffmpeg-rockchip-dev "$FFMPEG_VERSION"
