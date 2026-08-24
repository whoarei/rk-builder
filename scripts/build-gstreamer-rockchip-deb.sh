#!/bin/bash

set -euo pipefail

# 交叉编译 gstreamer-rockchip 插件并打包 ARM64 deb:运行包 gst-rockchip。
#
# 插件来自 JeffyCN/mirrors 仓库的 gstreamer-rockchip 分支(meson 工程),
# 包含 rockchipmpp(MPP 硬件编解码)、kmssrc(KMS 采集)、rkximage(X11/KMS
# 输出)三个插件。依赖 arm64 sysroot 里的 GStreamer dev 库和 librga/mpp deb。
# rkximage 在固定 commit 存在上游编译错误(ximagesink.c 里 'self' 未定义),
# 且 X11 输出对无屏/解码场景没有意义,显式禁用;上游把 libdrm 依赖绑在
# rkximage 特性上,禁用它会把同样依赖 libdrm 的 kmssrc 一并跳过,因此
# 构建前把 libdrm 改绑到 kmssrc 特性(见下方 sed)。
#
# 两种用法:
#   1. 默认: 克隆源码后用 meson 交叉编译,再打 deb
#      (在 Dockerfile 的 gst-deb 阶段使用)
#   2. BUILD_INPUT=<install-tree> 跳过编译,直接打包已有的安装产物
#
# 插件本体安装在 /usr/local/ans/lib/gstreamer-1.0;系统 GStreamer 不会自动
# 扫描该目录,运行包同时安装 profile.d 片段导出 GST_PLUGIN_PATH_1_0。
# 插件只安装 .so,没有头文件/pkg-config,因此不产出 -dev 包。

# 公共库可能和脚本在同一目录(Dockerfile COPY 到 /usr/local/bin/),
# 也可能在仓库的 scripts/ 下(本地直接执行),两种布局都支持。
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

