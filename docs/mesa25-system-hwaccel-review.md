# Mesa 25 系统级硬件加速改动 Code Review 报告

- 审查范围：`git status` 中未提交的改动（README.md、`mesa/mesa25-run`、
  `scripts/build-mesa-deb.sh` 修改；`mesa/01-xorg-glamor.conf`、
  `mesa/20-modesetting.conf`、`mesa/lightdm-xserver.conf`、`mesa/lightdm.conf`、
  `mesa/mesa25-xorg`、`mesa/postinst`、`mesa/postrm` 新增）
- 审查日期：2026-08-27
- 结论：**整体方向正确，可以合入**；存在 1 个必须确认/修复的问题（P1），
  以及若干建议项（P2/P3）。

## 1. 改动意图与总体评价

目标：让 `mesa25-ans` 运行包不仅提供 `/usr/local/ans` 下的 Mesa 25
Panfrost/Panthor 栈，还通过打包进 deb 的 Xorg/LightDM 配置，把整个系统
（桌面会话及其他组件）切换到 Mesa 硬件加速，替换 RK3588 BSP 的专有
G52/G610 libmali 栈。

实现链路清晰、自洽：

1. `50_mesa.json` 改为绝对路径（build-mesa-deb.sh 中 `sed` 替换 +
   `grep` 自检），绕开 BSP loader 的 ld.so 搜索顺序干扰；
2. `mesa25-run` 增加 `__GLX_VENDOR_LIBRARY_NAME=mesa`，补上 GLX 侧的选择；
3. `mesa25-xorg` 包装器在 exec `/usr/bin/X` 前显式导出 EGL/GLX/DRI/GBM 四组
   路径（LightDM 会清洗子进程环境，放在包装器里设置是正确做法）；
4. LightDM 通过 `lightdm.conf.d/90-mesa25-ans.conf` 改用 `mesa25-xorg`
   启动 Xorg，同时 systemd drop-in 也给整个 lightdm 服务补了环境；
5. `20-modesetting.conf` 用 Debian 的 modesetting+glamor+DRI3 替换 BSP
   的 FlipFB 驱动；`01-xorg-glamor.conf` 用 driconf 的
   `force_glsl_version=130` 绕过 Debian 11 Xorg 1.20.11 glamor 无
   `#version` 着色器被 Mesa 25 按 GLSL 1.10 解析导致 Xorg 崩溃的问题；
6. `postinst/postrm` 用 `dpkg-divert` 停用 BSP 的
   `00-aarch64-mali.conf`（保留 libmali 包满足依赖），并做
   `ldconfig`/`systemctl daemon-reload`。

命名规范、deb 打包结构、错误处理（`set -e`、divert 幂等、被其他包占用
divert 时报错退出）均符合仓库既有风格。shell 语法检查（`bash -n` /
`sh -n`）全部通过。

## 2. 问题列表

### P1（已修复）：`mesa25-xorg` 在 git 中权限为 0644

`stat` 显示 `mesa/mesa25-xorg` 为 `644`，而其余脚本（`mesa25-run`）为
`755`。打包侧用 `install -Dm 0755` 安装，所以构建出的 deb 内权限正确，
但仓库内文件权限不一致有隐患。

处置：已 `chmod 755 mesa/mesa25-xorg`，提交时确认 git 记录 `100755`。

### P2（已修复）：环境变量重复维护三份，存在漂移风险

同一组 4 个环境变量原先出现在 `mesa25-run`、`mesa25-xorg` 和
`lightdm.conf` 三处，且 `mesa25-run` 的 `LIBGL_DRIVERS_PATH` 缺少
`:/usr/lib/aarch64-linux-gnu/dri` 回退路径。

处置：

- `mesa25-run` 的 `LIBGL_DRIVERS_PATH` 已补上系统 dri 回退路径；
- `mesa25-xorg` 改为 `exec /usr/local/ans/bin/mesa25-run /usr/bin/X ...`，
  完全复用 `mesa25-run` 的环境设置（含 LD_LIBRARY_PATH 保护），不再
  自行导出变量；
