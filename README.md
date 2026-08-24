# rk-builder

`rk-builder` 是面向 Rockchip Debian 11 ARM64 设备的 x86_64 Docker 交叉编译环境。
默认适用于 RK3588，也适用于运行 Debian 11 arm64 的其他 RK35xx 平台。

## 设计

- 构建工具：Debian 11 amd64 官方 GCC 10 交叉工具链。
- 目标 sysroot：通过 Debian multiarch 下载官方 `:arm64` 包，解包到
  `/opt/sysroot`。不执行任何 ARM64 `postinst`。
- Rockchip RGA：固定 `airockchip/librga` 1.10.6 commit
  `2b32edcb97b601b25683e2941d888c8515da6d55`，先生成 ARM64 deb，再解包进 sysroot。
- Rockchip MPP：从 Rockchip 官方 `rockchip-linux/mpp` 源码交叉编译，固定在
  1.1.0 tag 的 commit `c08762ebfadeb4e986d2fed993bc7a54862d3ebe`（pkg-config
  版本 1.3.10）。
- RKNN runtime：从 `airockchip/rknn_model_zoo` 封装 RKNPU2 Linux AArch64
  官方开发包，固定在 2.3.2 tag 的 commit
  `bad6c7334531becaf90a561988519b7bec34d0ab`。运行包提供
  `librknnrt.so`，开发包提供 RKNN C API 头文件和 `rknnrt.pc`；适用于
  RK356x、RK3576、RK3588 等 RKNPU2 平台。
- FFmpeg：从 `nyanmisaka/ffmpeg-rockchip` 的 6.1 分支交叉编译，固定 commit
  `d547c18f18c744bc5e2180ce028fe1a6bd23ddad`，启用 `libdrm`、RKMPP 和 RKRGA。
- GStreamer 插件：从 `JeffyCN/mirrors` 的 `gstreamer-rockchip` 分支交叉编译
  （meson 工程），固定 commit
  `dcbcd6454ef892e385b3a782600369eb6c0719db`。产出 `rockchipmpp`
  （MPP 硬件编解码）与 `kmssrc`（KMS 采集）插件；`rkximage`（X11 输出）
  在该 commit 有上游编译错误，构建时显式禁用。
- deb 打包：librga / rockchip-mpp / rknn-runtime / ffmpeg-rockchip /
  gst-rockchip 共用
  `scripts/lib-deb-common.sh` 提供的初始化、源码拉取校验、control 渲染和
  打包函数，各组件脚本只保留编译与产物收集逻辑。

`airockchip/librga` 的 1.10.6 目前没有 tag，而且仓库只发布头文件、samples
和官方预编译 `librga.so`，没有发布库实现源码。因此 deb 封装的是该
commit 发布的官方 ARM64 库，不是本地重编 librga。

Debian 11 官方仓库仅提供 FFmpeg 4.3，且没有 Rockchip 的
`AV_HWDEVICE_TYPE_RKMPP`。镜像会保留 Debian ARM64 包构成的基础 sysroot，再将
上述 FFmpeg 6.1、MPP、RGA 和 RKNN runtime 安装到
`/opt/sysroot/usr/local/ans`，
供工程优先使用。

## 编译工程

使用远程 GHCR 镜像编译。若镜像已存在于本地则直接使用，否则自动拉取：

```bash
/path/to/rk-builder/rk-builder.sh /path/to/project
/path/to/rk-builder/rk-builder.sh -d /path/to/project
```

未指定 `PROJECT_DIR` 时，默认编译当前目录。输出产物在工程的
`build/release/` 或 `build/debug/`：

```bash
cd /path/to/project
/path/to/rk-builder/rk-builder.sh
```

向 CMake 传递额外参数：

```bash
./rk-builder.sh /path/to/project -- -DASLAI_BUILD_UNITTESTS=OFF
```

脚本或自动化任务可添加 `--script`，保留环境信息输出但跳过用户确认：

```bash
./rk-builder.sh --script /path/to/project
./rk-builder-local.sh --script /path/to/project
```

需要从本仓库的 Dockerfile 重新构建本地镜像时，使用
`rk-builder-local.sh`；其项目目录和 CMake 参数用法相同：

```bash
./rk-builder-local.sh /path/to/project
./rk-builder-local.sh -d /path/to/project -- -DFOO=ON
```

### 在其他项目中使用

将仓库根目录的 `rk-builder.sh` 复制到任意 CMake 项目根目录即可使用。脚本不依赖
本仓库中的其他文件；本地不存在指定镜像时会自动拉取，并将编译产物写入当前项目：

```bash
cp /path/to/rk-builder/rk-builder.sh /path/to/project/
cd /path/to/project
./rk-builder.sh
./rk-builder.sh -d
./rk-builder.sh -- -DFOO=ON
```

默认远程镜像为 `ghcr.io/whoarei/rk-builder:latest`。可通过环境变量覆盖镜像
或并行任务数：

```bash
RK_BUILDER_IMAGE=ghcr.io/example/rk-builder:v1 JOBS=8 ./rk-builder.sh
```

`build.sh` 仅作为旧命令的兼容入口保留；新项目应直接使用上述两个脚本。
两个脚本都会在编译项目前打印镜像、工程目录、构建类型、并行数和 CMake 参数，
并在交互式终端中等待确认；`--script` 或 CI 等非交互环境会自动跳过确认。

