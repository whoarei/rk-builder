# syntax=docker/dockerfile:1

# =============================================================================
# rk-builder：Rockchip ARM64 交叉编译环境
#
# 在 x86_64(amd64) 构建机上,交叉编译出面向 Rockchip ARM64 平台的
# librga / rockchip-mpp / RKNN runtime / ffmpeg-rockchip,并组装一个可复用的
# aarch64 sysroot + 交叉工具链镜像,用于编译依赖 RK 硬件编解码的上层项目
# (如 OBS、GStreamer 插件等)。
#
# 多阶段构建概览:
#   1. librga-deb      打包 librga deb(官方预编译库)
#   2. mpp-deb         交叉编译 Rockchip MPP 并打包 deb
#   3. rknn-runtime-deb 打包 RKNN runtime(官方预编译库与 API 头文件)
#   4. qt-host         构建 amd64 Qt host tools
#   5. base-sysroot    下载 OBS/Qt 所需 arm64 Debian 依赖并组装基础 sysroot
#   6. libdrm/mesa     交叉编译桌面图形栈并打包 runtime/dev deb
#   7. qt-target-deb   交叉编译 qtbase/qtsvg 并打包 runtime/dev deb
#   8. arm64-sysroot   桌面 sysroot + librga/mpp/RKNN runtime/dev deb
#   9. ffmpeg/gst      交叉编译 Rockchip 多媒体组件
#  10. full-sysroot    组装所有目标依赖
#  11. 最终镜像        CMake 3.28 + Qt host tools + full sysroot + 通用入口
#
# 构建开关:
#   USE_LOCAL_DEBS=ON (默认)  若 dist/ 或 GitHub Release 已有对应版本的
#   librga/mpp/RKNN/ffmpeg deb,则直接解包进 sysroot,跳过对应源码打包;
#   否则自动从源码编译。USE_LOCAL_DEBS=OFF 强制总是从源码编译。
#
# 打包约定:每个库产出运行包(如 rockchip-mpp)和开发包(*-dev)两个 deb,
# 安装前缀统一为 /usr/local/ans。sysroot 同时解包运行包和开发包。
# =============================================================================

# 基础系统版本,默认 Debian 11(bullseye)
ARG DEBIAN_RELEASE=bullseye

ARG CMAKE_VERSION=3.28.6
ARG CMAKE_X86_64_SHA256=931e3c0d546ee03ca72bb147ccd9b49e3b6252f765f66bf21b9d165519940458
ARG MESON_VERSION=1.7.2
ARG MESON_SHA256=82c6818dc81743c96de3a458f06175776ebfde4081195ea31ea6971838f25e38
ARG MESON_URL=https://files.pythonhosted.org/packages/e5/2b/46bda4ef5a7ae4135dbfe27fc0368c44e5a349a897a54fdf2cedb8dcb66e/meson-1.7.2-py3-none-any.whl
ARG LIBDRM_VERSION=2.4.124
ARG LIBDRM_COMMIT=38ec7dbd4df3141441afafe5ac62dfc9df36a77e
ARG MESA_VERSION=25.0.7
ARG MESA_COMMIT=742a20f48c59e8649533c84c4d49dd95b403f5da
ARG QT_VERSION=6.2.4
ARG QTBASE_SHA256=d9924d6fd4fa5f8e24458c87f73ef3dfc1e7c9b877a5407c040d89e6736e2634
ARG QTSVG_SHA256=23ec4c14259d799bb6aaf1a07559d6b1bd2cf6d0da3ac439221ebf9e46ff3fd2
ARG NLOHMANN_VERSION=3.11.3
ARG NLOHMANN_SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d

# -----------------------------------------------------------------------------
# 阶段 1: 构建 librga 的 .deb 包
# librga 是 Rockchip 的 2D 图像加速库(RGA),ffmpeg-rockchip 的 rkrga 依赖它。
# 打成 deb 而不是直接编译安装,是为了后面能干净地解包进 arm64 sysroot。
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_RELEASE} AS librga-deb

ARG DEBIAN_FRONTEND=noninteractive
# librga 的版本号与上游 commit,两者需对应
ARG LIBRGA_VERSION=1.10.6
ARG LIBRGA_COMMIT=2b32edcb97b601b25683e2941d888c8515da6d55

