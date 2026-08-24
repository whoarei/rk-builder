#!/bin/bash

set -euo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/lib-deb-common.sh"

QT_VERSION=${QT_VERSION:-6.2.4}
QTBASE_SHA256=${QTBASE_SHA256:-d9924d6fd4fa5f8e24458c87f73ef3dfc1e7c9b877a5407c040d89e6736e2634}
QTSVG_SHA256=${QTSVG_SHA256:-23ec4c14259d799bb6aaf1a07559d6b1bd2cf6d0da3ac439221ebf9e46ff3fd2}
QT_HOST_PATH=${QT_HOST_PATH:-/opt/qt-host/6.2.4}
RK_SYSROOT=${RK_SYSROOT:-/opt/sysroot}
TOOLCHAIN_FILE=${TOOLCHAIN_FILE:-/opt/rk-builder/aarch64-linux-gnu.cmake}
PREFIX=/usr/local/ans

deb_common_init

PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/qt6"}
SOURCE_DIR="$WORK_DIR/source"
BUILD_DIR="$WORK_DIR/build"
INSTALL_DIR="$WORK_DIR/install"
RUNTIME_ROOT="$WORK_DIR/package-runtime"
DEV_ROOT="$WORK_DIR/package-dev"

mkdir -p "$SOURCE_DIR"
curl -fsSL -o "$WORK_DIR/qtbase.tar.xz" \
    "https://download.qt.io/archive/qt/6.2/$QT_VERSION/submodules/qtbase-everywhere-src-$QT_VERSION.tar.xz"
echo "$QTBASE_SHA256  $WORK_DIR/qtbase.tar.xz" | sha256sum --check -
tar -xf "$WORK_DIR/qtbase.tar.xz" -C "$SOURCE_DIR"
curl -fsSL -o "$WORK_DIR/qtsvg.tar.xz" \
    "https://download.qt.io/archive/qt/6.2/$QT_VERSION/submodules/qtsvg-everywhere-src-$QT_VERSION.tar.xz"
echo "$QTSVG_SHA256  $WORK_DIR/qtsvg.tar.xz" | sha256sum --check -
tar -xf "$WORK_DIR/qtsvg.tar.xz" -C "$SOURCE_DIR"

mkdir -p "$BUILD_DIR/qtbase"
(
    cd "$BUILD_DIR/qtbase"
    "$SOURCE_DIR/qtbase-everywhere-src-$QT_VERSION/configure" \
        -prefix "$PREFIX" \
        -extprefix "$INSTALL_DIR$PREFIX" \
        -qt-host-path "$QT_HOST_PATH" \
        -opensource -confirm-license \
        -release \
        -opengl es2 \
        -xcb -xcb-xlib \
        -dbus-linked -glib \
        -nomake examples -nomake tests -no-pch \
        -- \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
)
cmake --build "$BUILD_DIR/qtbase" --parallel "$(nproc)"
cmake --install "$BUILD_DIR/qtbase"

cmake -S "$SOURCE_DIR/qtsvg-everywhere-src-$QT_VERSION" -B "$BUILD_DIR/qtsvg" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_PREFIX_PATH="$INSTALL_DIR$PREFIX" \
    -DQt6_DIR="$INSTALL_DIR$PREFIX/lib/cmake/Qt6" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_STAGING_PREFIX="$INSTALL_DIR$PREFIX" \
    -DQT_HOST_PATH="$QT_HOST_PATH" \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_BUILD_TESTS=OFF \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build "$BUILD_DIR/qtsvg" --parallel "$(nproc)"
cmake --install "$BUILD_DIR/qtsvg"

aarch64-linux-gnu-readelf -h "$INSTALL_DIR$PREFIX/lib/libQt6Gui.so.6" | grep -q AArch64
if aarch64-linux-gnu-readelf -d "$INSTALL_DIR$PREFIX/lib/libQt6Gui.so.6" | grep -q 'NEEDED.*libGL\.so'; then
    echo "Qt Gui unexpectedly links desktop libGL" >&2
    exit 1
fi