GST_ROCKCHIP_VERSION=${GST_ROCKCHIP_VERSION:-1.14.4}
GST_ROCKCHIP_COMMIT=${GST_ROCKCHIP_COMMIT:-dcbcd6454ef892e385b3a782600369eb6c0719db}
GST_ROCKCHIP_REPOSITORY=${GST_ROCKCHIP_REPOSITORY:-https://github.com/JeffyCN/mirrors.git}
BUILD_INPUT=${BUILD_INPUT:-}
PREFIX=/usr/local/ans
SYSROOT=${SYSROOT:-/opt/sysroot}

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/gstreamer-rockchip"}
SOURCE_DIR="$WORK_DIR/gstreamer-rockchip"
RUNTIME_ROOT="$WORK_DIR/package-runtime"

deb_fetch_source "$GST_ROCKCHIP_REPOSITORY" "$GST_ROCKCHIP_COMMIT" "$SOURCE_DIR"

# 上游把 libdrm 依赖绑在 rkximage 特性上,禁用 rkximage 会连带跳过
# kmssrc(它只依赖 libdrm)。这里把 libdrm 改绑到 kmssrc 特性,使
# -Drkximage=disabled 时 kmssrc 仍能构建。grep 先校验上游写法,
# 升级 commit 时若上游调整了该行会构建失败,提醒重新评估补丁。
if ! grep -q "drm_dep = dependency('libdrm', required : get_option('rkximage'))" \
    "$SOURCE_DIR/meson.build"; then
    echo "unexpected upstream meson.build: libdrm dependency wiring changed" >&2
    exit 1
fi
sed -i \
    "s/dependency('libdrm', required : get_option('rkximage'))/dependency('libdrm', required : get_option('kmssrc'))/" \
    "$SOURCE_DIR/meson.build"

# 编译阶段(BUILD_INPUT 为空时执行)。
# meson 交叉文件指定交叉工具链;依赖发现靠 pkg-config,由调用方通过
# PKG_CONFIG_LIBDIR / PKG_CONFIG_SYSROOT_DIR 环境变量限定在 sysroot 内。
if [[ -n $BUILD_INPUT ]]; then
    INSTALL_DIR=$BUILD_INPUT
else
    INSTALL_DIR="$WORK_DIR/install"
    CROSS_FILE="$WORK_DIR/cross-file.ini"
    cat > "$CROSS_FILE" <<EOF
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = false
sys_root = '$SYSROOT'
c_args = ['--sysroot=$SYSROOT']
cpp_args = ['--sysroot=$SYSROOT']
c_link_args = ['--sysroot=$SYSROOT']
cpp_link_args = ['--sysroot=$SYSROOT']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
    # Debian 11 的 meson 0.56 在交叉构建时读取不到 cross file [binaries]
    # 里的 pkg-config 条目,导致所有依赖查找失败;通过 PKG_CONFIG 环境
    # 变量提供即可(高版本 meson 两种方式都支持)。
    export PKG_CONFIG=${PKG_CONFIG:-pkg-config}
    meson setup "$WORK_DIR/build" "$SOURCE_DIR" \
        --cross-file "$CROSS_FILE" \
        --prefix "$PREFIX" \
        --libdir lib \
        --default-library shared \
        --buildtype release \
        -Dpackage-name="gst-rockchip $GST_ROCKCHIP_VERSION (rk-builder)" \
        -Dpackage-origin="https://github.com/whoarei/rk-builder" \
        -Drockchipmpp=enabled \
        -Dkmssrc=enabled \
        -Drkximage=disabled \
        || { tail -n 200 "$WORK_DIR/build/meson-logs/meson-log.txt" 2>/dev/null || true; exit 1; }
    ninja -C "$WORK_DIR/build"
    DESTDIR="$INSTALL_DIR" ninja -C "$WORK_DIR/build" install
fi

# 校验编译产物存在且为 AArch64
for plugin in rockchipmpp kmssrc; do
    if [[ ! -e $INSTALL_DIR$PREFIX/lib/gstreamer-1.0/libgst$plugin.so ]]; then
        echo "missing libgst$plugin.so in install tree" >&2
        exit 1
    fi
done
READELF_BIN=$(command -v aarch64-linux-gnu-readelf || command -v readelf)
if [[ -n $READELF_BIN ]] \
    && ! "$READELF_BIN" -h "$INSTALL_DIR$PREFIX/lib/gstreamer-1.0/libgstrockchipmpp.so" \
        | grep -q AArch64; then
    echo "libgstrockchipmpp.so is not AArch64" >&2
    exit 1
fi

# ----------------------------------------------------------------------
# 运行包 gst-rockchip:GStreamer 插件 .so + GST_PLUGIN_PATH 配置片段
# ----------------------------------------------------------------------
mkdir -p \
    "$RUNTIME_ROOT$PREFIX/lib" \
    "$RUNTIME_ROOT/usr/share/doc/gst-rockchip"

cp -a "$INSTALL_DIR$PREFIX/lib/gstreamer-1.0" "$RUNTIME_ROOT$PREFIX/lib/"

install -m 0644 "$SOURCE_DIR/COPYING" "$RUNTIME_ROOT/usr/share/doc/gst-rockchip/copyright" \
    2>/dev/null || true

# 系统 GStreamer 默认只扫描 /usr/lib/*/gstreamer-1.0,通过 profile.d 把
# /usr/local/ans 下的插件目录导出给登录 shell;服务进程需自行设置该变量。
mkdir -p "$RUNTIME_ROOT/etc/profile.d"
cat > "$RUNTIME_ROOT/etc/profile.d/gst-rockchip1.0.sh" <<'EOF'
# gstreamer-rockchip plugins installed under /usr/local/ans (rk-builder)
case ":${GST_PLUGIN_PATH_1_0:-}:" in
    *:/usr/local/ans/lib/gstreamer-1.0:*) ;;
    *) export GST_PLUGIN_PATH_1_0="/usr/local/ans/lib/gstreamer-1.0${GST_PLUGIN_PATH_1_0:+:$GST_PLUGIN_PATH_1_0}" ;;
esac
EOF
chmod 0644 "$RUNTIME_ROOT/etc/profile.d/gst-rockchip1.0.sh"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$GST_ROCKCHIP_VERSION" \
    PACKAGE=gst-rockchip \
    SECTION=libs \
    DEPENDS="gstreamer1.0-plugins-base (>= 1.14), rockchip-mpp (>= 1.3.10), librga (>= 1.10.6), libdrm2 (>= 2.4), libglib2.0-0 (>= 2.32), libc6 (>= 2.17)" \
    DESCRIPTION="GStreamer Rockchip hardware codec plugins (rockchipmpp, kmssrc)"
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" gst-rockchip "$GST_ROCKCHIP_VERSION"