# 安装打包所需的最小工具集:dpkg-dev 提供 dpkg-deb,git 用于拉取源码
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates dpkg-dev git \
    && rm -rf /var/lib/apt/lists/*

# 本地维护的 debian 打包文件(control/rules 等)与打包脚本
COPY librga/ /opt/rk-builder/librga/
COPY scripts/build-librga-deb.sh /usr/local/bin/build-librga-deb
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

# 执行打包,产物输出到 /out/*.deb
RUN LIBRGA_VERSION="$LIBRGA_VERSION" \
    LIBRGA_COMMIT="$LIBRGA_COMMIT" \
    PACKAGING_DIR=/opt/rk-builder/librga \
    OUT_DIR=/out \
    build-librga-deb

# -----------------------------------------------------------------------------
# 阶段 2: 交叉编译 Rockchip MPP 并打包 deb
# MPP(Media Process Platform)是 Rockchip 的硬件编解码库,
# ffmpeg-rockchip 的 rkmpp 编解码器依赖它。打成 deb 以便复用与发布。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE} AS mpp-deb

ARG DEBIAN_FRONTEND=noninteractive
ARG MPP_REPOSITORY=https://github.com/rockchip-linux/mpp.git
ARG MPP_COMMIT=c08762ebfadeb4e986d2fed993bc7a54862d3ebe
# 该 commit 的官方 Git tag 为 1.1.0,源码 pkg-config/API 版本为 1.3.10;
# deb 与 pkg-config 统一使用真实接口版本 1.3.10。
ARG MPP_VERSION=1.3.10

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        crossbuild-essential-arm64 \
        dpkg-dev \
        git \
        make \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# MPP 只需要基础 sysroot(编译时只需头文件/基础 libc),复用完整
# sysroot 会循环依赖,所以这里只给编译器一个最小环境。
# 实际 sysroot 由阶段 5 组装后,再让 ffmpeg 阶段使用。
# 这里我们先编译到一个不含 Debian arm64 库的“空 sysroot”,
# 因为 MPP 只依赖 libc/libstdc++/libdrm(后两者可选)。
# 为保持简单与可复现,直接挂载一个仅含编译器与 Debian 头文件的最小根。

COPY mpp/ /opt/rk-builder/mpp/
COPY scripts/build-mpp-deb.sh /usr/local/bin/build-mpp-deb
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

# MPP 只依赖 libc/libstdc++,不依赖阶段 5 的 sysroot。
# 产物输出到 /out/*.deb
RUN MPP_VERSION="$MPP_VERSION" \
    MPP_COMMIT="$MPP_COMMIT" \
    MPP_REPOSITORY="$MPP_REPOSITORY" \
    PACKAGING_DIR=/opt/rk-builder/mpp \
    OUT_DIR=/out \
    build-mpp-deb

# -----------------------------------------------------------------------------
# 阶段 3: 打包 Rockchip RKNN runtime 的 .deb 包
# rknn_model_zoo 发布 RKNPU2 的官方预编译 librknnrt.so 与 C API 头文件。
# 这里只封装 Linux AArch64 版本，不执行任何 ARM64 二进制。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE} AS rknn-runtime-deb

ARG DEBIAN_FRONTEND=noninteractive
ARG RKNN_RUNTIME_REPOSITORY=https://github.com/airockchip/rknn_model_zoo.git
ARG RKNN_RUNTIME_COMMIT=bad6c7334531becaf90a561988519b7bec34d0ab
ARG RKNN_RUNTIME_VERSION=2.3.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        dpkg-dev \
        git \
    && rm -rf /var/lib/apt/lists/*

COPY rknn-runtime/ /opt/rk-builder/rknn-runtime/
COPY scripts/build-rknn-runtime-deb.sh /usr/local/bin/build-rknn-runtime-deb
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

RUN RKNN_RUNTIME_VERSION="$RKNN_RUNTIME_VERSION" \
    RKNN_RUNTIME_COMMIT="$RKNN_RUNTIME_COMMIT" \
    RKNN_RUNTIME_REPOSITORY="$RKNN_RUNTIME_REPOSITORY" \
    PACKAGING_DIR=/opt/rk-builder/rknn-runtime \
    OUT_DIR=/out \
    build-rknn-runtime-deb

# -----------------------------------------------------------------------------
# 阶段 4: 构建 amd64 Qt host tools。它们只在构建期执行，不进入 ARM64 包。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE} AS qt-host

ARG DEBIAN_FRONTEND=noninteractive
ARG QT_VERSION
ARG QTBASE_SHA256

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        file \
        libdbus-1-dev \
        ninja-build \
        perl \
        python3 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/qt-host
RUN curl -fsSL -o qtbase.tar.xz \
        "https://download.qt.io/archive/qt/6.2/$QT_VERSION/submodules/qtbase-everywhere-src-$QT_VERSION.tar.xz" \
    && echo "$QTBASE_SHA256  qtbase.tar.xz" | sha256sum --check - \
    && tar -xf qtbase.tar.xz \
    && mkdir build \
    && cd build \
    && "../qtbase-everywhere-src-$QT_VERSION/configure" \
        -prefix "/opt/qt-host/$QT_VERSION" \
        -opensource -confirm-license \
        -release \
        -no-opengl \
        -no-feature-xcb \
        -dbus-linked \
        -no-glib \
        -nomake examples -nomake tests -no-pch \
    && cmake --build . --parallel "$(nproc)" \
    && cmake --install .

RUN file -L "/opt/qt-host/$QT_VERSION/libexec/moc" | grep -q 'x86-64' \
    && file -L "/opt/qt-host/$QT_VERSION/libexec/uic" | grep -q 'x86-64' \
    && file -L "/opt/qt-host/$QT_VERSION/libexec/rcc" | grep -q 'x86-64' \
    && file -L "/opt/qt-host/$QT_VERSION/bin/qdbuscpp2xml" | grep -q 'x86-64'

# -----------------------------------------------------------------------------
# 阶段 5: 组装基础 ARM64 sysroot
# 下载并解包 Debian ARM64 开发依赖，后续再叠加 Rockchip 组件 deb。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE} AS base-sysroot

ARG DEBIAN_FRONTEND=noninteractive
ARG NLOHMANN_VERSION
ARG NLOHMANN_SHA256

# 只下载不安装 Debian 11 的 ARM64 依赖闭包。
# 注意:排除所有 FFmpeg 相关包(包括运行库),因为后面会用 ffmpeg-rockchip
# 覆盖;否则 pkg-config 可能找到 Debian FFmpeg 4.3 的 .pc 文件。
# libmpv-dev 依赖 FFmpeg 运行库,安装后需要手动清理。
RUN dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils-aarch64-linux-gnu build-essential ca-certificates cmake curl \
        ninja-build xz-utils \
    && apt-get install -y --download-only --no-install-recommends \
        extra-cmake-modules:arm64 \
        libasound2-dev:arm64 \
        libarchive-dev:arm64 \
        libcurl4-openssl-dev:arm64 \
        libdbus-1-dev:arm64 \
        libdrm-dev:arm64 \
        libegl-dev:arm64 \
        libexpat1-dev:arm64 \
        libfontconfig1-dev:arm64 \
        libfreetype6-dev:arm64 \
        libgbm-dev:arm64 \
        libgles-dev:arm64 \
        libglib2.0-dev:arm64 \
        libglvnd-dev:arm64 \
        libgnutls28-dev:arm64 \
        libgstreamer1.0-dev:arm64 \
        libgstreamer-plugins-base1.0-dev:arm64 \
        libgmock-dev:arm64 \
        libgtest-dev:arm64 \
        libjansson-dev:arm64 \
        libjsoncpp-dev:arm64 \
        libmbedtls-dev:arm64 \
        libmpv-dev:arm64 \
        libopencv-dev:arm64 \
        libpci-dev:arm64 \
        libpipewire-0.3-dev:arm64 \
        libpulse-dev:arm64 \
        libsimde-dev:arm64 \
        libspeexdsp-dev:arm64 \
        libsqlite3-dev:arm64 \
        libssl-dev:arm64 \
        libudev-dev:arm64 \
        libv4l-dev:arm64 \
        libva-dev:arm64 \
        libx11-dev:arm64 \
        libx11-xcb-dev:arm64 \
        libx264-dev:arm64 \
        libxcb-composite0-dev:arm64 \
        libxcb-dri2-0-dev:arm64 \
        libxcb-dri3-dev:arm64 \
        libxcb-glx0-dev:arm64 \
        libxcb-icccm4-dev:arm64 \
        libxcb-image0-dev:arm64 \
        libxcb-keysyms1-dev:arm64 \
        libxcb-present-dev:arm64 \
        libxcb-randr0-dev:arm64 \
        libxcb-render-util0-dev:arm64 \
        libxcb-render0-dev:arm64 \
        libxcb-shape0-dev:arm64 \
        libxcb-shm0-dev:arm64 \
        libxcb-sync-dev:arm64 \
        libxcb-util-dev:arm64 \
        libxcb-xfixes0-dev:arm64 \
        libxcb-xinerama0-dev:arm64 \
        libxcb-xkb-dev:arm64 \
        libxcomposite-dev:arm64 \
        libxdamage-dev:arm64 \
        libxext-dev:arm64 \
        libxfixes-dev:arm64 \
        libxinerama-dev:arm64 \
        libxkbcommon-dev:arm64 \
        libxkbcommon-x11-dev:arm64 \
        libxrandr-dev:arm64 \
        libxrender-dev:arm64 \
        libxshmfence-dev:arm64 \
        libxss-dev:arm64 \
        libxxf86vm-dev:arm64 \
        libzmq3-dev:arm64 \
        uthash-dev:arm64 \
        zlib1g-dev:arm64 \
    && mkdir -p /opt/sysroot \
    && for archive in /var/cache/apt/archives/*.deb; do \
        architecture="$(dpkg-deb --field "$archive" Architecture)"; \
        if [ "$architecture" = arm64 ] || [ "$architecture" = all ]; then \
        dpkg-deb --extract "$archive" /opt/sysroot; \
        fi; \
    done \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    # 排除 Debian FFmpeg 的 pkg-config 和头文件,防止与 ffmpeg-rockchip 冲突。
    # 这些文件可能不存在(取决于 libmpv-dev 的依赖链),用 || true 容忍。
    && (rm -f /opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig/libav*.pc \
        /opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig/libsw*.pc || true) \
    && (rm -rf /opt/sysroot/usr/include/aarch64-linux-gnu/libavcodec \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libavdevice \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libavfilter \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libavformat \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libavutil \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libswresample \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libswscale || true)

# OBS 32 需要 nlohmann-json >= 3.11，Bullseye 的开发包版本过旧。该组件
# 只有头文件和 CMake metadata，可用 amd64 CMake 安全地安装进 ARM64 sysroot。
RUN curl -fsSL -o /tmp/json.tar.xz \
        "https://github.com/nlohmann/json/releases/download/v$NLOHMANN_VERSION/json.tar.xz" \
    && echo "$NLOHMANN_SHA256  /tmp/json.tar.xz" | sha256sum --check - \
    && mkdir -p /tmp/json-src /tmp/json-build \
    && tar -xf /tmp/json.tar.xz -C /tmp/json-src --strip-components=1 \
    && cmake -S /tmp/json-src -B /tmp/json-build -G Ninja \
        -DJSON_BuildTests=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local/ans \
    && DESTDIR=/opt/sysroot cmake --install /tmp/json-build \
    && test -f /opt/sysroot/usr/local/ans/share/cmake/nlohmann_json/nlohmann_jsonConfig.cmake

# Debian 的开发包里含有指向根目录的绝对符号链接,统一改写为 sysroot 内
# 相对路径,防止交叉链接器顺着绝对路径“逃出” sysroot。
RUN find /opt/sysroot -type l -lname '/*' -exec sh -c '\
        for link do \
            target=$(readlink "$link"); \
            relative=$(realpath -m --relative-to="$(dirname "$link")" "/opt/sysroot$target"); \
            ln -snf "$relative" "$link"; \
        done \
    ' sh {} +

# -----------------------------------------------------------------------------
# 阶段 6: 交叉编译 libdrm 2.4.124 与 Mesa 25.0.7。
# -----------------------------------------------------------------------------

FROM base-sysroot AS meson-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG MESON_VERSION
ARG MESON_SHA256
ARG MESON_URL

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bison \
        ccache \
        crossbuild-essential-arm64 \
        dpkg-dev \
        flex \
        git \
        ninja-build \
        pkg-config \
        python3-mako \
        python3-packaging \
        python3-pip \
        python3-yaml \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o "/tmp/meson-$MESON_VERSION-py3-none-any.whl" "$MESON_URL" \
    && echo "$MESON_SHA256  /tmp/meson-$MESON_VERSION-py3-none-any.whl" | sha256sum --check - \
    && python3 -m pip install --no-cache-dir --no-deps \
        "/tmp/meson-$MESON_VERSION-py3-none-any.whl" \
    && test "$(meson --version)" = "$MESON_VERSION" \
    && rm -f "/tmp/meson-$MESON_VERSION-py3-none-any.whl"

COPY meson/aarch64-linux-gnu.ini /opt/rk-builder/aarch64-linux-gnu.ini
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

FROM meson-builder AS libdrm-deb

ARG LIBDRM_VERSION
ARG LIBDRM_COMMIT
ARG LIBDRM_REPOSITORY=https://gitlab.freedesktop.org/mesa/drm.git

COPY libdrm/ /opt/rk-builder/libdrm/
COPY scripts/build-libdrm-deb.sh /usr/local/bin/build-libdrm-deb

RUN LIBDRM_VERSION="$LIBDRM_VERSION" \
    LIBDRM_COMMIT="$LIBDRM_COMMIT" \
    LIBDRM_REPOSITORY="$LIBDRM_REPOSITORY" \
    PACKAGING_DIR=/opt/rk-builder/libdrm \
    OUT_DIR=/out \
    build-libdrm-deb

FROM meson-builder AS mesa-deb

ARG MESA_VERSION
ARG MESA_COMMIT
ARG MESA_REPOSITORY=https://gitlab.freedesktop.org/mesa/mesa.git

COPY --from=libdrm-deb /out/ /tmp/libdrm-debs/
RUN for deb in /tmp/libdrm-debs/*.deb; do \
        dpkg-deb --extract "$deb" /opt/sysroot; \
    done

COPY mesa/ /opt/rk-builder/mesa/
COPY scripts/build-mesa-deb.sh /usr/local/bin/build-mesa-deb

RUN MESA_VERSION="$MESA_VERSION" \
    MESA_COMMIT="$MESA_COMMIT" \
    MESA_REPOSITORY="$MESA_REPOSITORY" \
    PACKAGING_DIR=/opt/rk-builder/mesa \
    OUT_DIR=/out \
    build-mesa-deb

FROM base-sysroot AS desktop-sysroot

COPY --from=libdrm-deb /out/ /tmp/desktop-debs/libdrm/
COPY --from=mesa-deb /out/ /tmp/desktop-debs/mesa/
RUN for deb in /tmp/desktop-debs/*/*.deb; do \
        dpkg-deb --extract "$deb" /opt/sysroot; \
    done \
    && rm -rf /tmp/desktop-debs \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/libdrm.so.2 \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/dri/panfrost_dri.so \
        | grep -q AArch64