mkdir -p "$RUNTIME_ROOT$PREFIX" "$RUNTIME_ROOT/usr/share/doc/qt6-ans"
for directory in lib plugins translations; do
    if [[ -d $INSTALL_DIR$PREFIX/$directory ]]; then
        cp -a "$INSTALL_DIR$PREFIX/$directory" "$RUNTIME_ROOT$PREFIX/"
    fi
done
rm -rf "$RUNTIME_ROOT$PREFIX/lib/cmake" "$RUNTIME_ROOT$PREFIX/lib/pkgconfig"
find "$RUNTIME_ROOT$PREFIX/lib" -maxdepth 1 -type l -name '*.so' -delete
find "$RUNTIME_ROOT$PREFIX" -type f \
    \( -name '*.a' -o -name '*.la' -o -name '*.prl' \) -delete
install -m 0644 "$SOURCE_DIR/qtbase-everywhere-src-$QT_VERSION/LICENSE.LGPL3" \
    "$RUNTIME_ROOT/usr/share/doc/qt6-ans/copyright"

deb_render_control "$PACKAGING_DIR/control.in" "$RUNTIME_ROOT" "$QT_VERSION" \
    PACKAGE=qt6-ans \
    SECTION=libs \
    DEPENDS="mesa25-ans (>= 25.0.7), libdrm-ans (>= 2.4.124), libc6, libstdc++6, libdbus-1-3, libfontconfig1, libfreetype6, libglib2.0-0, libx11-6, libx11-xcb1, libxcb1, libxkbcommon0, libxkbcommon-x11-0" \
    DESCRIPTION="Qt $QT_VERSION qtbase and qtsvg GLES2 libraries for Rockchip (runtime)"
deb_add_runtime_paths "$RUNTIME_ROOT" qt6-ans
deb_finish_package "$RUNTIME_ROOT" "$OUT_DIR" qt6-ans "$QT_VERSION"

mkdir -p "$DEV_ROOT$PREFIX/lib" "$DEV_ROOT/usr/share/doc/qt6-ans-dev"
cp -a "$INSTALL_DIR$PREFIX/include" "$DEV_ROOT$PREFIX/"
for directory in cmake pkgconfig; do
    if [[ -d $INSTALL_DIR$PREFIX/lib/$directory ]]; then
        cp -a "$INSTALL_DIR$PREFIX/lib/$directory" "$DEV_ROOT$PREFIX/lib/"
    fi
done
if [[ -d $INSTALL_DIR$PREFIX/mkspecs ]]; then
    cp -a "$INSTALL_DIR$PREFIX/mkspecs" "$DEV_ROOT$PREFIX/"
fi
find "$INSTALL_DIR$PREFIX/lib" -maxdepth 1 -type l -name '*.so' \
    -exec cp -a {} "$DEV_ROOT$PREFIX/lib/" \;
rm -rf \
    "$DEV_ROOT$PREFIX/lib/cmake/Qt6BuildInternals" \
    "$DEV_ROOT$PREFIX/lib/cmake/Qt6/QtBuildInternals"
install -m 0644 "$SOURCE_DIR/qtbase-everywhere-src-$QT_VERSION/LICENSE.LGPL3" \
    "$DEV_ROOT/usr/share/doc/qt6-ans-dev/copyright"

if grep -R -n -E "$INSTALL_DIR|$WORK_DIR" "$DEV_ROOT$PREFIX/lib/cmake"; then
    echo "Qt CMake metadata contains non-relocatable build paths" >&2
    exit 1
fi

deb_render_control "$PACKAGING_DIR/control.in" "$DEV_ROOT" "$QT_VERSION" \
    PACKAGE=qt6-ans-dev \
    SECTION=libdevel \
    DEPENDS="qt6-ans (= $QT_VERSION), mesa25-ans-dev (>= 25.0.7), libdrm-ans-dev (>= 2.4.124)" \
    DESCRIPTION="Qt $QT_VERSION qtbase and qtsvg GLES2 libraries for Rockchip (development files)"
deb_finish_package "$DEV_ROOT" "$OUT_DIR" qt6-ans-dev "$QT_VERSION"
