# Repository Guidelines

## Project Structure & Module Organization

`rk-builder` is a Docker-based x86_64 → ARM64 cross-compile environment for
Rockchip Debian 11 devices (default target: RK3588). Each component ships
two debs — a runtime package (e.g. `rockchip-mpp`) for target devices and a
`-dev` package for the cross sysroot — all installed under the
/usr/local/ans prefix.

- `Dockerfile`: multi-stage build — librga deb packaging, arm64 sysroot
  assembly, Rockchip MPP and ffmpeg-rockchip cross-compiles, final image.
- `rk-builder.sh`: portable entry point using the cached or remote GHCR image.
- `rk-builder-local.sh`: repository-local entry point that rebuilds the image
  from the Dockerfile before compiling a CMake project.
- `build.sh`: deprecated compatibility wrapper for the two entry points.
- `scripts/`: `entrypoint.sh` (container entrypoint `rk-cross-build`) and
  `lib-deb-common.sh` (shared deb packaging helpers), and the standalone
  ARM64 deb packagers `build-librga-deb.sh`, `build-mpp-deb.sh`,
  `build-ffmpeg-rockchip-deb.sh`.
- `cmake/aarch64-linux-gnu.cmake`: CMake toolchain file (compiler, sysroot,
  find rules).
- `librga/`: deb packaging templates (`control.in`, `librga.pc.in`).
- `.github/workflows/`: `image.yml` (image CI) and deb release workflows
  `librga-release.yml`, `mpp-release.yml`, `ffmpeg-rockchip-release.yml`
  on `librga-v*`, `mpp-v*`, `ffmpeg-rockchip-v*` tags respectively.
- `mpp/`: deb packaging templates (`control.in`, `rockchip_mpp.pc.in`)
- `ffmpeg-rockchip/`: deb packaging templates (`control.in`)
- `build/`, `.ccache/`, `dist/`: generated artifacts; never commit these.
- `examples/`: example projects

## Build, Test, and Development Commands

- `./rk-builder.sh examples/hello` — build the example project using the
  cached or remote GHCR image; useful for smoke-testing the toolchain.
- `./rk-builder.sh -d examples/hello` — Debug build; output in
  `examples/hello/build/debug/`.
- `./rk-builder-local.sh examples/hello` — rebuild the local image from the
  current Dockerfile, then build the example project.
- `./rk-builder.sh examples/hello -- -DFOO=ON` — pass extra CMake arguments.
- `./rk-builder.sh --script examples/hello` — print the build environment but
  skip interactive confirmation for scripts or automation.
- `RK_BUILDER_IMAGE=ghcr.io/whoarei/rk-builder:latest ./rk-builder.sh
  examples/hello` — use the specified prebuilt image.
- `./scripts/build-librga-deb.sh` / `build-mpp-deb.sh` /
  `build-ffmpeg-rockchip-deb.sh` — produce the ARM64 debs under `dist/`
  plus their SHA-256 files. Each script emits two packages: a runtime deb
  and a `-dev` deb, both targeting the /usr/local/ans prefix.
- `docker build -t rk-builder:debian11-arm64 .` — build the image directly.

Cross-compiled binaries cannot run on the x86_64 host; verify them on a target
device (see the "部署验证" section of `README.md`).

## Coding Style & Naming Conventions

- Shell scripts: bash with `set -euo pipefail`, 4-space indentation, function
  names in `snake_case`, environment overrides in `UPPER_CASE` (e.g.
  `RK_BUILDER_IMAGE`, `RK_BUILDER_LOCAL_IMAGE`).
- Dockerfile: multi-line `RUN` chains joined with `&&`; explanatory comments
  go above the block, never between continuation lines (a `#` mid-chain breaks
  the line continuation).
- Pinned upstream sources use `ARG <NAME>_COMMIT=<sha>`; keep version ARGs and
  commits in sync.

## Testing Guidelines

There is no unit-test suite. Validation is build-time: the Dockerfile fails the
build if librga/MPP/FFmpeg artifacts are not AArch64 or RKMPP is missing from
the FFmpeg headers. End-to-end checks are the CI workflows and running the
produced binary on a Rockchip device.

## Commit & Pull Request Guidelines

- Git history is minimal (`Initial Debian 11 Rockchip cross builder`); write
  short imperative subjects that name the affected component, e.g.
  `Pin MPP to 1.1.0` or `Add librga deb packaging`.
- PRs should describe what changed and why, include build/CI results, and note
  any on-device verification. Update `README.md` when pinned versions, build
  flags, or usage change.

## Security & Configuration Tips

- Never execute ARM64 `postinst` scripts on the amd64 builder; sysroot packages
  must be extracted with `dpkg-deb --extract` only.
- Do not commit `dist/`, `build/`, or `.ccache/` contents.
- Keep pkg-config scoped to `/opt/sysroot` so host amd64 libraries are never
  linked into ARM64 artifacts.