# -----------------------------------------------------------------------------
# 阶段 7: 使用 amd64 Qt tools 交叉编译 qtbase + qtsvg target libraries。
# -----------------------------------------------------------------------------

FROM desktop-sysroot AS qt-target-deb

ARG DEBIAN_FRONTEND=noninteractive
ARG QT_VERSION
ARG QTBASE_SHA256
ARG QTSVG_SHA256

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ccache \
        crossbuild-essential-arm64 \
        curl \
        dpkg-dev \
        ninja-build \
        perl \
        pkg-config \
        python3 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY --from=qt-host /opt/qt-host/ /opt/qt-host/
COPY cmake/aarch64-linux-gnu.cmake /opt/rk-builder/aarch64-linux-gnu.cmake
COPY qt6/ /opt/rk-builder/qt6/
COPY scripts/build-qt6-deb.sh /usr/local/bin/build-qt6-deb
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

ENV PKG_CONFIG_DIR="" \
    PKG_CONFIG_PATH="" \
    PKG_CONFIG_LIBDIR=/opt/sysroot/usr/local/ans/lib/pkgconfig:/opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/opt/sysroot

RUN QT_VERSION="$QT_VERSION" \
    QTBASE_SHA256="$QTBASE_SHA256" \
    QTSVG_SHA256="$QTSVG_SHA256" \
    QT_HOST_PATH="/opt/qt-host/$QT_VERSION" \
    PACKAGING_DIR=/opt/rk-builder/qt6 \
    OUT_DIR=/out \
    build-qt6-deb

