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

`airockchip/librga` 的 1.10.6 目前没有 tag，而且仓库只发布头文件、samples
和官方预编译 `librga.so`，没有发布库实现源码。因此 deb 封装的是该
commit 发布的官方 ARM64 库，不是本地重编 librga。

Debian 11 官方仓库仅提供 FFmpeg 4.3，且没有 Rockchip 的
`AV_HWDEVICE_TYPE_RKMPP`。镜像会保留 Debian ARM64 包构成的基础 sysroot，再将
上述 FFmpeg 6.1、MPP 和 RGA 安装到 `/opt/sysroot/usr`，供工程优先使用。

## 编译父目录工程

将本仓库放在目标 CMake 工程的 `rk-builder/` 目录后：

```bash
./rk-builder/build.sh
./rk-builder/build.sh -d
```

默认产物位于 `rk-builder/build/release/` 或 `rk-builder/build/debug/`。也可编译其他
CMake 工程：

```bash
PROJECT_DIR=/path/to/project ./build.sh --rebuild-image
```

向 CMake 传递额外参数：

```bash
./rk-builder/build.sh -- -DASLAI_BUILD_UNITTESTS=OFF
```

使用 GitHub Container Registry 镜像：

```bash
RK_BUILDER_IMAGE=ghcr.io/whoarei/rk-builder:latest \
    ./rk-builder/build.sh --pull-image
```

## 单独生成 librga deb

```bash
./scripts/build-librga-deb.sh
```

输出为 `dist/librga-dev_1.10.6_arm64.deb`和 SHA-256 文件。在仓库推送
`librga-v1.10.6` tag 时，GitHub Actions 会自动创建 Release 并上传这两个文件。

## GitHub Actions

- `image.yml`：验证 Dockerfile；对 main/tag 构建并推送
  `ghcr.io/<owner>/rk-builder`。
- `librga-release.yml`：生成 librga ARM64 deb 工件；对 `librga-v*` tag
  创建 GitHub Release。

## 部署验证

交叉编译产物不能在 x86_64 宿主机直接运行。例如：

```bash
scp rk-builder/build/release/aslai-dispfilter root@172.16.0.249:/tmp/
ssh root@172.16.0.249 /tmp/aslai-dispfilter --help
```
