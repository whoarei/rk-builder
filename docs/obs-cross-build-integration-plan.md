# OBS 交叉编译集成计划

## 1. 目标

将当前 `obs-buildenv` 中依赖 QEMU 的 ARM64 原生构建流程迁移到
`rk-builder`，由 x86_64 主机直接交叉编译面向 Debian 11 RK3588 的 OBS。

集成完成后只维护一个通用的 `rk-builder:latest` 镜像。镜像不仅能编译
OBS，也能编译依赖 Qt、Mesa、FFmpeg、MPP、RGA、GStreamer、RKNN、OpenCV
等组件的普通 CMake 工程。

本次集成遵循以下边界：

- 保留 `rk-builder.sh` 作为通用宿主机入口，不增加 OBS 专用逻辑。
- 保留镜像现有的 `rk-cross-build` entrypoint，不修改它的通用 CMake
  配置与构建流程。
- OBS 工程自行增加 `obs-build.sh`，负责传入 OBS 专用 CMake 参数以及执行
  CPack。
- 构建过程中不执行 ARM64 程序，也不依赖 QEMU/binfmt。
- 目标库统一安装到 sysroot 的 `/usr/local/ans` 前缀，并继续产出运行包与
  `-dev` 包；目标设备安装运行包，交叉 sysroot 同时组装运行包和开发包。

## 2. 已确定的版本基线

版本比较必须区分 deb 包版本、pkg-config 版本和源码/API 版本，不能只根据
包名中的数字判断新旧。

| 组件 | rk-builder 采用版本 | 固定来源 | 处理结论 |
| --- | --- | --- | --- |
| librga | API/deb `1.10.6` | `airockchip/librga@2b32edcb97b601b25683e2941d888c8515da6d55` | 保留 rk-builder 版本 |
| Rockchip MPP | deb/pkg-config `1.3.10` | `rockchip-linux/mpp@c08762ebfadeb4e986d2fed993bc7a54862d3ebe` | 保留 rk-builder 官方源码，统一包版本 |
| ffmpeg-rockchip | `6.1.6` | `nyanmisaka/ffmpeg-rockchip@705345ee866866d3ea5521c89c5abd9d0b0a245b` | 源码和版本跟随 obs-buildenv |
| Qt | `6.2.4` | Qt 官方 qtbase、qtsvg 源码包 | 增加 amd64 host tools 和 ARM64 target libraries |
| Mesa | `25.0.7` | Mesa 官方源码包 | ARM64 交叉编译，启用 panfrost/panthor 所需功能 |
| libdrm | `2.4.124` | freedesktop 官方源码包 | 先于 Mesa 交叉编译并安装进 sysroot |
| CMake | `3.28.6` | Kitware 官方 x86_64 二进制发行包 | 替换 Debian 11 自带的 CMake 3.18 |

### 2.1 librga 版本说明

不引入 `obs-buildenv` vendored 的 `librga2_2.2.0-1` 和
`librga-dev_2.2.0-1`：

- 这两个 deb 的实际头文件和库 API 是 `1.9.3_[2]`，pkg-config 版本是
  `2.1.0`，deb 版本 `2.2.0-1` 不是可与 API 版本直接比较的上游版本号。
- 它们的动态库 SONAME 是 `librga.so.2`；rk-builder 当前预编译库的 SONAME
  是 `librga.so`，两套包不能混装或相互覆盖。
- rk-builder 固定源码中的实际 API 是 `1.10.6_[3]`，头文件和导出接口更新，
  并且当前 ffmpeg-rockchip 已经基于该版本构建。

### 2.2 MPP 版本说明

MPP 使用 rk-builder 当前固定的官方 `rockchip-linux/mpp` 提交，不切换到
`nyanmisaka/mpp`。包版本和 `rockchip_mpp.pc` 的版本都使用 `1.3.10`。

OBS 上机验证时需重点覆盖 RK3588 的 10-bit stride、FBC/RKFBC 和 VP9 fast
mode，因为官方源码与 Jellyfin fork 在这些策略上存在行为差异。

