#!/bin/bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -f -- "$test_dir/gh.log" "$test_dir/wget.log" "$test_dir/code.tar.gz" "$test_dir/sha256sums.txt"; rmdir -- "$test_dir"' EXIT

is_sh_dir=$repo_dir
is_core=sing-box
is_core_name=sing-box
is_sh_repo=G1oow/Singbox
is_core_repo=SagerNet/sing-box
is_sh_bin=$test_dir/sing-box
is_sh_ver=v1.19
authenticated=1
fail_lookup=0
fail_download=0
load() { . "$repo_dir/src/$1"; }
err() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
load core.sh
load download.sh

# 模拟 GitHub 网络边界；不会访问本机凭证或真实安装目录。
gh() {
    printf '%s\n' "$*" >>"$test_dir/gh.log"
    case "$1 $2" in
    "auth status") [[ $authenticated == 1 ]] ;;
    "release view")
        [[ $fail_lookup == 0 ]] || return 1
        printf 'v1.19.99\n'
        ;;
    "release download")
        [[ $fail_download == 0 ]] || return 1
        while [[ $# -gt 0 ]]; do
            if [[ $1 == --output ]]; then
                cp "$test_dir/code.tar.gz" "$2"
                return
            fi
            shift
        done
        return 1
        ;;
    *) return 1 ;;
    esac
}

_wget() {
    printf '%s\n' "$*" >>"$test_dir/wget.log"
    if [[ $1 == -qO- ]]; then
        printf '{"tag_name":"v1.19.99"}\n'
        return
    fi
    while [[ $# -gt 0 ]]; do
        if [[ $1 == -O ]]; then
            cp "$test_dir/code.tar.gz" "$2"
            return
        fi
        shift
    done
    return 1
}

# 检查和读取真实 tar 包，但不安装到 /etc 或修改可执行文件。
tar() {
    if [[ $1 == zxf ]]; then
        printf 'extract %s\n' "$*" >>"$test_dir/gh.log"
    else
        command tar "$@"
    fi
}
chmod() { return 0; }

for file in install.sh src/init.sh; do
    grep -Fxq 'is_sh_repo=G1oow/Singbox' "$repo_dir/$file"
done
echo "通过：安装和更新使用同一发布仓库"

bash "$repo_dir/scripts/package.sh" v1.19.99 "$test_dir"
command tar -xOf "$test_dir/code.tar.gz" sing-box.sh | grep -Fx 'is_sh_ver=v1.19.99' >/dev/null
command tar -tzf "$test_dir/code.tar.gz" | grep -Fx 'src/egress.sh' >/dev/null
command tar -tzf "$test_dir/code.tar.gz" | grep -Fx 'docs/release.md' >/dev/null
if command tar -tzf "$test_dir/code.tar.gz" | grep -E '^(\.git|tests/|scripts/|.*\.env)' >/dev/null; then
    echo "发布包包含非运行文件"
    exit 1
fi
first_hash=$(sha256sum "$test_dir/code.tar.gz")
bash "$repo_dir/scripts/package.sh" v1.19.99 "$test_dir"
[[ $(sha256sum "$test_dir/code.tar.gz") == "$first_hash" ]]
(cd "$test_dir" && sha256sum -c sha256sums.txt)
echo "通过：版本写入、包白名单、校验和与可重复构建"

get_latest_version sh
[[ $latest_ver == v1.19.99 ]]
download sh "$latest_ver"
grep -q 'release download v1.19.99 --repo G1oow/Singbox --pattern code.tar.gz' "$test_dir/gh.log"
[[ ! -s $test_dir/wget.log ]]
echo "通过：私有 Release 使用 gh 下载，不回退到匿名下载"

authenticated=0
get_latest_version sh
[[ $latest_ver == v1.19.99 ]]
download sh "$latest_ver"
grep -q 'api.github.com/repos/G1oow/Singbox/releases/latest' "$test_dir/wget.log"
grep -q 'github.com/G1oow/Singbox/releases/download/v1.19.99/code.tar.gz' "$test_dir/wget.log"
echo "通过：公开 Release 使用 wget 下载"

authenticated=1
fail_lookup=1
if main update sh >/dev/null 2>&1; then echo "查询失败仍报告更新成功"; exit 1; fi
fail_lookup=0
fail_download=1
before=$(wc -l <"$test_dir/wget.log")
if download sh v1.19.99 >/dev/null 2>&1; then echo "未处理认证下载失败"; exit 1; fi
[[ $(wc -l <"$test_dir/wget.log") == "$before" ]]
fail_download=0
if download sh v1.19.98 >/dev/null 2>&1; then echo "未拒绝版本不一致的发布包"; exit 1; fi
echo "通过：查询失败、下载失败和版本不一致均停止更新"

# 只加载独立下载函数，不执行安装器的 root 检查或主流程。
source <(sed -n '/^download() {$/,/^}$/p' "$repo_dir/install.sh")
tmpsh=$test_dir/sh.tmp
is_sh_ok=$test_dir/code.tar.gz
download sh >/dev/null
grep -q 'release download --repo G1oow/Singbox --pattern code.tar.gz' "$test_dir/gh.log"
authenticated=0
download sh >/dev/null
grep -q 'github.com/G1oow/Singbox/releases/latest/download/code.tar.gz' "$test_dir/wget.log"
echo "通过：安装器兼容私有和公开 Release"
echo "全部发布测试通过"
