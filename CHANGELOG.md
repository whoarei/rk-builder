# Changelog

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