### 2.3 FFmpeg 编译选项

FFmpeg 的源码提交和版本已经与 `obs-buildenv` 对齐。集成 OBS 依赖时建议把
下列选项也显式对齐，避免依赖 configure 默认值：

```text
--enable-shared --disable-static
--enable-gpl --enable-libx264
--enable-swscale --enable-swresample
--enable-avdevice --enable-avfilter
--enable-network --enable-gnutls
--enable-rkmpp --enable-rkrga --enable-libdrm --enable-version3
--disable-doc --disable-debug --disable-ffplay
```

包名继续采用 rk-builder 约定的 `ffmpeg-rockchip` 和
`ffmpeg-rockchip-dev`，不沿用 `ffmpeg6.1-ans-local`。在正式修改编译选项前，
需要确认通用镜像是否接受 GPL/libx264 及 GnuTLS 带来的许可证和依赖变化。

## 3. 目标架构

镜像内同时存在两类不能混用的内容：

```text
x86_64 rk-builder image
├── amd64 host tools
│   ├── CMake 3.28.6 / Ninja / pkg-config / ccache
│   └── Qt 6.2.4 host tools: moc / uic / rcc / qml tools（按 OBS 实际需要）
├── AArch64 cross toolchain
│   └── aarch64-linux-gnu-gcc/g++
└── /opt/sysroot                         ARM64 target root
    ├── Debian 11 ARM64 headers/libraries
    └── /usr/local/ans
        ├── Qt 6.2.4 target libraries
        ├── Mesa 25.0.7 + libdrm 2.4.124
        ├── librga 1.10.6
        ├── MPP 1.3.10
        ├── ffmpeg-rockchip 6.1.6
        └── RKNN / GStreamer / OpenCV 等通用组件
```

Qt 的 `moc`、`uic`、`rcc` 必须是 amd64 可执行文件；Qt 库、插件和头文件必须
是 ARM64 目标产物。CMake 查找目标包时仍受 sysroot 限制，查找构建期程序时
仍在主机路径中进行。

## 4. Dockerfile 分层方案

在不改变最终入口的前提下，按以下职责扩展现有多阶段构建。

### 4.1 `base-sysroot`

扩充 Debian 11 ARM64 依赖闭包，至少覆盖 OBS/Qt 的桌面、音频、视频和设备
接口开发包：

- X11/XCB、XKB、fontconfig、freetype、glib、DBus；
- ALSA、PulseAudio、PipeWire、speexdsp；
- OpenSSL、GnuTLS、curl、jansson、nlohmann-json；
- V4L2、udev、PCI、VA-API、DRM；
- x264、SIMDe、uthash、extra-cmake-modules；
- OBS 实际启用模块所需的其他 ARM64 `-dev` 包。

所有 Debian ARM64 包继续通过下载并 `dpkg-deb --extract` 的方式进入 sysroot，
绝不在 amd64 builder 中执行 ARM64 maintainer scripts。

### 4.2 `libdrm-deb` 与 `mesa-deb`

增加 Meson 交叉文件并使用 AArch64 编译器：

1. 交叉编译 libdrm 2.4.124，安装到临时 DESTDIR 的 `/usr/local/ans`。
2. 交叉编译 Mesa 25.0.7，至少启用 X11、EGL、GBM、GLES2、GLX、GLVND，
   Gallium driver 使用 `panfrost,softpipe`，Vulkan 暂不启用。
3. 检查 `panfrost_dri.so`、`panthor_dri.so`、`rockchip_dri.so`、
   `libEGL_mesa.so.0`、`libgbm.so.1` 和 `libdrm.so.2` 都是 AArch64 ELF。
4. 分别生成 runtime 与 `-dev` deb。运行包包含库、DRI driver 和必要的数据
   文件；开发包包含头文件、pkg-config、CMake 元数据和链接器 symlink。

旧 `obs-buildenv` 中 LightDM/Xorg 的系统级配置不能直接注入交叉 sysroot。
如设备仍需要这些配置，应由 runtime 包的设备部署策略单独维护，并在 RK3588
实机上验证，不作为通用构建镜像的隐式副作用。

