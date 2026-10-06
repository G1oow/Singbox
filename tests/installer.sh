#!/bin/bash
set -eo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
echo "安装器测试临时目录: $test_dir"
mkdir "$test_dir/assets"
bash "$repo_dir/scripts/package.sh" v1.19.99 "$test_dir/assets" >/dev/null

# 只加载安装器的下载、参数和清理接口，不执行 root 检查、依赖安装或系统写入。
for function_name in _wget install_verify install_unpack download pass_args exit_and_del_tmpdir; do
    source <(sed -n "/^${function_name}() {$/,/^}$/p" "$repo_dir/install.sh")
done
err() { printf '%s\n' "$*" >&2; exit 1; }
msg() { printf '%s\n' "$*" >&2; }
wget() { printf '<%s>\n' "$@" >"$test_dir/wget-args"; }
_wget -q 'https://example.org/a path' -O '/tmp/a file'
if grep -q -- '--no-check-certificate' "$test_dir/wget-args"; then echo "安装器关闭了证书校验"; exit 1; fi
grep -Fxq '<https://example.org/a path>' "$test_dir/wget-args"
echo "通过：安装下载保留 HTTPS 证书校验与参数边界"

is_core=sing-box
is_core_name=sing-box
is_core_repo=SagerNet/sing-box
is_sh_repo=G1oow/Singbox
is_arch=amd64
test_authenticated=0
fail_download=0
_wget() {
    local url output
    while (($#)); do
        case $1 in
        -O) output=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
        esac
    done
    printf '%s\n' "$url" >>"$test_dir/network.log"
    [[ $fail_download == 0 ]] || return 1
    if [[ $url == */latest ]]; then
        printf '{"tag_name":"v1.19.99"}\n'
    else
        cp "$test_dir/assets/${url##*/}" "$output"
    fi
}
gh() {
    case "$1 $2" in
    "auth status") [[ $test_authenticated == 1 ]] ;;
    "release view") echo v1.19.99 ;;
    "release download")
        printf '%s\n' "$*" >>"$test_dir/network.log"
        [[ $fail_download == 0 ]] || return 1
        while (($#)); do
            if [[ $1 == --dir ]]; then
                cp "$test_dir/assets/code.tar.gz" "$test_dir/assets/sha256sums.txt" "$2/"
                return
            fi
            shift
        done
        return 1
        ;;
    *) return 1 ;;
    esac
}
run_download() (
    set +e
    tmpdir=$test_dir/$1
    mkdir "$tmpdir" || exit 1
    tmpcore=$tmpdir/core.tmp
    tmpjq=$tmpdir/jq.tmp
    is_sh_ok=$tmpdir/sh.ok
    is_jq_ok=$tmpdir/jq.ok
    download "${2:-sh}"
)
run_download public
[[ -f $test_dir/public/sh.ok ]]
grep -q '/download/v1.19.99/sha256sums.txt' "$test_dir/network.log"
test_authenticated=1
run_download private
[[ -f $test_dir/private/sh.ok ]]
grep -q 'release download v1.19.99 ' "$test_dir/network.log"
printf '%064d  code.tar.gz\n' 0 >"$test_dir/assets/sha256sums.txt"
if run_download bad-hash >/dev/null 2>&1; then echo "脚本摘要失败仍标记成功"; exit 1; fi
[[ ! -f $test_dir/bad-hash/sh.ok ]]
fail_download=1
if run_download bad-download >/dev/null 2>&1; then echo "下载失败仍标记成功"; exit 1; fi
fail_download=0
echo "通过：公开及私有安装锁定 Release，下载和摘要失败均不标记成功"

printf '#!/bin/bash\necho jq-1.7.1\n' >"$test_dir/assets/jq-linux-amd64"
(cd "$test_dir/assets"; sha256sum jq-linux-amd64 >sha256sum.txt)
run_download jq-good jq
[[ -f $test_dir/jq-good/jq.ok ]]
printf 'tampered\n' >>"$test_dir/assets/jq-linux-amd64"
if run_download jq-bad jq >/dev/null 2>&1; then echo "未校验 jq 便携版"; exit 1; fi
[[ ! -f $test_dir/jq-bad/jq.ok ]]
echo "通过：jq 执行前校验官方摘要"

touch "$test_dir/core archive.tar.gz"
(
    set +e
    pass_args --core-file "$test_dir/core archive.tar.gz"
    [[ $is_core_file == "$test_dir/core archive.tar.gz" ]]
)
if (pass_args --core-version v1.2/bad) >/dev/null 2>&1; then exit 1; fi
(exit_and_del_tmpdir ok)
echo "通过：安装参数保留空格，拒绝无效版本，安装成功返回零"
