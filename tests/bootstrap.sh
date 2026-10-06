#!/bin/bash
set -eo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
echo "引导安装测试临时目录: $test_dir"
mkdir -p "$test_dir/source/src" "$test_dir/assets" "$test_dir/work"
export BOOTSTRAP_RESULT_FILE=$test_dir/result
export TMPDIR=$test_dir/work
cat >"$test_dir/source/install.sh" <<'SH'
#!/bin/bash
printf '<%s>\n' "$@" >"$BOOTSTRAP_RESULT_FILE"
exit "${INSTALL_RESULT:-0}"
SH
printf 'is_sh_ver=v1.19.99\n' >"$test_dir/source/sing-box.sh"
printf ':\n' >"$test_dir/source/src/core.sh"
tar -czf "$test_dir/assets/code.tar.gz" -C "$test_dir/source" install.sh sing-box.sh src
(cd "$test_dir/assets"; sha256sum code.tar.gz >sha256sums.txt)
test_authenticated=0
fail_download=0
curl() {
    local url output
    while (($#)); do
        case $1 in
        -o | --output) output=$2; shift 2 ;;
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
            if [[ $1 == --dir ]]; then cp "$test_dir/assets/"* "$2/"; return; fi
            shift
        done
        return 1
        ;;
    *) return 1 ;;
    esac
}
source "$repo_dir/get.sh"
run_bootstrap() (set +e; bootstrap_main "$@")
run_bootstrap --core-file '/tmp/core archive.tar.gz'
[[ $(cat "$BOOTSTRAP_RESULT_FILE") == "$(printf '<%s>\n' --local-install --core-file '/tmp/core archive.tar.gz')" ]]
grep -q '/download/v1.19.99/code.tar.gz' "$test_dir/network.log"
grep -q '/download/v1.19.99/sha256sums.txt' "$test_dir/network.log"
echo "通过：公开安装锁定同一 Release，校验后安装且原样传递参数"
test_authenticated=1
run_bootstrap --release v1.19.99
grep -q 'release download v1.19.99 ' "$test_dir/network.log"
echo "通过：私有仓库使用 gh 认证下载"
rm -f "$BOOTSTRAP_RESULT_FILE"
fail_download=1
if run_bootstrap >/dev/null 2>&1; then echo "下载失败仍继续"; exit 1; fi
fail_download=0
printf '%064d  code.tar.gz\n' 0 >"$test_dir/assets/sha256sums.txt"
if run_bootstrap >/dev/null 2>&1; then echo "摘要失败仍继续"; exit 1; fi
[[ ! -e $BOOTSTRAP_RESULT_FILE ]]
if compgen -G "$test_dir/work/singbox-bootstrap.*" >/dev/null; then echo "引导临时目录未清理"; exit 1; fi
echo "通过：下载和摘要失败不执行安装，临时目录已清理"

(cd "$test_dir/assets"; sha256sum code.tar.gz >sha256sums.txt)
export INSTALL_RESULT=7
if run_bootstrap >/dev/null 2>&1; then echo "安装器失败仍返回成功"; exit 1; fi
unset INSTALL_RESULT
[[ -f $BOOTSTRAP_RESULT_FILE ]]
rm -f "$BOOTSTRAP_RESULT_FILE"
printf 'broken archive\n' >"$test_dir/assets/code.tar.gz"
(cd "$test_dir/assets"; sha256sum code.tar.gz >sha256sums.txt)
if run_bootstrap >/dev/null 2>&1; then echo "损坏的包仍被执行"; exit 1; fi
[[ ! -e $BOOTSTRAP_RESULT_FILE ]]
if compgen -G "$test_dir/work/singbox-bootstrap.*" >/dev/null; then exit 1; fi
echo "通过：解压失败不执行安装，安装器的失败状态向外传递"

tar -czf "$test_dir/assets/code.tar.gz" --transform='s|^install.sh$|../install.sh|' \
    -C "$test_dir/source" install.sh sing-box.sh src
(cd "$test_dir/assets"; sha256sum code.tar.gz >sha256sums.txt)
if run_bootstrap >/dev/null 2>&1; then echo "未拒绝目录穿越归档"; exit 1; fi
[[ ! -e $BOOTSTRAP_RESULT_FILE ]]
if ln -s "$test_dir/source/install.sh" "$test_dir/source/link" 2>/dev/null &&
    [[ -L $test_dir/source/link ]]; then
    tar -czf "$test_dir/assets/code.tar.gz" -C "$test_dir/source" install.sh sing-box.sh src link
    (cd "$test_dir/assets"; sha256sum code.tar.gz >sha256sums.txt)
    if run_bootstrap >/dev/null 2>&1; then echo "未拒绝链接归档"; exit 1; fi
    [[ ! -e $BOOTSTRAP_RESULT_FILE ]]
    echo "通过：拒绝符号链接归档"
else
    echo "跳过：当前文件系统不支持符号链接；Linux CI 将验证此场景"
fi
echo "通过：拒绝目录穿越，不执行不安全的发布包"