### 4.3 `qt-host`

在 amd64 构建阶段安装或构建 Qt 6.2.4 host tools，建议固定到
`/opt/qt-host/6.2.4`。该阶段只服务于 Qt 本身和使用 Qt 的工程构建，不进入
ARM64 sysroot，也不进入目标设备 deb。

### 4.4 `qt-target-deb`

使用 AArch64 toolchain 和 `qt-host` 交叉编译 qtbase 6.2.4，再交叉编译
qtsvg。目标安装前缀为 `/usr/local/ans`，图形后端采用 GLES2、XCB/Xlib，
不链接目标端 desktop `libGL.so`。

产物拆分为 Qt runtime 与 `-dev` 包：

- runtime：Qt 共享库、平台插件、图像格式插件及运行所需资源；
- `-dev`：ARM64 头文件、链接文件、pkg-config/CMake metadata；
- amd64 host tools 始终留在 builder 镜像内，不打入任一 ARM64 deb。

构建后检查 `libQt6Gui.so.6` 是 AArch64，并确认其 NEEDED 项没有错误指向
amd64 库或不期望的 desktop GL。

### 4.5 `full-sysroot`

在现有 librga、MPP、RKNN、FFmpeg、GStreamer 基础上，解包 Mesa/libdrm、Qt
以及新增的 Debian ARM64 依赖。所有组件的 `.pc` 和 CMake config 中必须使用
可由 sysroot 重定位的路径，不能写入宿主机绝对路径。

### 4.6 最终镜像

最终通用镜像增加：

- CMake 3.28.6 amd64 host binary；
- Qt 6.2.4 amd64 host tools；
- Meson/Python 等仅在通用项目确有构建期需求时保留，否则只留在中间阶段；
- 扩充后的 `/opt/sysroot`。

最终镜像继续使用：

```dockerfile
ENTRYPOINT ["/usr/local/bin/rk-cross-build"]
```

不复制 `obs-buildenv` 的 `build-obs.sh`，也不把 OBS preset 写进镜像。

## 5. Toolchain 调整

`cmake/aarch64-linux-gnu.cmake` 保持当前 sysroot 查找原则：

- program：只从 amd64 host 环境查找；
- library/include/package：只从 ARM64 sysroot 查找；
- pkg-config：仅搜索 `/opt/sysroot` 中的 ARM64 metadata。

为 Qt 增加条件式 host path，推荐由最终镜像提供默认值，同时允许调用者覆盖：

```cmake
if(NOT DEFINED QT_HOST_PATH AND EXISTS "/opt/qt-host/6.2.4")
    set(QT_HOST_PATH "/opt/qt-host/6.2.4" CACHE PATH
        "Qt host tools used while cross-compiling")
endif()
```

不能把 host Qt 加入 `CMAKE_PREFIX_PATH`，否则可能让 CMake 把 amd64 Qt 库当成
目标库。`CMAKE_PREFIX_PATH` 继续只包含 sysroot 路径。

## 6. OBS 工程侧集成

OBS 仓库新增 `obs-build.sh`，但不改 rk-builder 仓库的入口脚本。它负责：

1. 确认或定位 rk-builder 仓库中的 `rk-builder.sh`。
2. 调用 `rk-builder.sh`，传入 OBS 的 preset/feature 开关、安装前缀以及必要
   的 `QT_HOST_PATH` 或 Qt package hint。
3. 保留 `rk-builder.sh` 已有的源码、build 和 ccache 挂载方式。
4. 编译完成后，用同一镜像启动第二个容器并覆盖 entrypoint 为 `cmake`，执行
   `cmake --build <build-dir> --target package` 或等价 CPack 命令。
5. 将 OBS 安装包写回宿主机 build/dist 目录。

示意流程如下，最终参数以 OBS 仓库实际 preset 为准：

