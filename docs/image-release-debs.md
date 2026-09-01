# 镜像版本与 Release deb 对照表

本文记录每个正式镜像版本所使用的、已发布到本仓库 GitHub Release 的
ARM64 deb，便于核对目标设备运行环境和交叉编译 sysroot 的组成。

- 运行包安装到 Rockchip 目标设备。
- development 包（通常以 `-dev` 结尾）用于构建镜像中的交叉编译 sysroot。
- 清单只包含 Release 资产中的 `.deb`，不包含 `.sha256`、Debian 系统依赖，
  也不包含仅在本地生成但未发布的包。

## 0.4.1

- 镜像：`ghcr.io/whoarei/rk-builder:0.4.1`
- 镜像源码 commit：见 tag `v0.4.1`
- 目标架构：ARM64 (`arm64`)
- 相对 0.4.0 的变化：librga 运行包改为版本化 SONAME 布局——以
  `librga.so.2` 为实体（SONAME=`librga.so.2`）、`librga.so` 为开发符号链接；
  ffmpeg-rockchip 随之重编，其引用 RGA 的库 NEEDED 由 `librga.so` 变为
  `librga.so.2`。其余组件 deb 版本不变（见 0.4.0 表）。

## 0.4.0

- 镜像：`ghcr.io/whoarei/rk-builder:0.4.0`
- 镜像源码 commit：`f1b512a6c9d6c3322d27b8d6a64393712ce6c8e0`
- 目标架构：ARM64 (`arm64`)
- Release deb 数量：15

| 组件 | Release tag | 运行包 | development 包 |
| --- | --- | --- | --- |
| librga | [`librga-v1.10.6`](https://github.com/whoarei/rk-builder/releases/tag/librga-v1.10.6) | `librga_1.10.6_arm64.deb` | `librga-dev_1.10.6_arm64.deb` |
| Rockchip MPP | [`mpp-v1.3.10`](https://github.com/whoarei/rk-builder/releases/tag/mpp-v1.3.10) | `rockchip-mpp_1.3.10_arm64.deb` | `rockchip-mpp-dev_1.3.10_arm64.deb` |
| RKNN Runtime | [`rknn-runtime-v2.3.2`](https://github.com/whoarei/rk-builder/releases/tag/rknn-runtime-v2.3.2) | `rknn-runtime_2.3.2_arm64.deb` | `rknn-runtime-dev_2.3.2_arm64.deb` |
| FFmpeg Rockchip | [`ffmpeg-rockchip-v6.1.6`](https://github.com/whoarei/rk-builder/releases/tag/ffmpeg-rockchip-v6.1.6) | `ffmpeg-rockchip_6.1.6_arm64.deb` | `ffmpeg-rockchip-dev_6.1.6_arm64.deb` |
| GStreamer Rockchip | [`gst-rockchip-v1.14.4`](https://github.com/whoarei/rk-builder/releases/tag/gst-rockchip-v1.14.4) | `gst-rockchip_1.14.4_arm64.deb` | —（runtime-only） |
| libdrm | [`libdrm-v2.4.124`](https://github.com/whoarei/rk-builder/releases/tag/libdrm-v2.4.124) | `libdrm-ans_2.4.124_arm64.deb` | `libdrm-ans-dev_2.4.124_arm64.deb` |
| Mesa | [`mesa-v25.0.7`](https://github.com/whoarei/rk-builder/releases/tag/mesa-v25.0.7) | `mesa25-ans_25.0.7_arm64.deb` | `mesa25-ans-dev_25.0.7_arm64.deb` |
| Qt 6 | [`qt6-v6.2.4`](https://github.com/whoarei/rk-builder/releases/tag/qt6-v6.2.4) | `qt6-ans_6.2.4_arm64.deb` | `qt6-ans-dev_6.2.4_arm64.deb` |

GStreamer 插件不提供头文件或 pkg-config 元数据，因此只发布运行包。
新增镜像版本时，请新增版本小节并保留旧版本清单，确保历史环境仍可追溯。
