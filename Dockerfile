# syntax=docker/dockerfile:1

ARG DEBIAN_RELEASE=bullseye

FROM debian:${DEBIAN_RELEASE} AS librga-deb

ARG DEBIAN_FRONTEND=noninteractive
ARG LIBRGA_VERSION=1.10.6
ARG LIBRGA_COMMIT=2b32edcb97b601b25683e2941d888c8515da6d55

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates dpkg-dev git \
    && rm -rf /var/lib/apt/lists/*

COPY librga/ /opt/rk-builder/librga/
COPY scripts/build-librga-deb.sh /usr/local/bin/build-librga-deb

RUN LIBRGA_VERSION="$LIBRGA_VERSION" \
    LIBRGA_COMMIT="$LIBRGA_COMMIT" \
    PACKAGING_DIR=/opt/rk-builder/librga \
    OUT_DIR=/out \
    build-librga-deb

FROM debian:${DEBIAN_RELEASE} AS arm64-sysroot

ARG DEBIAN_FRONTEND=noninteractive

# Download the complete Debian 11 ARM64 dependency closure without installing
# it. Foreign postinst scripts (notably Python pulled by OpenCV/VTK) must never
# execute on the amd64 builder. dpkg-deb then creates a pure target sysroot.
RUN dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get install -y --download-only --no-install-recommends \
        libarchive-dev:arm64 \
        libavcodec-dev:arm64 \
        libavdevice-dev:arm64 \
        libavfilter-dev:arm64 \
        libavformat-dev:arm64 \
        libavutil-dev:arm64 \
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
        libswscale-dev:arm64 \
        libudev-dev:arm64 \
        libzmq3-dev:arm64 \
    && mkdir -p /opt/sysroot \
    && for archive in /var/cache/apt/archives/*.deb; do \
        architecture="$(dpkg-deb --field "$archive" Architecture)"; \
        if [ "$architecture" = arm64 ] || [ "$architecture" = all ]; then \
            dpkg-deb --extract "$archive" /opt/sysroot; \
        fi; \
    done \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# Debian development packages contain absolute links such as
# /usr/lib/aarch64-linux-gnu/libpthread.so -> /lib/aarch64-linux-gnu/....
# Rewrite them relative to the sysroot so the cross linker cannot escape it.
RUN find /opt/sysroot -type l -lname '/*' -exec sh -c '\
        for link do \
            target=$(readlink "$link"); \
            relative=$(realpath -m --relative-to="$(dirname "$link")" "/opt/sysroot$target"); \
            ln -snf "$relative" "$link"; \
        done \
    ' sh {} +

COPY --from=librga-deb /out/ /tmp/librga/
RUN dpkg-deb --extract /tmp/librga/*.deb /opt/sysroot \
    && rm -rf /tmp/librga

FROM debian:${DEBIAN_RELEASE} AS rockchip-mpp

ARG DEBIAN_FRONTEND=noninteractive
ARG MPP_REPOSITORY=https://github.com/rockchip-linux/mpp.git
ARG MPP_COMMIT=c08762ebfadeb4e986d2fed993bc7a54862d3ebe

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        crossbuild-essential-arm64 \
        git \
        make \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY --from=arm64-sysroot /opt/sysroot/ /opt/sysroot/

ENV PKG_CONFIG_DIR="" \
    PKG_CONFIG_PATH="" \
    PKG_CONFIG_LIBDIR=/opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/opt/sysroot

# Rockchip MPP 1.1.0 advertises rockchip_mpp 1.3.10, satisfying the
# ffmpeg-rockchip 6.1 requirement (rockchip_mpp >= 1.3.9).
RUN git init --quiet /src/mpp \
    && git -C /src/mpp remote add origin "$MPP_REPOSITORY" \
    && git -C /src/mpp fetch --quiet --depth 1 origin "$MPP_COMMIT" \
    && git -C /src/mpp checkout --quiet --detach FETCH_HEAD \
    && test "$(git -C /src/mpp rev-parse HEAD)" = "$MPP_COMMIT" \
    && cmake -S /src/mpp -B /build/mpp -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_SYSROOT=/opt/sysroot \
        -DCMAKE_FIND_ROOT_PATH=/opt/sysroot \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TEST=OFF \
    && cmake --build /build/mpp --parallel \
    && DESTDIR=/opt/sysroot cmake --install /build/mpp \
    && test "$(pkg-config --modversion rockchip_mpp)" = 1.3.10

FROM rockchip-mpp AS rockchip-media

ARG FFMPEG_ROCKCHIP_REPOSITORY=https://github.com/nyanmisaka/ffmpeg-rockchip.git
ARG FFMPEG_ROCKCHIP_COMMIT=d547c18f18c744bc5e2180ce028fe1a6bd23ddad

RUN git init --quiet /src/ffmpeg-rockchip \
    && git -C /src/ffmpeg-rockchip remote add origin "$FFMPEG_ROCKCHIP_REPOSITORY" \
    && git -C /src/ffmpeg-rockchip fetch --quiet --depth 1 origin "$FFMPEG_ROCKCHIP_COMMIT" \
    && git -C /src/ffmpeg-rockchip checkout --quiet --detach FETCH_HEAD \
    && test "$(git -C /src/ffmpeg-rockchip rev-parse HEAD)" = "$FFMPEG_ROCKCHIP_COMMIT" \
    && cd /src/ffmpeg-rockchip \
    && ./configure \
        --prefix=/usr \
        --libdir=/usr/lib/aarch64-linux-gnu \
        --incdir=/usr/include/aarch64-linux-gnu \
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
    && make DESTDIR=/opt/sysroot install \
    && test "$(pkg-config --modversion libavutil)" = 58.29.100 \
    && rm -rf /src /build

FROM debian:${DEBIAN_RELEASE}

ARG DEBIAN_FRONTEND=noninteractive

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

COPY --from=rockchip-media /opt/sysroot/ /opt/sysroot/
COPY cmake/aarch64-linux-gnu.cmake /opt/rk-builder/aarch64-linux-gnu.cmake
COPY scripts/entrypoint.sh /usr/local/bin/rk-cross-build

RUN chmod 0755 /usr/local/bin/rk-cross-build \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/lib/aarch64-linux-gnu/librga.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/lib/aarch64-linux-gnu/librockchip_mpp.so \
        | grep -q AArch64 \
    && aarch64-linux-gnu-readelf -h /opt/sysroot/usr/lib/aarch64-linux-gnu/libavutil.so \
        | grep -q AArch64 \
    && grep -q AV_HWDEVICE_TYPE_RKMPP \
        /opt/sysroot/usr/include/aarch64-linux-gnu/libavutil/hwcontext.h

ENV CCACHE_DIR=/workspace/ccache \
    CCACHE_MAXSIZE=2G \
    PKG_CONFIG_DIR="" \
    PKG_CONFIG_PATH="" \
    PKG_CONFIG_LIBDIR=/opt/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/opt/sysroot

WORKDIR /workspace/project
ENTRYPOINT ["/usr/local/bin/rk-cross-build"]