# -----------------------------------------------------------------------------
# 阶段 8: 在 desktop-sysroot 之上安装 librga/mpp/RKNN runtime/dev deb。
# ffmpeg-deb 阶段基于本阶段(需要完整 sysroot 做 configure 试编译),
# ffmpeg deb 的安装放到 full-sysroot 阶段,避免循环依赖。
# -----------------------------------------------------------------------------

FROM desktop-sysroot AS arm64-sysroot

ARG USE_LOCAL_DEBS=ON
ARG LIBRGA_VERSION=1.10.6
ARG MPP_VERSION=1.3.10
ARG RKNN_RUNTIME_VERSION=2.3.2
ARG FFMPEG_VERSION=6.1.6
ARG DEBS_BASE_URL=https://github.com/whoarei/rk-builder/releases/download

# 安装 librga/mpp/RKNN runtime deb。优先使用本地 dist/ 目录,其次 GitHub Release,
# 都没有时从源码编译。
# dist/ 必须在 build context 里(.dockerignore 不排除它)。
# 如果 dist/ 不存在,COPY 会失败,所以确保仓库里 dist/ 目录存在(哪怕是空的)。
COPY dist/ /tmp/dist-local/
COPY --from=librga-deb /out/ /tmp/dist-build/librga/
COPY --from=mpp-deb /out/ /tmp/dist-build/mpp/
COPY --from=rknn-runtime-deb /out/ /tmp/dist-build/rknn-runtime/

