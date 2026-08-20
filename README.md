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
- FFmpeg：从 `nyanmisaka/ffmpeg-rockchip` 的 6.1 分支交叉编译，固定 commit
  `d547c18f18c744bc5e2180ce028fe1a6bd23ddad`，启用 `libdrm`、RKMPP 和 RKRGA。
- deb 打包：librga / rockchip-mpp / ffmpeg-rockchip 共用
  `scripts/lib-deb-common.sh` 提供的初始化、源码拉取校验、control 渲染和
  打包函数，各组件脚本只保留编译与产物收集逻辑。

`airockchip/librga` 的 1.10.6 目前没有 tag，而且仓库只发布头文件、samples
和官方预编译 `librga.so`，没有发布库实现源码。因此 deb 封装的是该
commit 发布的官方 ARM64 库，不是本地重编 librga。

Debian 11 官方仓库仅提供 FFmpeg 4.3，且没有 Rockchip 的
`AV_HWDEVICE_TYPE_RKMPP`。镜像会保留 Debian ARM64 包构成的基础 sysroot，再将
上述 FFmpeg 6.1、MPP 和 RGA 安装到 `/opt/sysroot/usr/local/ans`，
供工程优先使用。

## 编译工程

在目标 CMake 工程目录下执行（输出产物在工程的 `build/release/` 或
`build/debug/`）：

```bash
/path/to/rk-builder/build.sh
/path/to/rk-builder/build.sh -d
```

也可以通过位置参数指定工程目录：

```bash
./build.sh /path/to/project
```

镜像选择规则（`auto` 模式，默认）：

1. 本地已有 GHCR 镜像（默认 `ghcr.io/whoarei/rk-builder:latest`）则直接使用；
2. 否则使用本地编译镜像 `rk-builder:debian11-arm64`；
3. 两者都不存在时拉取 GHCR 镜像；
4. 拉取失败则回退到本地编译镜像。

向 CMake 传递额外参数：

```bash
./build.sh -- -DASLAI_BUILD_UNITTESTS=OFF
```

强制拉取 GHCR 镜像或本地编译镜像：

```bash
./build.sh --pull-image
./build.sh --rebuild-image
```

## 单独生成 deb 包

librga / rockchip-mpp / ffmpeg-rockchip 每个组件都会产出两个 ARM64 deb：
安装在目标设备上的运行包（含共享库，ffmpeg 还含 `ffmpeg`/`ffprobe` 等
二进制），以及只在交叉编译 sysroot 里使用的 `-dev` 开发包（头文件、
链接器符号链接、pkg-config）。所有包统一安装到 `/usr/local/ans`，
`/usr/local` 在动态链接器搜索顺序中优先于 `/usr`，因此目标设备上
安装的库会覆盖 Debian 自带的同名库。
运行包会安装 `/etc/ld.so.conf.d/00-ans-*.conf` 并调用 `ldconfig`；
`ffmpeg-rockchip` 还会在 `/usr/local/bin` 创建命令链接，因此安装后可直接
执行 `ffmpeg`、`ffprobe` 等程序。

运行包 / 开发包对应关系：

- `librga` / `librga-dev`
- `rockchip-mpp` / `rockchip-mpp-dev`
- `ffmpeg-rockchip` / `ffmpeg-rockchip-dev`

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
docker build --target ffmpeg-debs --output type=local,dest=dist .
# 单独导出时 deb 直接在 dist/ 下
```

输出到 `dist/` 目录，例如：

- `librga_1.10.6_arm64.deb`、`librga-dev_1.10.6_arm64.deb`
- `rockchip-mpp_1.1.0_arm64.deb`、`rockchip-mpp-dev_1.1.0_arm64.deb`
- `ffmpeg-rockchip_6.1_arm64.deb`、`ffmpeg-rockchip-dev_6.1_arm64.deb`

推送对应 tag 会触发 GitHub Actions 构建 deb 并发布 Release：

- `librga-v1.10.6` → librga deb
- `mpp-v1.1.0` → rockchip-mpp deb
- `ffmpeg-rockchip-v6.1` → ffmpeg-rockchip deb

镜像构建默认开启 `USE_LOCAL_DEBS=ON`：优先用本地 `dist/` 里的 deb，其次
GitHub Release，最后才从源码编译。`--build-arg USE_LOCAL_DEBS=OFF` 强制
总是从源码编译。

## GitHub Actions

- `image.yml`：验证 Dockerfile；对 main/tag 构建并推送
  `ghcr.io/<owner>/rk-builder`。
- `librga-release.yml` / `mpp-release.yml` / `ffmpeg-rockchip-release.yml`：
  分别生成对应组件的 ARM64 deb 工件；对 `librga-v*` / `mpp-v*` /
  `ffmpeg-rockchip-v*` tag 创建 GitHub Release。三个工作流结构一致，
  只是构建目标（`librga-debs` / `mpp-debs` / `ffmpeg-debs`）不同。