- `lightdm.conf`（systemd drop-in）补注释说明与 `mesa25-run` 保持同步
  —— 该文件面向 LightDM 启动的非 Xorg 进程（greeter、session helper），
  不能删除。

### P2（不处理）：Xorg 版本约束可考虑用最新安全版本

`DEPENDS` 中 `xserver-common/xserver-xorg-core (>=
2:1.20.11-1+deb11u17)`。经核实 bullseye-security 当前已是
`2:1.20.11-1+deb11u18`（2026-08-13 发布）。`>=` 约束仍然正确、可解析。

处置：经确认保持现状，不提升下限。

### P3（已补充 README）：Xorg 配置为排他性整体替换

`mesa25-xorg` 使用 `-config <file>`（而非仅 `-configdir`），这会**替换**
Xorg 的全部主配置，包括目标 BSP 镜像 `/etc/X11/xorg.conf` 中可能存在的
键盘/输入设备等定制段。

处置：README "在 RK3588 设备上启用 Mesa 硬件加速" 一节已补充注意事项，
说明 `-config` 替换语义、libinput 自动探测以及定制输入配置的迁移路径
（`/usr/local/ans/share/rk-builder/xorg.conf.d/`）。

### P3（已补充 README）：未安装 lightdm 的最小系统

deb 会无条件安装 `/etc/lightdm/lightdm.conf.d/90-mesa25-ans.conf` 和
`lightdm.service.d/mesa25-ans.conf`。对无桌面的服务器镜像这些文件无害，
`Depends` 未包含 `lightdm` 是合理选择（不强制拉桌面）。

处置：README 已注明该方案假定 LightDM，最小系统可改用 `mesa25-run`
启动应用程序。

### P3（已补充 README）：README 验证命令

`DISPLAY=:0 XAUTHORITY=/home/ans/.Xauthority glxinfo -B` 假定用户名为
`ans` 且 Xorg 跑在 `:0`。

处置：README 已注明按实际用户/显示号调整。

## 3. 逐项核对记录

| 检查项 | 结果 |
| --- | --- |
| `mesa25-run` / `mesa25-xorg` / `postinst` / `postrm` / `build-mesa-deb.sh` 语法（`sh -n` / `bash -n`） | 通过 |
| `50_mesa.json` 绝对路径替换 + `grep -q` 自检（替换失败即构建失败） | 正确 |
| postinst divert 幂等、其他包占用 divert 时显式失败 | 正确 |
| postrm 仅处理 `remove|purge`，且只移除本包的 divert | 正确 |
| deb 内 postinst/postrm 权限（`install -m 0755`） | 正确 |
| `deb_add_runtime_paths` 替换为手写 ld.so.conf + 自定义脚本 | 等价，且 ld.so.conf 文件名保持一致（`00-ans-mesa25-ans.conf`） |
| xserver 版本号 `2:1.20.11-1+deb11u17` 在 bullseye 存在 | 属实（当前最新 u18） |
| 新增 `libegl1/libgles2/libgl1/libudev1` 依赖与启用功能（EGL/GLES2/GLX/GBM）匹配 | 正确 |
| README 新增部署/验证章节与实现一致（dpkg-divert、mesa25-xorg、预期 Panfrost 输出） | 一致 |
| 工作流/Dockerfile 无需改动（`COPY mesa/ ...` 全目录拷贝，自动包含新文件） | 确认 |

## 4. 提交前待办

1. ~~`chmod 755 mesa/mesa25-xorg` 并确认 git 记录 100755（P1）~~ 已完成。
2. ~~对齐三处环境变量、`mesa25-xorg` 复用 `mesa25-run`（P2）~~ 已完成。
3. ~~xserver 依赖下限提升到 `deb11u18`（P2）~~ 决定不处理。
4. ~~README 补充 P3 注意事项~~ 已完成。
5. 在 RK3588 设备上实测：安装 deb → `systemctl restart lightdm` →
   核对 `glxinfo -B` 显示 `Mali-G610 (Panfrost)` / `Accelerated: yes`，
   以及 `Xorg.0.log` 中 `glamor X acceleration enabled`。