```bash
rk-builder/rk-builder.sh --script /path/to/obs -- \
    -DQT_HOST_PATH=/opt/qt-host/6.2.4 \
    -DENABLE_BROWSER=OFF \
    -DENABLE_AJA=OFF

docker run --rm --entrypoint cmake \
    <与 rk-builder.sh 相同的 mounts/env> \
    rk-builder:latest \
    --build /workspace/build/release --target package
```

第二步不要在宿主机直接运行 CPack，以保证打包工具版本和构建环境一致。

## 7. 实施顺序

### 阶段 A：版本与现有包收敛

- [x] librga 保留 rk-builder `1.10.6`。
- [x] MPP 使用 rk-builder 官方提交，deb/pkg-config 统一为 `1.3.10`。
- [x] ffmpeg-rockchip 固定到 `705345ee`，包版本更新为 `6.1.6`。
- [x] 确认 FFmpeg 完全采用 obs-buildenv 的 GPL/x264/GnuTLS 选项。
- [x] 分别构建并检查 MPP、FFmpeg deb。

### 阶段 B：桌面 sysroot

- [x] 补齐 OBS/Qt 所需 Debian 11 ARM64 依赖闭包。
- [x] 增加 libdrm 2.4.124 的交叉构建和 runtime/dev 打包。
- [x] 增加 Mesa 25.0.7 的交叉构建和 runtime/dev 打包。
- [x] 增加 Mesa/libdrm 的架构、SONAME、pkg-config 和依赖自检。

### 阶段 C：Qt 与构建工具

- [x] 在最终 amd64 镜像提供 CMake 3.28.6。
- [x] 构建/安装 Qt 6.2.4 amd64 host tools。
- [x] 交叉编译 Qt 6.2.4 qtbase + qtsvg target libraries。
- [x] 生成 Qt runtime/dev deb 并组装到 full sysroot。
- [x] 为 toolchain 增加条件式 `QT_HOST_PATH`。

### 阶段 D：OBS 接入

- [x] 在 OBS 仓库增加 `obs-build.sh`。
- [x] 用通用 `rk-builder.sh` 完成 OBS configure/build。
- [x] 用覆盖 entrypoint 的第二个容器完成 CPack。
- [x] 删除 OBS 构建流程对 QEMU/binfmt 和旧 `obs-buildenv` 镜像的依赖。

### 阶段 E：发布与文档

- [x] 为 Qt、Mesa/libdrm 增加独立 deb 导出 target 和 release workflow。
- [x] 更新镜像 CI，使其至少执行通用 CMake 和 Qt 工程 smoke test。
- [x] 更新 README 的镜像能力、版本表、deb 名称和 OBS 使用示例。
- [x] 记录镜像尺寸与构建耗时，确认完整通用镜像的发布成本可接受。

### 7.1 2026-08-24 实施验证记录

- 最终本地镜像 `rk-builder:debian11-arm64` 的 Docker reported size 为
  943,154,402 bytes（约 900 MiB）；完整桌面 sysroot 变更后的本机构建约需
  8 分钟，后续缓存命中的增量构建约需 3 分钟。
- CMake 3.28.6、普通 C 和 Qt6 冒烟工程均在最终镜像构建阶段通过；Qt
  `moc`、`uic`、`rcc`、`qdbuscpp2xml` 为 x86-64，目标库为 AArch64。
- OBS 32.2.1-6-g607839700 已在无 QEMU/binfmt 的流程中完成 configure、455
  个目标的交叉编译和 CPack；deb control 中的包名为
  `obs-studio-rk3588`、架构为 `arm64`（未提交集成改动的工作树会按 OBS
  约定在版本后附加 `-modified`，CPack 文件名保留上游格式）。
- 生成的 deb 含 18 个 ELF，全部为 AArch64；未发现 `/opt/sysroot`、
  `/workspace` 或 `/tmp` RPATH/RUNPATH。desktop、metainfo 和 hicolor icons
  已迁移到标准 `/usr/share`，desktop 的 `Exec` 指向
  `/usr/local/ans/bin/obs`。