RUN set -e; \
    fetch_deb() { \
        local name="$1" version="$2" release_tag="$3" outdir="$4"; \
        local file="${name}_${version}_arm64.deb"; \
        if [ "$USE_LOCAL_DEBS" = "ON" ] && [ -f "/tmp/dist-local/$file" ]; then \
            echo "Using local dist/$file"; \
            cp "/tmp/dist-local/$file" "$outdir/"; \
        elif [ "$USE_LOCAL_DEBS" = "ON" ] \
            && curl -fsSL "$DEBS_BASE_URL/$release_tag/$file" -o "$outdir/$file" \
            && [ -s "$outdir/$file" ]; then \
            echo "Downloaded $file from release $release_tag"; \
            # 有 sha256 则校验,没有则跳过(老 release 可能没传)
            if curl -fsSL "$DEBS_BASE_URL/$release_tag/$file.sha256" -o "$outdir/$file.sha256" \
                && [ -s "$outdir/$file.sha256" ]; then \
                (cd "$outdir" && sha256sum --check "$file.sha256"); \
            fi; \
        else \
            local build_dir; \
            case "$name" in \
                librga*) build_dir=/tmp/dist-build/librga ;; \
                rockchip-mpp*) build_dir=/tmp/dist-build/mpp ;; \
                rknn-runtime*) build_dir=/tmp/dist-build/rknn-runtime ;; \
            esac; \
            echo "Using source-built $file"; \
            cp "$build_dir/$file" "$outdir/"; \
        fi; \
    }; \
    mkdir -p /tmp/debs; \
    fetch_deb librga-dev "$LIBRGA_VERSION" "librga-v$LIBRGA_VERSION" /tmp/debs; \
    fetch_deb rockchip-mpp-dev "$MPP_VERSION" "mpp-v$MPP_VERSION" /tmp/debs; \
    fetch_deb rknn-runtime-dev "$RKNN_RUNTIME_VERSION" "rknn-runtime-v$RKNN_RUNTIME_VERSION" /tmp/debs; \
    fetch_deb librga "$LIBRGA_VERSION" "librga-v$LIBRGA_VERSION" /tmp/debs; \
    fetch_deb rockchip-mpp "$MPP_VERSION" "mpp-v$MPP_VERSION" /tmp/debs; \
    fetch_deb rknn-runtime "$RKNN_RUNTIME_VERSION" "rknn-runtime-v$RKNN_RUNTIME_VERSION" /tmp/debs; \
    for deb in /tmp/debs/*.deb; do \
        dpkg-deb --extract "$deb" /opt/sysroot; \
    done \
    && rm -rf /tmp/dist-local /tmp/dist-build /tmp/debs

# -----------------------------------------------------------------------------
# 阶段 6: 交叉编译 ffmpeg-rockchip 并打包 deb。
# 最终镜像用这个,用户链接时能找到所有 Rockchip 相关库。
# -----------------------------------------------------------------------------

FROM arm64-sysroot AS ffmpeg-deb

ARG DEBIAN_FRONTEND=noninteractive
ARG FFMPEG_ROCKCHIP_REPOSITORY=https://github.com/nyanmisaka/ffmpeg-rockchip.git
ARG FFMPEG_ROCKCHIP_COMMIT=705345ee866866d3ea5521c89c5abd9d0b0a245b
# 上游基线和本项目 deb 版本统一为 FFmpeg 6.1.6。
ARG FFMPEG_VERSION=6.1.6

# arm64-sysroot 阶段已包含完整的 Debian arm64 sysroot + librga/mpp deb,
# 无需额外安装。

# 安装编译工具(arm64-sysroot 阶段只有 sysroot,没有交叉编译器)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        crossbuild-essential-arm64 \
        dpkg-dev \
        git \
        make \
        nasm \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

ENV PKG_CONFIG_DIR="" \
    PKG_CONFIG_PATH="" \
    PKG_CONFIG_LIBDIR=/opt/sysroot/usr/local/ans/lib/pkgconfig:/opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/opt/sysroot

COPY ffmpeg-rockchip/ /opt/rk-builder/ffmpeg-rockchip/
COPY scripts/build-ffmpeg-rockchip-deb.sh /usr/local/bin/build-ffmpeg-rockchip-deb
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

# 编译 ffmpeg 到 /tmp/install,然后交给打包脚本生成 deb。
# configure 选项与之前 Dockerfile 保持一致。这个 release-branch 提交只有
# RELEASE=6.1.6 而没有 VERSION 文件；显式生成 VERSION，避免浅克隆使
# libavutil/ffversion.h 只记录短 SHA，导致消费方无法识别 FFmpeg 版本。
RUN git init --quiet /src/ffmpeg-rockchip \
    && git -C /src/ffmpeg-rockchip remote add origin "$FFMPEG_ROCKCHIP_REPOSITORY" \
    && git -C /src/ffmpeg-rockchip fetch --quiet --depth 1 origin "$FFMPEG_ROCKCHIP_COMMIT" \
    && git -C /src/ffmpeg-rockchip checkout --quiet --detach FETCH_HEAD \
    && test "$(git -C /src/ffmpeg-rockchip rev-parse HEAD)" = "$FFMPEG_ROCKCHIP_COMMIT" \
    && cd /src/ffmpeg-rockchip \
    && printf '%s\n' "$FFMPEG_VERSION" > VERSION \
    && ./configure \
        --prefix=/usr/local/ans \
        --arch=aarch64 \
        --target-os=linux \
        --cross-prefix=aarch64-linux-gnu- \
        --sysroot=/opt/sysroot \
        --pkg-config=pkg-config \
        --enable-cross-compile \
        --enable-shared \
        --disable-static \
        --enable-gpl \
        --enable-libx264 \
        --enable-swscale \
        --enable-swresample \
        --enable-avdevice \
        --enable-avfilter \
        --enable-network \
        --enable-gnutls \
        --disable-doc \
        --disable-debug \
        --disable-ffplay \
        --enable-pic \
        --enable-version3 \
        --enable-libdrm \
        --enable-rkmpp \
        --enable-rkrga \
        || { tail -n 200 ffbuild/config.log; exit 1; } \
    && grep -q '^#define CONFIG_RKMPP 1' config.h \
    && grep -q '^#define CONFIG_RKRGA 1' config.h \
    && make -j"$(nproc)" \
    && make DESTDIR=/tmp/install install \
    && grep -q "FFMPEG_VERSION \"$FFMPEG_VERSION\"" \
        /tmp/install/usr/local/ans/include/libavutil/ffversion.h \
    && test "$(PKG_CONFIG_SYSROOT_DIR=/tmp/install \
        PKG_CONFIG_LIBDIR=/tmp/install/usr/local/ans/lib/pkgconfig \
        pkg-config --modversion libavutil)" = 58.29.100

# 打包步骤独立出来,避免被 ffmpeg 编译的大量输出淹没,方便排查。
RUN BUILD_INPUT=/tmp/install \
    FFMPEG_VERSION="$FFMPEG_VERSION" \
    FFMPEG_SRC_DIR=/src/ffmpeg-rockchip \
    PACKAGING_DIR=/opt/rk-builder/ffmpeg-rockchip \
    OUT_DIR=/out \
    build-ffmpeg-rockchip-deb

# -----------------------------------------------------------------------------
# 阶段 7: 交叉编译 gstreamer-rockchip 插件并打包 deb
# JeffyCN 维护的 GStreamer Rockchip 插件(meson 工程),含 rockchipmpp
# (MPP 硬件编解码)与 kmssrc(KMS 采集)插件。依赖 arm64-sysroot 里的
# GStreamer dev 库和 librga/mpp deb。rkximage(X11 输出)在上游固定
# commit 存在编译错误,构建脚本里显式禁用。
# -----------------------------------------------------------------------------

FROM arm64-sysroot AS gst-deb

ARG DEBIAN_FRONTEND=noninteractive
ARG GST_ROCKCHIP_REPOSITORY=https://github.com/JeffyCN/mirrors.git
ARG GST_ROCKCHIP_COMMIT=dcbcd6454ef892e385b3a782600369eb6c0719db
ARG GST_ROCKCHIP_VERSION=1.14.4

# arm64-sysroot 阶段已包含 GStreamer dev 库和 librga/mpp deb,
# 这里只需交叉工具链与 meson/ninja。python3-setuptools 是上游
# meson.build 里 python3 find_program 校验所必需的。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        crossbuild-essential-arm64 \
        dpkg-dev \
        git \
        meson \
        ninja-build \
        pkg-config \
        python3-setuptools \
    && rm -rf /var/lib/apt/lists/*

ENV PKG_CONFIG_DIR="" \
    PKG_CONFIG_PATH="" \
    PKG_CONFIG_LIBDIR=/opt/sysroot/usr/local/ans/lib/pkgconfig:/opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/opt/sysroot

COPY gstreamer-rockchip/ /opt/rk-builder/gstreamer-rockchip/
COPY scripts/build-gstreamer-rockchip-deb.sh /usr/local/bin/build-gstreamer-rockchip-deb
COPY scripts/lib-deb-common.sh /usr/local/bin/lib-deb-common.sh

# 拉源码 → meson 交叉编译 → 打 deb,产物输出到 /out/*.deb
RUN GST_ROCKCHIP_VERSION="$GST_ROCKCHIP_VERSION" \
    GST_ROCKCHIP_COMMIT="$GST_ROCKCHIP_COMMIT" \
    GST_ROCKCHIP_REPOSITORY="$GST_ROCKCHIP_REPOSITORY" \
    PACKAGING_DIR=/opt/rk-builder/gstreamer-rockchip \
    OUT_DIR=/out \
    build-gstreamer-rockchip-deb

# -----------------------------------------------------------------------------
# 阶段 8: 组装完整 arm64 sysroot
# sysroot 是交叉编译的目标环境根目录,包含 arm64 的头文件和库,
# 交叉链接器只在这里面找依赖,保证不会误用宿主机的 amd64 库。
#
# 若 dist/ 或 GitHub Release 已提供对应版本的 librga/mpp/RKNN/ffmpeg deb,
# 则直接解包;否则回退到从源码编译(阶段 1-3)。
# -----------------------------------------------------------------------------

FROM arm64-sysroot AS full-sysroot

COPY --from=ffmpeg-deb /out/ /tmp/debs-ffmpeg/
COPY --from=qt-target-deb /out/ /tmp/debs-qt/
RUN for deb in /tmp/debs-ffmpeg/*.deb /tmp/debs-qt/*.deb; do \
        dpkg-deb --extract "$deb" /opt/sysroot; \
    done \
    && rm -rf /tmp/debs-ffmpeg /tmp/debs-qt

# -----------------------------------------------------------------------------
# 汇总阶段: 把所有 deb 收集到 /out,方便 CI 用
#   docker build --target debs --output type=local,dest=dist .
# 一条命令导出全部 deb。
# -----------------------------------------------------------------------------

FROM scratch AS debs
COPY --from=librga-deb /out/ /out/
COPY --from=mpp-deb /out/ /out/
COPY --from=rknn-runtime-deb /out/ /out/
COPY --from=ffmpeg-deb /out/ /out/
COPY --from=gst-deb /out/ /out/
COPY --from=libdrm-deb /out/ /out/
COPY --from=mesa-deb /out/ /out/
COPY --from=qt-target-deb /out/ /out/

# 单独导出每个 deb 的 scratch 阶段,供各 release workflow 用
# --target librga-debs / mpp-debs / rknn-runtime-debs / ffmpeg-debs /
# gst-rockchip-debs 导出。
# 这些阶段只包含 /out 目录,--output type=local 导出干净。
FROM scratch AS librga-debs
COPY --from=librga-deb /out/ /

FROM scratch AS mpp-debs
COPY --from=mpp-deb /out/ /

FROM scratch AS rknn-runtime-debs
COPY --from=rknn-runtime-deb /out/ /

FROM scratch AS ffmpeg-debs
COPY --from=ffmpeg-deb /out/ /

FROM scratch AS gst-rockchip-debs
COPY --from=gst-deb /out/ /

FROM scratch AS libdrm-debs
COPY --from=libdrm-deb /out/ /

FROM scratch AS mesa-debs
COPY --from=mesa-deb /out/ /

FROM scratch AS qt6-debs
COPY --from=qt-target-deb /out/ /

# -----------------------------------------------------------------------------
# 阶段 9: 最终镜像
# 交叉工具链 + 完整 arm64 sysroot + CMake toolchain 文件 + 入口脚本。
# 使用方式大致是:挂载源码目录到 /workspace/project,
# 容器入口脚本会带着交叉编译环境执行构建命令。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE}

ARG DEBIAN_FRONTEND=noninteractive
ARG RKNN_RUNTIME_VERSION=2.3.2
ARG CMAKE_VERSION
ARG CMAKE_X86_64_SHA256
ARG QT_VERSION

# 最终镜像里的构建工具:交叉编译器、CMake/Ninja、ccache(加速重复构建)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ccache \
        crossbuild-essential-arm64 \
        curl \
        dpkg-dev \
        file \
        git \
        ninja-build \
        pkg-config \
        xz-utils \
    && curl -fsSL -o /tmp/cmake.tar.gz \
        "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-x86_64.tar.gz" \
    && echo "$CMAKE_X86_64_SHA256  /tmp/cmake.tar.gz" | sha256sum --check - \
    && tar -xzf /tmp/cmake.tar.gz -C /usr/local --strip-components=1 \
    && test "$(cmake --version | sed -n '1s/cmake version //p')" = "$CMAKE_VERSION" \
    && rm -rf /var/lib/apt/lists/*

# 拷入包含 librga + mpp + RKNN runtime + ffmpeg-rockchip 的完整 sysroot
COPY --from=full-sysroot /opt/sysroot/ /opt/sysroot/
COPY --from=qt-host /opt/qt-host/ /opt/qt-host/
# aarch64 的 CMake toolchain 文件(指定编译器、sysroot、find 规则)
COPY cmake/aarch64-linux-gnu.cmake /opt/rk-builder/aarch64-linux-gnu.cmake
COPY scripts/entrypoint.sh /usr/local/bin/rk-cross-build
COPY examples/hello/ /tmp/smoke/hello/
COPY examples/qt/ /tmp/smoke/qt/

# 构建期自检,尽早暴露 sysroot 问题:
#   1. 关键动态库确实是 AArch64 架构(防止混进 amd64 库)
#   2. FFmpeg 头文件里确实包含 RKMPP 硬件设备类型
#   3. RKNN C API 头文件与 pkg-config 元数据已安装
RUN chmod 0755 /usr/local/bin/rk-cross-build \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/librga.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/librockchip_mpp.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/librknnrt.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/libavutil.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/libdrm.so.2 \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/dri/panthor_dri.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/local/ans/lib/libQt6Gui.so.6 \
        | grep -q AArch64 \
    && file -L "/opt/qt-host/$QT_VERSION/libexec/moc" | grep -q 'x86-64' \
    && file -L "/opt/qt-host/$QT_VERSION/libexec/uic" | grep -q 'x86-64' \
    && file -L "/opt/qt-host/$QT_VERSION/libexec/rcc" | grep -q 'x86-64' \
    && file -L "/opt/qt-host/$QT_VERSION/bin/qdbuscpp2xml" | grep -q 'x86-64' \
    && grep -q AV_HWDEVICE_TYPE_RKMPP \
        /opt/sysroot/usr/local/ans/include/libavutil/hwcontext.h \
    && grep -q RKNN_SUCC /opt/sysroot/usr/local/ans/include/rknn_api.h \
    && test "$(PKG_CONFIG_SYSROOT_DIR=/opt/sysroot \
        PKG_CONFIG_LIBDIR=/opt/sysroot/usr/local/ans/lib/pkgconfig \
        pkg-config --modversion rknnrt)" = "$RKNN_RUNTIME_VERSION" \
    && cmake -S /tmp/smoke/hello -B /tmp/smoke/build-hello -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE=/opt/rk-builder/aarch64-linux-gnu.cmake \
    && cmake --build /tmp/smoke/build-hello \
    && aarch64-linux-gnu-readelf -h /tmp/smoke/build-hello/hello | grep -q AArch64 \
    && cmake -S /tmp/smoke/qt -B /tmp/smoke/build-qt -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE=/opt/rk-builder/aarch64-linux-gnu.cmake \
    && cmake --build /tmp/smoke/build-qt \
    && aarch64-linux-gnu-readelf -h /tmp/smoke/build-qt/qt-cross-smoke | grep -q AArch64 \
    && rm -rf /tmp/smoke

# 运行时环境:
#   ccache 缓存目录指向挂载卷,跨容器构建也能命中缓存
#   pkg-config 配置同阶段 3,保证使用者的构建也只查 sysroot
ENV CCACHE_DIR=/workspace/ccache \
    CCACHE_MAXSIZE=2G \
    PKG_CONFIG_DIR="" \
    PKG_CONFIG_PATH="" \
    PKG_CONFIG_LIBDIR=/opt/sysroot/usr/local/ans/lib/pkgconfig:/opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/opt/sysroot

WORKDIR /workspace/project
ENTRYPOINT ["/usr/local/bin/rk-cross-build"]
