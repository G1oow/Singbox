#!/bin/bash

# 独立引导入口：不通过管道执行下载内容，先校验完整发布包再运行安装器。
bootstrap_main() (
    set -euo pipefail
    local repo=G1oow/Singbox version= authenticated= workdir= temp_root
    local base metadata digest file expected= actual entry listing
    local install_args=()
    while (($#)); do
        case $1 in
        --release)
            [[ $# -ge 2 ]] || { echo "--release 缺少版本号" >&2; exit 1; }
            version=$2; shift 2
            ;;
        -h | --help)
            echo "用法: bash get.sh [--release v1.19.99] [安装器参数]"
            echo "安装器参数: --core-version <版本>、--core-file <路径>、--proxy <地址>"
            echo "仅在准备安装的新 VPS 上以 root 运行；已有安装请用 sb U 更新脚本。"
            return 0
            ;;
        *) install_args+=("$1"); shift ;;
        esac
    done
    [[ ! $version || $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] ||
        { echo "Release 版本格式无效" >&2; exit 1; }
    for file in bash tar gzip sha256sum mktemp; do
        command -v "$file" >/dev/null || { echo "请先安装 $file" >&2; exit 1; }
    done
    if command -v gh >/dev/null && GH_HOST=github.com gh auth status --hostname github.com &>/dev/null; then
        authenticated=1
    else
        command -v curl >/dev/null || { echo "请先安装 curl，或使用已认证的 GitHub CLI" >&2; exit 1; }
    fi
    temp_root=$(cd -- "${TMPDIR:-/tmp}" && pwd -P) || exit 1
    workdir=$(mktemp -d "$temp_root/singbox-bootstrap.XXXXXX") || exit 1
    cleanup_bootstrap() {
        local result=$?
        [[ $workdir == "$temp_root"/singbox-bootstrap.* && -d $workdir && ! -L $workdir ]] &&
            rm -rf -- "$workdir"
        return "$result"
    }
    trap cleanup_bootstrap EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ ! $version ]]; then
        if [[ $authenticated ]]; then
            version=$(GH_HOST=github.com gh release view --repo "$repo" --json tagName --jq .tagName) || exit 1
        else
            metadata=$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
                "https://api.github.com/repos/$repo/releases/latest") || exit 1
            version=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<<"$metadata")
        fi
    fi
    [[ $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] ||
        { echo "无法获取稳定版，请检查网络及仓库访问权限" >&2; exit 1; }
    echo "下载并校验脚本 $version ..."
    if [[ $authenticated ]]; then
        GH_HOST=github.com gh release download "$version" --repo "$repo" \
            --pattern code.tar.gz --pattern sha256sums.txt --dir "$workdir" || exit 1
    else
        base=https://github.com/$repo/releases/download/$version
        for file in code.tar.gz sha256sums.txt; do
            curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$base/$file" -o "$workdir/$file" || exit 1
        done
    fi
    # 不让清单中的其他路径参与校验。
    while read -r digest file; do
        [[ ${file#\*} == code.tar.gz ]] || continue
        [[ ! $expected && $digest =~ ^[[:xdigit:]]{64}$ ]] ||
            { echo "SHA256 清单无效" >&2; exit 1; }
        expected=${digest,,}
    done <"$workdir/sha256sums.txt"
    actual=$(sha256sum "$workdir/code.tar.gz") || exit 1
    [[ $expected && ${actual%% *} == "$expected" ]] ||
        { echo "SHA256 校验失败，安装已中止" >&2; exit 1; }
    listing=$(tar -tzf "$workdir/code.tar.gz") || exit 1
    while IFS= read -r entry; do
        case $entry in
        /* | .. | ../* | */../* | */..) echo "发布包包含不安全路径" >&2; exit 1 ;;
        esac
    done <<<"$listing"
    listing=$(LC_ALL=C tar -tvzf "$workdir/code.tar.gz") || exit 1
    while IFS= read -r entry; do
        [[ $entry == [-d]* ]] || { echo "发布包包含不支持的文件类型" >&2; exit 1; }
    done <<<"$listing"
    mkdir "$workdir/source" || exit 1
    tar -xzf "$workdir/code.tar.gz" --no-same-owner --no-same-permissions -C "$workdir/source" || exit 1
    cd "$workdir/source" || exit 1
    [[ -f install.sh && -f src/core.sh ]] || { echo "发布包不完整" >&2; exit 1; }
    grep -Fxq "is_sh_ver=$version" sing-box.sh ||
        { echo "发布包版本与 Release 不一致" >&2; exit 1; }
    bash -n install.sh || exit 1
    bash install.sh --local-install "${install_args[@]}"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    bootstrap_main "$@"
fi
