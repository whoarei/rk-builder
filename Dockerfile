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
#   4. base-sysroot    下载 arm64 Debian 依赖并组装基础 sysroot
#   5. arm64-sysroot   base-sysroot + librga/mpp/RKNN runtime deb
#   6. ffmpeg-deb      基于 arm64-sysroot 交叉编译 ffmpeg-rockchip 并打包 deb
#   7. gst-deb         基于 arm64-sysroot 交叉编译 gstreamer-rockchip 插件并打包 deb
#   8. full-sysroot    arm64-sysroot + ffmpeg deb(最终镜像用的完整 sysroot)
#   9. 最终镜像        交叉工具链 + full-sysroot + 入口脚本
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
ARG MPP_VERSION=1.1.0
ARG MPP_PC_VERSION=1.3.10

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
    MPP_PC_VERSION="$MPP_PC_VERSION" \
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
# 阶段 4: 组装基础 ARM64 sysroot
# 下载并解包 Debian ARM64 开发依赖，后续再叠加 Rockchip 组件 deb。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE} AS base-sysroot

ARG DEBIAN_FRONTEND=noninteractive

# 只下载不安装 Debian 11 的 ARM64 依赖闭包。
# 注意:排除所有 FFmpeg 相关包(包括运行库),因为后面会用 ffmpeg-rockchip
# 覆盖;否则 pkg-config 可能找到 Debian FFmpeg 4.3 的 .pc 文件。
# libmpv-dev 依赖 FFmpeg 运行库,安装后需要手动清理。
RUN dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && apt-get install -y --download-only --no-install-recommends \
        libarchive-dev:arm64 \
        libcurl4-openssl-dev:arm64 \
        libdrm-dev:arm64 \
        libegl1-mesa-dev:arm64 \
        libgbm-dev:arm64 \
        libgles2-mesa-dev:arm64 \
        libgstreamer1.0-dev:arm64 \
        libgstreamer-plugins-base1.0-dev:arm64 \
        libgmock-dev:arm64 \
        libgtest-dev:arm64 \
        libjsoncpp-dev:arm64 \
        libmpv-dev:arm64 \
        libopencv-dev:arm64 \
        libsqlite3-dev:arm64 \
        libssl-dev:arm64 \
        libudev-dev:arm64 \
        libzmq3-dev:arm64 \
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
# 阶段 5: 在 base-sysroot 之上安装 librga/mpp/RKNN runtime deb。
# ffmpeg-deb 阶段基于本阶段(需要完整 sysroot 做 configure 试编译),
# ffmpeg deb 的安装放到 full-sysroot 阶段,避免循环依赖。
# -----------------------------------------------------------------------------

FROM base-sysroot AS arm64-sysroot

ARG USE_LOCAL_DEBS=ON
ARG LIBRGA_VERSION=1.10.6
ARG MPP_VERSION=1.1.0
ARG RKNN_RUNTIME_VERSION=2.3.2
ARG FFMPEG_VERSION=6.1.0-1
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
ARG FFMPEG_ROCKCHIP_COMMIT=d547c18f18c744bc5e2180ce028fe1a6bd23ddad
ARG FFMPEG_VERSION=6.1.0-1

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
# configure 选项与之前 Dockerfile 保持一致。
RUN git init --quiet /src/ffmpeg-rockchip \
    && git -C /src/ffmpeg-rockchip remote add origin "$FFMPEG_ROCKCHIP_REPOSITORY" \
    && git -C /src/ffmpeg-rockchip fetch --quiet --depth 1 origin "$FFMPEG_ROCKCHIP_COMMIT" \
    && git -C /src/ffmpeg-rockchip checkout --quiet --detach FETCH_HEAD \
    && test "$(git -C /src/ffmpeg-rockchip rev-parse HEAD)" = "$FFMPEG_ROCKCHIP_COMMIT" \
    && cd /src/ffmpeg-rockchip \
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
        --disable-doc \
        --disable-debug \
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
RUN for deb in /tmp/debs-ffmpeg/*.deb; do \
        dpkg-deb --extract "$deb" /opt/sysroot; \
    done \
    && rm -rf /tmp/debs-ffmpeg

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

# -----------------------------------------------------------------------------
# 阶段 9: 最终镜像
# 交叉工具链 + 完整 arm64 sysroot + CMake toolchain 文件 + 入口脚本。
# 使用方式大致是:挂载源码目录到 /workspace/project,
# 容器入口脚本会带着交叉编译环境执行构建命令。
# -----------------------------------------------------------------------------

FROM debian:${DEBIAN_RELEASE}

ARG DEBIAN_FRONTEND=noninteractive
ARG RKNN_RUNTIME_VERSION=2.3.2

# 最终镜像里的构建工具:交叉编译器、CMake/Ninja、ccache(加速重复构建)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ccache \
        cmake \
        crossbuild-essential-arm64 \
        file \
        git \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 拷入包含 librga + mpp + RKNN runtime + ffmpeg-rockchip 的完整 sysroot
COPY --from=full-sysroot /opt/sysroot/ /opt/sysroot/
# aarch64 的 CMake toolchain 文件(指定编译器、sysroot、find 规则)
COPY cmake/aarch64-linux-gnu.cmake /opt/rk-builder/aarch64-linux-gnu.cmake
COPY scripts/entrypoint.sh /usr/local/bin/rk-cross-build

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
    && grep -q AV_HWDEVICE_TYPE_RKMPP \
        /opt/sysroot/usr/local/ans/include/libavutil/hwcontext.h \
    && grep -q RKNN_SUCC /opt/sysroot/usr/local/ans/include/rknn_api.h \
    && test "$(PKG_CONFIG_SYSROOT_DIR=/opt/sysroot \
        PKG_CONFIG_LIBDIR=/opt/sysroot/usr/local/ans/lib/pkgconfig \
        pkg-config --modversion rknnrt)" = "$RKNN_RUNTIME_VERSION"

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
