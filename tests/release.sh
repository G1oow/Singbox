#!/bin/bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for file in "$repo_dir/"*.sh "$repo_dir/src/"*.sh "$repo_dir/scripts/"*.sh "$repo_dir/tests/"*.sh; do
    # 按原始字节检查，避免 Windows grep 的文本模式自动忽略 CR。
    if LC_ALL=C od -An -t x1 "$file" | grep -w '0d' >/dev/null; then
        echo "失败：Shell 脚本包含 CRLF 或 CR 换行，Linux 无法可靠执行: $file"
        exit 1
    fi
done
test_dir=$(mktemp -d)
echo "发布测试临时目录: $test_dir"

is_sh_dir=$test_dir/sh
is_core=sing-box
is_core_name=sing-box
is_sh_repo=G1oow/Singbox
is_core_repo=SagerNet/sing-box
is_sh_bin=$test_dir/sing-box
is_sh_ver=v1.19
test_authenticated=1
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
    "auth status") [[ $test_authenticated == 1 ]] ;;
    "release view")
        [[ $fail_lookup == 0 ]] || return 1
        printf 'v1.19.99\n'
        ;;
    "release download")
        [[ $fail_download == 0 ]] || return 1
        while [[ $# -gt 0 ]]; do
            if [[ $1 == --dir ]]; then
                cp "$test_dir/code.tar.gz" "$test_dir/sha256sums.txt" "$2/"
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
    if [[ " $* " == *" -qO- "* ]]; then
        printf '{"tag_name":"v1.19.99"}\n'
        return
    fi
    local url
    while [[ $# -gt 0 ]]; do
        [[ $1 != https://* ]] || url=$1
        if [[ $1 == -O ]]; then
            cp "$test_dir/${url##*/}" "$2"
            return
        fi
        shift
    done
    return 1
}

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
grep -Fxq 'is_sh_ver=v1.19.99' "$is_sh_dir/sing-box.sh"
grep -q 'release download v1.19.99 --repo G1oow/Singbox --pattern code.tar.gz' "$test_dir/gh.log"
[[ ! -s $test_dir/wget.log ]]
echo "通过：私有 Release 使用 gh 下载，不回退到匿名下载"

test_authenticated=0
get_latest_version sh
[[ $latest_ver == v1.19.99 ]]
download sh "$latest_ver"
grep -q 'api.github.com/repos/G1oow/Singbox/releases/latest' "$test_dir/wget.log"
grep -q 'github.com/G1oow/Singbox/releases/download/v1.19.99/code.tar.gz' "$test_dir/wget.log"
echo "通过：公开 Release 使用 wget 下载"

test_authenticated=1
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

installed_hash=$(sha256sum "$is_sh_dir/sing-box.sh")
mv() {
    if [[ ${@: -2:1} == */source && ${@: -1} == "$is_sh_dir" ]]; then
        return 1
    fi
    command mv "$@"
}
if download sh v1.19.99 >/dev/null 2>&1; then echo "脚本替换失败仍报告成功"; exit 1; fi
unset -f mv
[[ $(sha256sum "$is_sh_dir/sing-box.sh") == "$installed_hash" ]]
[[ ! -d $is_sh_dir.update.lock ]]
echo "通过：脚本替换失败恢复原目录并释放锁"

# 摘要损坏时不能覆盖已安装脚本。
printf '%064d  code.tar.gz\n' 0 >"$test_dir/sha256sums.txt"
if download sh v1.19.99 >/dev/null 2>&1; then echo "未拒绝摘要错误的脚本"; exit 1; fi
[[ $(sha256sum "$is_sh_dir/sing-box.sh") == "$installed_hash" ]]
[[ ! -d $is_sh_dir.update.lock ]]
echo "通过：脚本摘要失败保持原安装并释放更新锁"

bash "$repo_dir/tests/update.sh"
bash "$repo_dir/tests/cli.sh"
bash "$repo_dir/tests/bootstrap.sh"
bash "$repo_dir/tests/installer.sh"
echo "全部发布测试通过"
