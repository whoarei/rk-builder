# Changelog

## 0.5.0 - 2026-08-27

- Mesa 上游源码版本保持 25.0.7，Debian 包版本更新为 `25.0.7-2`；release
  workflow 从 `mesa-v*` tag 自动传入包版本。
- `rk-builder.sh` 新增 `-a/--app <SUBDIR>`：在多应用工程中只交叉编译
  `PROJECT_DIR/SUBDIR` 子目录。整个工程仍挂载进容器（子目录可引用兄弟
  目录），产物写入 `build/<release|debug>/SUBDIR/`。功能通过容器入口点
  已有的 `SOURCE_DIR` 环境变量实现，`rk-cross-build` 与镜像无变化，
  新脚本可配合旧版镜像使用。

## 0.4.0 - 2026-08-24

- 将 Rockchip MPP deb 与 pkg-config 版本统一为 1.3.10，源码继续固定在
  `rockchip-linux/mpp` commit `c08762ebfadeb4e986d2fed993bc7a54862d3ebe`。
- 将 ffmpeg-rockchip 更新到 FFmpeg 6.1.6 commit
  `705345ee866866d3ea5521c89c5abd9d0b0a245b`，deb 版本更新为 6.1.6。
- 增加 libdrm 2.4.124、Mesa 25.0.7、Qt 6.2.4 的 ARM64 runtime/dev 包，
  Qt amd64 host tools，以及 CMake 3.28.6 和 OBS 桌面依赖 sysroot。
- Mesa 和 Qt Debian 包名分别为 `mesa25-ans` / `mesa25-ans-dev`
  和 `qt6-ans` / `qt6-ans-dev`。
- 增加通用 CMake/Qt 冒烟检查、组件 release workflows 与 OBS 32 交叉编译
  使用文档；OBS 工程通过独立 `obs-build.sh` 完成构建和 CPack。

## 0.3.0

- 集成 RKNN 开发包：加入 RKNPU2 2.3.2 AArch64 runtime、C API 头文件和
  pkg-config 元数据。
