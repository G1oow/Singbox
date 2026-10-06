#!/bin/bash
set -eo pipefail
if [[ ${JQ_BIN:-} ]]; then
    jq() { "$JQ_BIN" -b "$@"; }
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
echo "更新测试临时目录: $test_dir"
mkdir -p "$test_dir/bin" "$test_dir/assets/core" "$test_dir/conf"
is_core=sing-box
is_core_name=sing-box
is_core_repo=SagerNet/sing-box
is_core_dir=$test_dir
is_core_bin=$test_dir/bin/sing-box
is_config_json=$test_dir/config.json
is_conf_dir=$test_dir/conf
is_sh_repo=G1oow/Singbox
is_sh_dir=$test_dir/sh
is_sh_bin=$test_dir/sing-box
is_arch=amd64
is_systemd=1
is_openrc=
load() { . "$repo_dir/src/$1"; }
err() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
sleep() { return 0; }
gh() { return 1; }
load download.sh

_wget() {
    local url output
    while (($#)); do
        case $1 in
        -O) output=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
        esac
    done
    if [[ $url == */releases/tags/* ]]; then
        cp "$test_dir/assets/core.json" "$output"
    else
        cp "$test_dir/assets/${url##*/}" "$output"
    fi
}
systemctl() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    if [[ ${interrupt_restart:-0} == 1 && $1 == restart &&
          $(grep -c '^restart ' "$test_dir/service.log") == 1 ]]; then
        kill -TERM "$BASHPID"
    fi
    [[ ${fail_restart:-0} != 1 || $1 != restart ||
       $(grep -c '^restart ' "$test_dir/service.log") != 1 ]]
}
fixture_core() {
    printf '#!/bin/bash\nprintf "sing-box version 1.12.12\\n"\n' >"$is_core_bin"
    chmod +x "$is_core_bin"
    printf '#!/bin/bash\nif [[ $1 == version ]]; then echo "sing-box version 1.13.14"; else exit "${FAIL_CHECK:-0}"; fi\n' \
        >"$test_dir/assets/core/sing-box"
    chmod +x "$test_dir/assets/core/sing-box"
    tar -czf "$test_dir/assets/sing-box-1.13.14-linux-amd64.tar.gz" -C "$test_dir/assets" core
    core_metadata
    : >"$test_dir/service.log"
}
core_metadata() {
    local checksum
    checksum=$(sha256sum "$test_dir/assets/sing-box-1.13.14-linux-amd64.tar.gz")
    printf '{"tag_name":"v1.13.14","assets":[{"name":"sing-box-1.13.14-linux-amd64.tar.gz","digest":"sha256:%s"}]}\n' \
        "${checksum%% *}" >"$test_dir/assets/core.json"
}
run_download() (set +e; download "$@")

fixture_core
before=$(sha256sum "$is_core_bin")
printf 'broken archive\n' >"$test_dir/assets/sing-box-1.13.14-linux-amd64.tar.gz"
core_metadata
if run_download core v1.13.14 >/dev/null 2>&1; then
    echo "失败：损坏的内核包仍报告更新成功"
    exit 1
fi
[[ $(sha256sum "$is_core_bin") == "$before" ]]
echo "通过：损坏的内核包返回失败并保留旧内核"

fixture_core
printf 'tampered\n' >>"$test_dir/assets/sing-box-1.13.14-linux-amd64.tar.gz"
if run_download core v1.13.14 >/dev/null 2>&1; then echo "未拒绝摘要不符的内核"; exit 1; fi
[[ $(sha256sum "$is_core_bin") == "$before" ]]
fixture_core
export FAIL_CHECK=1
if run_download core v1.13.14 >/dev/null 2>&1; then echo "未拒绝不兼容的内核"; exit 1; fi
unset FAIL_CHECK
[[ $(sha256sum "$is_core_bin") == "$before" ]]
echo "通过：摘要和配置校验失败均保留旧内核"

fixture_core
fail_restart=1
if run_download core v1.13.14 restart >/dev/null 2>&1; then echo "重启失败仍报告成功"; exit 1; fi
[[ $(sha256sum "$is_core_bin") == "$before" && $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
fail_restart=0
run_download core v1.13.14 restart
[[ $("$is_core_bin" version) == 'sing-box version 1.13.14' && -f $is_core_bin.update.bak ]]
[[ ! -e $is_core_bin.update.lock ]]
echo "通过：重启失败恢复旧内核，成功更新保留备份并清理锁"

fixture_core
interrupt_restart=1
if run_download core v1.13.14 restart >/dev/null 2>&1; then echo "中断更新仍返回成功"; exit 1; fi
interrupt_restart=0
[[ $(sha256sum "$is_core_bin") == "$before" && $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
[[ ! -e $is_core_bin.update.lock ]]
echo "通过：更新收到终止信号时恢复旧内核并释放锁"

fixture_core
jq '.assets[0].digest=null' "$test_dir/assets/core.json" >"$test_dir/assets/legacy.json"
mv "$test_dir/assets/legacy.json" "$test_dir/assets/core.json"
output=$(run_download core v1.13.14 2>&1)
[[ $output == *'未提供 SHA256'* ]]
echo "通过：旧发布缺少摘要时明确提示，不伪称已校验"

is_caddy_repo=caddyserver/caddy
is_caddy_bin=$test_dir/bin/caddy
is_caddyfile=$test_dir/Caddyfile
printf '#!/bin/bash\necho v2.9.0\n' >"$is_caddy_bin"
chmod +x "$is_caddy_bin"
old_caddy=$(sha256sum "$is_caddy_bin")
mkdir "$test_dir/assets/caddy"
printf '#!/bin/bash\nif [[ $1 == version ]]; then echo v2.10.2; else exit "${FAIL_CHECK:-0}"; fi\n' \
    >"$test_dir/assets/caddy/caddy"
chmod +x "$test_dir/assets/caddy/caddy"
tar -czf "$test_dir/assets/caddy_2.10.2_linux_amd64.tar.gz" -C "$test_dir/assets/caddy" caddy
(cd "$test_dir/assets"; sha256sum caddy_2.10.2_linux_amd64.tar.gz >caddy_2.10.2_checksums.txt)
printf 'example.org {}\n' >"$is_caddyfile"
export FAIL_CHECK=1
if run_download caddy v2.10.2 >/dev/null 2>&1; then echo "Caddy 未校验现有配置"; exit 1; fi
unset FAIL_CHECK
[[ $(sha256sum "$is_caddy_bin") == "$old_caddy" ]]
: >"$test_dir/service.log"
fail_restart=1
if run_download caddy v2.10.2 restart >/dev/null 2>&1; then echo "Caddy 重启失败仍成功"; exit 1; fi
fail_restart=0
[[ $(sha256sum "$is_caddy_bin") == "$old_caddy" ]]
run_download caddy v2.10.2 restart
[[ $("$is_caddy_bin" version) == v2.10.2 ]]
echo "通过：Caddy 更新校验摘要与配置，启动失败恢复旧版"

load core.sh
_green() { printf '%s\n' "$*"; }
load() {
    if [[ $1 == systemd.sh ]]; then
        install_service() { echo "不应调用服务安装"; return 0; }
    else
        . "$repo_dir/src/$1"
    fi
}
if output=$(get install-caddy 2>&1); then echo "失败：Caddy 下载失败仍报告安装成功"; exit 1; fi
[[ $output != *'不应调用服务安装'* ]]
echo "通过：Caddy 下载失败不注册服务，也不报告安装成功"