### RKNN 开发环境测试

`examples/rknn` 通过 `pkg-config rknnrt` 查找 RKNN 头文件和链接库，编译一个
板端 smoke test。该程序加载指定的 `.rknn` 模型，调用 `rknn_init`，查询
RKNN API/驱动版本，然后调用 `rknn_destroy`：

```bash
RK_BUILDER_IMAGE=ghcr.io/whoarei/rk-builder:0.3.0 \
    ./rk-builder.sh --script examples/rknn
file examples/rknn/build/release/rknn-smoke
```

交叉编译只验证开发环境；程序需复制到安装了 `rknn-runtime`、具有匹配 NPU
驱动的 Rockchip 设备上运行，并传入该设备支持的 RKNN 模型：

```bash
./rknn-smoke /path/to/model.rknn
```

## 单独生成 deb 包

librga / rockchip-mpp / rknn-runtime / ffmpeg-rockchip 每个组件都会产出
两个 ARM64 deb：
安装在目标设备上的运行包（含共享库，ffmpeg 还含 `ffmpeg`/`ffprobe` 等
二进制），以及只在交叉编译 sysroot 里使用的 `-dev` 开发包（头文件、
链接器符号链接、pkg-config）。所有包统一安装到 `/usr/local/ans`，
`/usr/local` 在动态链接器搜索顺序中优先于 `/usr`，因此目标设备上
安装的库会覆盖 Debian 自带的同名库。
运行包会安装 `/etc/ld.so.conf.d/00-ans-*.conf` 并调用 `ldconfig`。
`ffmpeg-rockchip` 的程序安装在 `/usr/local/ans/bin`，不会在
`/usr/local/bin` 创建命令链接。

运行包 / 开发包对应关系：

- `librga` / `librga-dev`
- `rockchip-mpp` / `rockchip-mpp-dev`
- `rknn-runtime` / `rknn-runtime-dev`
- `ffmpeg-rockchip` / `ffmpeg-rockchip-dev`
- `gst-rockchip`（只有运行包：GStreamer 插件没有头文件和 pkg-config，
  不产出 `-dev` 包。插件安装在 `/usr/local/ans/lib/gstreamer-1.0`，
  系统 GStreamer 不会自动扫描该目录，运行包通过
  `/etc/profile.d/gst-rockchip1.0.sh` 为登录 shell 导出
  `GST_PLUGIN_PATH_1_0`；服务进程需自行设置该环境变量。）

deb 会发布到 GitHub Release，镜像构建时优先复用这些预编译 deb，
只有缺失或版本不匹配时才从源码编译。

本地导出全部 deb（通过 Docker 多阶段构建）：

```bash
docker build --target debs --output type=local,dest=dist .
# 产物在 dist/out/ 下
```

也可以单独导出某个组件：

```bash
docker build --target librga-debs --output type=local,dest=dist .
docker build --target mpp-debs --output type=local,dest=dist .
docker build --target rknn-runtime-debs --output type=local,dest=dist .
docker build --target ffmpeg-debs --output type=local,dest=dist .
docker build --target gst-rockchip-debs --output type=local,dest=dist .
# 单独导出时 deb 直接在 dist/ 下
```

输出到 `dist/` 目录，例如：

- `librga_1.10.6_arm64.deb`、`librga-dev_1.10.6_arm64.deb`
- `rockchip-mpp_1.1.0_arm64.deb`、`rockchip-mpp-dev_1.1.0_arm64.deb`
- `rknn-runtime_2.3.2_arm64.deb`、`rknn-runtime-dev_2.3.2_arm64.deb`
- `ffmpeg-rockchip_6.1.0-1_arm64.deb`、`ffmpeg-rockchip-dev_6.1.0-1_arm64.deb`
- `gst-rockchip_1.14.4_arm64.deb`

推送对应 tag 会触发 GitHub Actions 构建 deb 并发布 Release：

- `librga-v1.10.6` → librga deb
- `mpp-v1.1.0` → rockchip-mpp deb
- `rknn-runtime-v2.3.2` → rknn-runtime deb
- `ffmpeg-rockchip-v6.1.0-1` → ffmpeg-rockchip deb
- `gst-rockchip-v1.14.4` → gst-rockchip deb

镜像构建默认开启 `USE_LOCAL_DEBS=ON`：优先用本地 `dist/` 里的 deb，其次
GitHub Release，最后才从源码编译。`--build-arg USE_LOCAL_DEBS=OFF` 强制
总是从源码编译。

## GitHub Actions

- `image.yml`：验证 Dockerfile；对 main/tag 构建并推送
  `ghcr.io/<owner>/rk-builder`。版本 tag 同时发布带 `v` 和不带 `v` 的镜像
  tag（例如 `v0.3.0` 与 `0.3.0`）。
- `librga-release.yml` / `mpp-release.yml` / `rknn-runtime-release.yml` /
  `ffmpeg-rockchip-release.yml` / `gst-rockchip-release.yml`：分别生成对应组件的
  ARM64 deb 工件；对 `librga-v*` / `mpp-v*` / `rknn-runtime-v*` /
  `ffmpeg-rockchip-v*` / `gst-rockchip-v*` tag 创建 GitHub Release。