- 设备侧图形、音频、采集、推流以及 RKMPP/RGA 行为仍需按 8.3 节在 RK3588
  Debian 11 实机验证。

## 8. 验证标准

### 8.1 静态和构建期验证

- Dockerfile 每个新增 stage 能独立构建并导出 deb。
- 所有目标 `.so` 经 `readelf -h` 检查均为 AArch64。
- amd64 host tools 经 `file` 检查均为 x86-64，且可以在 builder 中执行。
- ARM64 库不存在对 amd64 路径的 RPATH/RUNPATH 或绝对链接引用。
- `pkg-config` 和 CMake package 查找只返回 `/opt/sysroot` 下的目标内容。
- `moc/uic/rcc` 使用 host Qt，Qt libraries 使用 target Qt。
- FFmpeg 头文件包含 RKMPP，且 rkmpp/rkrga encoder/decoder/filter 能被构建。
- 通用 `examples/hello` 和至少一个最小 Qt6 示例均能通过 `rk-builder.sh`
  交叉编译。

### 8.2 OBS 构建验证

- OBS configure 阶段不存在 `Exec format error`，证明未尝试执行 ARM64 工具。
- OBS 主程序和插件全部为 AArch64。
- CPack 能生成目标设备可安装包，依赖关系指向 rk-builder 发布的 runtime
  包名和版本。

### 8.3 RK3588 实机验证

- OBS 能启动并正常创建 X11/EGL/GLES 界面。
- 音频采集、V4L2/摄像头输入、显示捕获和网络推流正常。
- FFmpeg RKMPP 硬件编码与解码可用，RGA 转换路径可用。
- 验证 8-bit/10-bit、FBC/RKFBC、不同 stride 和 VP9 场景。
- Qt/Mesa/FFmpeg runtime 包也能支持非 OBS 的普通程序。
- 安装/升级 runtime 包不会覆盖系统 amd64 内容，也不会破坏设备原有 BSP
  包；如存在同名 SONAME，需通过 `/usr/local/ans` 的加载策略明确优先级。

## 9. 主要风险与控制措施

| 风险 | 控制措施 |
| --- | --- |
| CMake 误用 amd64 Qt 库或 ARM64 Qt 工具 | host tools 与 sysroot 严格分目录，设置 `QT_HOST_PATH`，增加 ELF 架构检查 |
| Debian 11 依赖过旧 | 仅对确认不足的 CMake、Mesa/libdrm、Qt 固定新版本，其余优先使用 Debian 11 ARM64 包 |
| Mesa 包修改设备 Xorg/LightDM 配置 | 构建 sysroot 与设备部署配置分离，配置变更必须单独打包并实机验证 |
| MPP 官方版与 Jellyfin fork 行为不同 | 保持当前官方源码决定，增加 RK3588 stride/FBC/VP9 回归测试 |
| librga 包版本和 API 版本混淆 | 固定 rk-builder `1.10.6`，不混装 OBS 的 `librga2` 包 |
| FFmpeg 许可证和依赖范围扩大 | 在启用 GPL/libx264/GnuTLS 前明确发布策略，并把依赖写入 runtime/dev control |
| 完整镜像体积和 CI 时间增长 | 保留多阶段缓存及独立 deb stage，记录层大小，避免将源码和中间产物复制到最终镜像 |

## 10. 完成定义

满足以下条件后可认为 OBS 已集成进 rk-builder：

1. `rk-builder:latest` 在无 QEMU/binfmt 的 x86_64 环境中完成 OBS ARM64
   configure、build 和 package。
2. `rk-builder.sh` 与 `rk-cross-build` 保持通用且无需 OBS 特判。
3. Qt/Mesa/libdrm/MPP/librga/FFmpeg 的 ARM64 runtime/dev 包版本、依赖与
   sysroot 内容一致。
4. 普通 CMake 和 Qt 工程仍可使用同一镜像构建。
5. 生成的 OBS 包在 RK3588 Debian 11 设备上通过图形、音频、采集、推流和
   RKMPP/RGA 硬件加速验证。
