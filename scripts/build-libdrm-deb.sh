#!/bin/bash

set -euo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

LIBDRM_VERSION=${LIBDRM_VERSION:-2.4.124}
LIBDRM_COMMIT=${LIBDRM_COMMIT:-38ec7dbd4df3141441afafe5ac62dfc9df36a77e}
LIBDRM_REPOSITORY=${LIBDRM_REPOSITORY:-https://gitlab.freedesktop.org/mesa/drm.git}
RK_SYSROOT=${RK_SYSROOT:-/opt/sysroot}
CROSS_FILE=${CROSS_FILE:-/opt/rk-builder/aarch64-linux-gnu.ini}
PREFIX=/usr/local/ans

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/libdrm"}
SOURCE_DIR="$WORK_DIR/libdrm"
BUILD_DIR="$WORK_DIR/build"
INSTALL_DIR="$WORK_DIR/install"
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"

deb_fetch_source "$LIBDRM_REPOSITORY" "$LIBDRM_COMMIT" "$SOURCE_DIR"

PKG_CONFIG_DIR= \
PKG_CONFIG_PATH= \
PKG_CONFIG_LIBDIR="$RK_SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$RK_SYSROOT/usr/lib/pkgconfig:$RK_SYSROOT/usr/share/pkgconfig" \
PKG_CONFIG_SYSROOT_DIR="$RK_SYSROOT" \
meson setup "$BUILD_DIR" "$SOURCE_DIR" \
    --cross-file "$CROSS_FILE" \
    --prefix "$PREFIX" \
    --libdir lib \
    --buildtype release \
    -Dtests=false \
    -Dinstall-test-programs=false \
    -Dintel=disabled \
    -Dradeon=disabled \
    -Damdgpu=disabled \
    -Dnouveau=disabled \
    -Dvmwgfx=disabled \
    -Domap=disabled \
    -Dexynos=disabled \
    -Dfreedreno=disabled \
    -Dtegra=disabled \
    -Dvc4=disabled \
    -Detnaviv=disabled \
    -Dcairo-tests=disabled \
    -Dman-pages=disabled \
    -Dvalgrind=disabled
meson compile -C "$BUILD_DIR" -j "$(nproc)"
DESTDIR="$INSTALL_DIR" meson install -C "$BUILD_DIR"

test "$(aarch64-linux-gnu-readelf -h "$INSTALL_DIR$PREFIX/lib/libdrm.so.2" | sed -n 's/.*Machine:[[:space:]]*//p')" = AArch64

mkdir -p "$RUNTIME_ROOT$PREFIX/lib" "$RUNTIME_ROOT/usr/share/doc/libdrm-ans"
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 \( -type f -o -type l \) \
    -name 'libdrm*.so.*' -exec cp -a {} "$RUNTIME_ROOT$PREFIX/lib/" \;
install -m 0644 "$SOURCE_DIR/README.rst" "$RUNTIME_ROOT/usr/share/doc/libdrm-ans/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$LIBDRM_VERSION" \
    PACKAGE=libdrm-ans \
    SECTION=libs \
    DEPENDS="libc6 (>= 2.17)" \
    DESCRIPTION="libdrm $LIBDRM_VERSION for the Rockchip graphics stack (runtime)"
deb_add_runtime_paths "$RUNTIME_ROOT" libdrm-ans
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" libdrm-ans "$LIBDRM_VERSION"

mkdir -p "$DEV_ROOT$PREFIX/lib" "$DEV_ROOT/usr/share/doc/libdrm-ans-dev"
cp -a "$INSTALL_DIR$PREFIX/include" "$DEV_ROOT$PREFIX/"
cp -a "$INSTALL_DIR$PREFIX/lib/pkgconfig" "$DEV_ROOT$PREFIX/lib/"
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 -type l -name 'libdrm*.so' \
    -exec cp -a {} "$DEV_ROOT$PREFIX/lib/" \;
install -m 0644 "$SOURCE_DIR/README.rst" "$DEV_ROOT/usr/share/doc/libdrm-ans-dev/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$LIBDRM_VERSION" \
    PACKAGE=libdrm-ans-dev \
    SECTION=libdevel \
    DEPENDS="libdrm-ans (= $LIBDRM_VERSION), libc6-dev" \
    DESCRIPTION="libdrm $LIBDRM_VERSION for the Rockchip graphics stack (development files)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" libdrm-ans-dev "$LIBDRM_VERSION"
