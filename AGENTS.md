# Repository Guidelines

## Project Structure & Module Organization

`rk-builder` is a Docker-based x86_64 → ARM64 cross-compile environment for
Rockchip Debian 11 devices (default target: RK3588).

- `Dockerfile`: multi-stage build — librga deb packaging, arm64 sysroot
  assembly, Rockchip MPP and ffmpeg-rockchip cross-compiles, final image.
- `build.sh`: main entry point; builds a CMake project inside the container.
- `scripts/`: `entrypoint.sh` (container entrypoint `rk-cross-build`) and
  `build-librga-deb.sh` (standalone librga ARM64 deb packaging).
- `cmake/aarch64-linux-gnu.cmake`: CMake toolchain file (compiler, sysroot,
  find rules).
- `librga/`: deb packaging templates (`control.in`, `librga.pc.in`).
- `.github/workflows/`: `image.yml` (image CI), `librga-release.yml` (deb
  release on `librga-v*` tags).
- `build/`, `.ccache/`, `dist/`: generated artifacts; never commit these.

## Build, Test, and Development Commands

- `./build.sh` — build the parent CMake project (Release) using the local
  image, building the image first if missing.
- `./build.sh -d` — Debug build; output in `build/debug/`.
- `PROJECT_DIR=/path/to/project ./build.sh --rebuild-image` — force an image
  rebuild and compile a different CMake tree.
- `./build.sh -- -DFOO=ON` — pass extra CMake arguments.
- `RK_BUILDER_IMAGE=ghcr.io/whoarei/rk-builder:latest ./build.sh --pull-image`
  — use the prebuilt GHCR image.
- `./scripts/build-librga-deb.sh` — produce `dist/librga-dev_1.10.6_arm64.deb`
  plus its SHA-256 file.
- `docker build -t rk-builder:debian11-arm64 .` — build the image directly.

Cross-compiled binaries cannot run on the x86_64 host; verify them on a target
device (see the "部署验证" section of `README.md`).

## Coding Style & Naming Conventions

- Shell scripts: bash with `set -euo pipefail`, 4-space indentation, function
  names in `snake_case`, environment overrides in `UPPER_CASE` (e.g.
  `PROJECT_DIR`, `RK_BUILDER_IMAGE`).
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
