# rk-builder deb 打包公共函数库。
#
# 用法: 在打包脚本开头 source 本文件,然后按顺序调用:
#   deb_common_init                          初始化 WORK_DIR/trap/路径变量
#   deb_fetch_source <repo> <commit> <dest>  浅克隆源码并校验 commit
#   deb_render_control <tpl> <root> <ver> [kv...]  从 control.in 生成 DEBIAN/control
#   deb_finish_package <root> <out> <name> <ver>  打 deb + sha256
#
# 各脚本只需保留自己特有的部分:如何编译/收集产物、如何生成 pkg-config。

# 防止被直接执行
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "lib-deb-common.sh 是函数库,请用 source 引入" >&2
    exit 1
fi

# deb_common_init
#
# 设置所有打包脚本共用的基础变量:
#   BUILDER_DIR  仓库根目录(默认按脚本在 scripts/ 下的布局推导,
#                 在容器里被 COPY 到 /usr/local/bin/ 时由 PACKAGING_DIR
#                 等显式传入,BUILDER_DIR 本身不参与包内容组织)
#   WORK_DIR     临时工作目录(脚本退出时自动清理)
#   OUT_DIR      deb 输出目录(默认 $BUILDER_DIR/dist,可用环境变量覆盖)
#
# 调用前脚本需先 set -euo pipefail。
deb_common_init()
{
    local i
    for i in "${!BASH_SOURCE[@]}"; do
        if [[ ${BASH_SOURCE[$i]} != "${BASH_SOURCE[0]}" ]]; then
            SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[$i]}")" && pwd)
            break
        fi
    done
    BUILDER_DIR=${BUILDER_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}
    OUT_DIR=${OUT_DIR:-"$BUILDER_DIR/dist"}

    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT

    mkdir -p "$OUT_DIR"
}

# deb_fetch_source <repository> <commit> <dest_dir>
#
# 浅克隆指定 commit 的源码并校验 HEAD 是否匹配,保证构建可复现。
# 同时设置并导出 SOURCE_DATE_EPOCH 为该 commit 的时间戳,
# 使 deb 包内容可复现(配合 deb_finish_package 里的 touch)。
#
# 参数:
#   repository  git 仓库地址
#   commit      期望的 commit SHA
#   dest_dir    克隆目标目录(函数内创建)
deb_fetch_source()
{
    local repository=$1
    local commit=$2
    local dest_dir=$3

    git init --quiet "$dest_dir"
    git -C "$dest_dir" remote add origin "$repository"
    git -C "$dest_dir" fetch --quiet --depth 1 origin "$commit"
    git -C "$dest_dir" checkout --quiet --detach FETCH_HEAD

    if [[ $(git -C "$dest_dir" rev-parse HEAD) != "$commit" ]]; then
        echo "commit verification failed for $repository" >&2
        return 1
    fi

    SOURCE_DATE_EPOCH=$(git -C "$dest_dir" show -s --format=%ct HEAD)
    export SOURCE_DATE_EPOCH
}

# deb_render_control <template> <package_root> <version> [KEY=VALUE ...]
#
# 从 control.in 模板生成 DEBIAN/control:
#   - @VERSION@ 始终替换为 <version>
#   - 额外的 KEY=VALUE 参数把模板里的 @KEY@ 替换为 VALUE,
#     用于一个模板产出多个 control(如运行包/dev包 共用模板)。
#
# 参数:
#   template      control.in 模板路径
#   package_root  deb 包根目录(函数内创建 DEBIAN/ 子目录)
#   version       版本号字符串
#   KEY=VALUE     额外的占位符替换对,可多个
deb_render_control()
{
    local template=$1
    local package_root=$2
    local version=$3
    shift 3

    local sed_args=(-e "s/@VERSION@/$version/g")
    local kv
    for kv in "$@"; do
        sed_args+=(-e "s|@${kv%%=*}@|${kv#*=}|g")
    done

    mkdir -p "$package_root/DEBIAN"
    sed "${sed_args[@]}" "$template" > "$package_root/DEBIAN/control"
}

# deb_finish_package <package_root> <out_dir> <name> <version>
#
# 打包收尾:
#   1. 用 SOURCE_DATE_EPOCH 统一包内所有文件的时间戳(可复现构建)
#   2. dpkg-deb 生成 <name>_<version>_arm64.deb
#   3. 生成同名 .sha256 校验文件
#
# 参数:
#   package_root  deb 包根目录(须已包含 DEBIAN/control 和全部文件)
#   out_dir       输出目录
#   name          deb 包名(如 rockchip-mpp-dev)
#   version       版本号(如 1.1.0)
deb_finish_package()
{
    local package_root=$1
    local out_dir=$2
    local name=$3
    local version=$4

    local package_file="$out_dir/${name}_${version}_arm64.deb"

    # 脚本可能跳过 deb_fetch_source(如 BUILD_INPUT 复用已有产物),
    # 此时用当前时间兜底,保证 deb_finish_package 可用。
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}

    find "$package_root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

    # 强制用 xz 压缩,不用 zst。
    # Debian 11 bullseye 的 dpkg-deb 不支持 zst,而解包进 sysroot
    # 用的正是 bullseye 里的 dpkg-deb。
    dpkg-deb --root-owner-group -Zxz --build "$package_root" "$package_file"

    (
        cd "$out_dir"
        sha256sum "$(basename "$package_file")" > "$(basename "$package_file").sha256"
    )

    echo "Created $package_file"
}
