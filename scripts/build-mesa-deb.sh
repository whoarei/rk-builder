#!/bin/bash

set -euo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

MESA_VERSION=${MESA_VERSION:-25.0.7}
MESA_COMMIT=${MESA_COMMIT:-742a20f48c59e8649533c84c4d49dd95b403f5da}
MESA_REPOSITORY=${MESA_REPOSITORY:-https://gitlab.freedesktop.org/mesa/mesa.git}
RK_SYSROOT=${RK_SYSROOT:-/opt/sysroot}
CROSS_FILE=${CROSS_FILE:-/opt/rk-builder/aarch64-linux-gnu.ini}
PREFIX=/usr/local/ans

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/mesa"}
SOURCE_DIR="$WORK_DIR/mesa"
BUILD_DIR="$WORK_DIR/build"
INSTALL_DIR="$WORK_DIR/install"
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"

deb_fetch_source "$MESA_REPOSITORY" "$MESA_COMMIT" "$SOURCE_DIR"
test "$(cat "$SOURCE_DIR/VERSION")" = "$MESA_VERSION"

PKG_CONFIG_DIR= \
PKG_CONFIG_PATH= \
PKG_CONFIG_LIBDIR="$RK_SYSROOT/usr/local/ans/lib/pkgconfig:$RK_SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$RK_SYSROOT/usr/lib/pkgconfig:$RK_SYSROOT/usr/share/pkgconfig" \
PKG_CONFIG_SYSROOT_DIR="$RK_SYSROOT" \
meson setup "$BUILD_DIR" "$SOURCE_DIR" \
    --cross-file "$CROSS_FILE" \
    --prefix "$PREFIX" \
    --libdir lib \
    --buildtype release \
    -Dplatforms=x11 \
    -Dgallium-drivers=panfrost,softpipe \
    -Dvulkan-drivers= \
    -Degl=enabled \
    -Dgbm=enabled \
    -Dgles1=disabled \
    -Dgles2=enabled \
    -Dopengl=true \
    -Dglx=dri \
    -Dglvnd=enabled \
    -Dshared-glapi=enabled \
    -Dllvm=disabled \
    -Dshared-llvm=disabled \
    -Dgallium-vdpau=disabled \
    -Dgallium-va=disabled \
    -Dgallium-xa=disabled \
    -Dgallium-rusticl=false \
    -Dgallium-opencl=disabled \
    -Dvideo-codecs= \
    -Dbuild-tests=false \
    -Dtools= \
    -Dosmesa=false \
    -Dvalgrind=disabled \
    -Dlibunwind=disabled \
    -Dlmsensors=disabled \
    -Dzstd=disabled \
    -Dxmlconfig=enabled
meson compile -C "$BUILD_DIR" -j "$(nproc)"
DESTDIR="$INSTALL_DIR" meson install -C "$BUILD_DIR"

# Do not leave EGL vendor resolution to the BSP's dynamic-loader ordering.
# The target keeps Debian GLVND and the vendor libmali package installed, so
# point GLVND directly at this package's Mesa implementation.
EGL_VENDOR_JSON="$INSTALL_DIR$PREFIX/share/glvnd/egl_vendor.d/50_mesa.json"
sed -i \
    "s#\"libEGL_mesa.so.0\"#\"$PREFIX/lib/libEGL_mesa.so.0\"#" \
    "$EGL_VENDOR_JSON"
grep -q "\"$PREFIX/lib/libEGL_mesa.so.0\"" "$EGL_VENDOR_JSON"

for library in \
    "$INSTALL_DIR$PREFIX/lib/dri/panfrost_dri.so" \
    "$INSTALL_DIR$PREFIX/lib/dri/panthor_dri.so" \
    "$INSTALL_DIR$PREFIX/lib/dri/rockchip_dri.so" \
    "$INSTALL_DIR$PREFIX/lib/libEGL_mesa.so.0" \
    "$INSTALL_DIR$PREFIX/lib/libgbm.so.1"; do
    test -e "$library"
    aarch64-linux-gnu-readelf -h "$library" | grep -q AArch64
done

mkdir -p \
    "$RUNTIME_ROOT/usr/local" \
    "$RUNTIME_ROOT/usr/share/doc/mesa25-ans" \
    "$RUNTIME_ROOT/etc/ld.so.conf.d" \
    "$RUNTIME_ROOT/etc/systemd/system/lightdm.service.d" \
    "$RUNTIME_ROOT/etc/lightdm/lightdm.conf.d"
cp -a "$INSTALL_DIR$PREFIX" "$RUNTIME_ROOT/usr/local/"
rm -rf "$RUNTIME_ROOT$PREFIX/include" \
    "$RUNTIME_ROOT$PREFIX/lib/cmake" \
    "$RUNTIME_ROOT$PREFIX/lib/pkgconfig"
find "$RUNTIME_ROOT$PREFIX" -type f \( -name '*.a' -o -name '*.la' \) -delete
find "$RUNTIME_ROOT$PREFIX/lib" -maxdepth 1 -type l -name '*.so' -delete
install -Dm 0755 "$PACKAGING_DIR/mesa25-run" "$RUNTIME_ROOT$PREFIX/bin/mesa25-run"
install -Dm 0755 "$PACKAGING_DIR/mesa25-xorg" "$RUNTIME_ROOT$PREFIX/bin/mesa25-xorg"
install -Dm 0644 "$PACKAGING_DIR/01-xorg-glamor.conf" \
    "$RUNTIME_ROOT$PREFIX/share/drirc.d/01-xorg-glamor.conf"
install -Dm 0644 "$PACKAGING_DIR/20-modesetting.conf" \
    "$RUNTIME_ROOT$PREFIX/share/rk-builder/mesa25-xorg.conf"
mkdir -p "$RUNTIME_ROOT$PREFIX/share/rk-builder/xorg.conf.d"
install -m 0644 "$PACKAGING_DIR/lightdm.conf" \
    "$RUNTIME_ROOT/etc/systemd/system/lightdm.service.d/mesa25-ans.conf"
install -m 0644 "$PACKAGING_DIR/lightdm-xserver.conf" \
    "$RUNTIME_ROOT/etc/lightdm/lightdm.conf.d/90-mesa25-ans.conf"
install -m 0644 "$SOURCE_DIR/docs/license.rst" "$RUNTIME_ROOT/usr/share/doc/mesa25-ans/copyright"
printf '%s\n' '/usr/local/ans/lib' \
    > "$RUNTIME_ROOT/etc/ld.so.conf.d/00-ans-mesa25-ans.conf"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$MESA_VERSION" \
    PACKAGE=mesa25-ans \
    SECTION=libs \
    DEPENDS="xserver-common (>= 2:1.20.11-1+deb11u17), xserver-xorg-core (>= 2:1.20.11-1+deb11u17), libdrm-ans (>= 2.4.124), libc6, libgcc-s1, libstdc++6, libegl1, libgles2, libgl1, libglvnd0, libexpat1, libudev1, libx11-6, libx11-xcb1, libxcb1, libxcb-dri2-0, libxcb-dri3-0, libxcb-glx0, libxcb-present0, libxcb-randr0, libxcb-shm0, libxcb-sync1, libxcb-xfixes0, libxext6, libxfixes3, libxshmfence1, libxxf86vm1, zlib1g" \
    DESCRIPTION="Mesa $MESA_VERSION Panfrost/Panthor EGL, GLES, GLX and GBM stack (runtime)"
install -m 0755 "$PACKAGING_DIR/postinst" "$RUNTIME_ROOT/DEBIAN/postinst"
install -m 0755 "$PACKAGING_DIR/postrm" "$RUNTIME_ROOT/DEBIAN/postrm"
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" mesa25-ans "$MESA_VERSION"

mkdir -p "$DEV_ROOT$PREFIX/lib" "$DEV_ROOT/usr/share/doc/mesa25-ans-dev"
cp -a "$INSTALL_DIR$PREFIX/include" "$DEV_ROOT$PREFIX/"
for metadata in cmake pkgconfig; do
    if [[ -d $INSTALL_DIR$PREFIX/lib/$metadata ]]; then
        cp -a "$INSTALL_DIR$PREFIX/lib/$metadata" "$DEV_ROOT$PREFIX/lib/"
    fi
done
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 -type l -name '*.so' \
    -exec cp -a {} "$DEV_ROOT$PREFIX/lib/" \;
install -m 0644 "$SOURCE_DIR/docs/license.rst" "$DEV_ROOT/usr/share/doc/mesa25-ans-dev/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$MESA_VERSION" \
    PACKAGE=mesa25-ans-dev \
    SECTION=libdevel \
    DEPENDS="mesa25-ans (= $MESA_VERSION), libdrm-ans-dev (>= 2.4.124), libglvnd-dev, libx11-dev, libxcb1-dev" \
    DESCRIPTION="Mesa $MESA_VERSION Panfrost/Panthor graphics stack (development files)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" mesa25-ans-dev "$MESA_VERSION"
