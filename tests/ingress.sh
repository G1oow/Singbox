#!/bin/bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
# 保留隔离配置用于排查；不递归删除目录，不触及真实安装。
echo "入口测试临时目录: $test_dir"
mkdir "$test_dir/conf"
if [[ ${JQ_BIN:-} ]]; then
    jq() { "$JQ_BIN" -b "$@"; }
fi
is_sh_dir=$repo_dir
is_core=sing-box
is_core_name=sing-box
is_core_ver=1.12.12
is_config_json=$test_dir/config.json
is_conf_dir=$test_dir/conf
is_core_bin=check_core
is_systemd=1
is_openrc=
is_core_status=running
is_sh_ver=test
is_machine_id=testvm
is_caddy_conf=$test_dir/caddy
node4=$is_conf_dir/Socks-32101.json
node6=$is_conf_dir/Socks-32102.json
reject_config=0
fail_restart=0
fail_ipv6=0
reject_address=0
load() {
    . "$repo_dir/src/$1"
    if [[ $1 == ingress.sh ]]; then
        ingress_ipv6_assigned() { [[ $reject_address == 0 ]]; }
    fi
}
err() { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
sleep() { return 0; }
load core.sh
load ingress.sh
get_uuid() { tmp_uuid=00000000-0000-4000-8000-000000000001; }
manage() { return 0; }
is_port_used() { return 0; }
_wget() {
    if [[ $1 == -6 ]]; then
        [[ $fail_ipv6 == 0 ]] || return 1
        printf 'ip=2001:db8::6\n'
    else
        printf 'ip=198.51.100.4\n'
    fi
}

# /proc 地址分配与服务管理是系统边界，其余路径使用真实脚本。
check_core() {
    printf '%s\n' "$@" >"$test_dir/check.log"
    [[ $reject_config == 0 ]] || return 1
    if [[ ${SING_BOX_BIN:-} ]]; then
        "$SING_BOX_BIN" "$@"
    fi
}
systemctl() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    if [[ $1 == restart && $fail_restart == 1 ]] &&
        [[ $(grep -c '^restart ' "$test_dir/service.log") == 1 ]]; then
        return 1
    fi
    return 0
}

# 每次模拟一次新的 CLI 调用，不让上次节点的缓存变量污染下一次调用。
run() (
    # 实际管理脚本未启用 errexit；旧命令包含返回 false 的条件语句。
    set +e
    main "$@"
    result=$?
    wait
    exit "$result"
)
assert_json() { jq -e "$2" "$1" >/dev/null || { echo "断言失败: $2"; exit 1; }; }
if [[ ${SING_BOX_BIN:-} ]]; then
    is_core_ver=$("$SING_BOX_BIN" version | sed -n '1p' | tr -d '\r' | cut -d ' ' -f3)
fi
printf '%s\n' '{"log":{"disabled":true},"dns":{},"outbounds":[{"type":"direct","tag":"direct"}]}' >"$is_config_json"
for port in 32101 32102; do
    jq -n --argjson port "$port" '{inbounds:[{type:"socks",tag:("Socks-"+($port|tostring)+".json"),
        listen:"::",listen_port:$port,users:[{username:"tester",password:"test-password"}]}]}' \
        >"$is_conf_dir/Socks-$port.json"
done
: >"$test_dir/service.log"

run egress ipv6 >/dev/null
before=$(cat "$is_config_json")
sibling=$(cat "$node6")
run ingress ipv4 "${node4##*/}" >/dev/null
[[ $(cat "$node6") == "$sibling" && $(cat "$is_config_json") == "$before" ]]
run ingress ipv6 "${node6##*/}" 2001:db8::6 >/dev/null
run ingress ipv6 "${node6##*/}" >/dev/null
assert_json "$node4" '.inbounds[0].listen == "0.0.0.0"'
assert_json "$node6" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].users[0].password == "test-password"'
[[ $(cat "$is_config_json") == "$before" ]]
[[ $(grep -c '^check$' "$test_dir/check.log") == 1 ]]
[[ $(grep -c "$node6$" "$test_dir/check.log") == 0 ]]
echo "通过：IPv4、IPv6 节点独立共存，主配置及出口保持不变，校验不重复加载目标"

url4=$(run url "${node4##*/}")
url6=$(run url "${node6##*/}")
[[ $url4 == *'@198.51.100.4:32101'* && $url6 == *'@[2001:db8::6]:32102'* ]]
if run url "${node4##*/}" ipv6 >/dev/null 2>&1; then echo "错误地允许不匹配的入口链接"; exit 1; fi
run ingress dual "${node4##*/}" >/dev/null
url4=$(run url "${node4##*/}" ipv4)
url6=$(run url "${node4##*/}" ipv6)
[[ $url4 == *'@198.51.100.4:32101'* && $url6 == *'@[2001:db8::6]:32101'* ]]
[[ $(cat "$is_config_json") == "$before" ]]
echo "通过：双栈同端口导出两个入口链接，共享出口"

status=$(run ingress status)
[[ $status == *'dual'* && $status == *'ipv6'* ]]
before_node=$(cat "$node6")
for address in :: ::ffff:192.0.2.1 ::ffff:c000:201 2001:::1 2001:db8::xyz fe80::1; do
    if run ingress ipv6 "${node6##*/}" "$address" >/dev/null 2>&1; then echo "未拒绝地址: $address"; exit 1; fi
done
if run ingress ipv4 "${node6##*/}" 999.1.1.1 >/dev/null 2>&1; then exit 1; fi
reject_address=1
if run ingress ipv6 "${node6##*/}" 2001:db8::9 >/dev/null 2>&1; then exit 1; fi
reject_address=0
fail_ipv6=1
if run ingress ipv6 "${node6##*/}" >/dev/null 2>&1; then exit 1; fi
if run url "${node4##*/}" ipv6 >/dev/null 2>&1; then exit 1; fi
fail_ipv6=0
[[ $(cat "$node6") == "$before_node" ]]
echo "通过：无效、未分配或不可用的 IPv6 不落盘、不回退成 IPv4"

: >"$test_dir/service.log"
reject_config=1
if run ingress ipv4 "${node6##*/}" >/dev/null 2>&1; then exit 1; fi
reject_config=0
[[ $(cat "$node6") == "$before_node" && ! -s $test_dir/service.log ]]
fail_restart=1
if run ingress ipv4 "${node6##*/}" >/dev/null 2>&1; then exit 1; fi
fail_restart=0
[[ $(cat "$node6") == "$before_node" && $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
[[ $(cat "$is_config_json") == "$before" ]]
echo "通过：校验失败不改文件，重启失败只回滚目标节点"

mkdir "${is_config_json}.network.lock"
if run ingress ipv4 "${node6##*/}" >/dev/null 2>&1; then exit 1; fi
rmdir "${is_config_json}.network.lock"
[[ $(cat "$node6") == "$before_node" ]]
echo "通过：已有网络事务锁时拒绝修改"

run change "${node6##*/}" passwd changed-password >/dev/null
# 修改旧命名节点时迁移为新命名: 协议-IPv6/v4-机器ID
node6=$is_conf_dir/Socks-v6-testvm.json
assert_json "$node6" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].users[0].password == "changed-password"'
run change "${node6##*/}" port 32103 >/dev/null
assert_json "$node6" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].listen_port == 32103'
echo "通过：修改密码和端口不会重置 IPv6-only 入口，旧命名同时迁移到新命名"

saved_node=$(cat "$node4")
config=$(jq '.inbounds[0] |= (.listen="127.0.0.1" | .transport={type:"ws",headers:{host:"example.org"}})' "$node4")
printf '%s\n' "$config" >"$node4"
if run ingress ipv4 "${node4##*/}" >/dev/null 2>&1; then echo "错误地暴露 Caddy 后端"; exit 1; fi
[[ $(cat "$node4") == "$config" ]]
printf '%s\n' "$saved_node" >"$node4"
echo "通过：Caddy 本地反代入口受到保护"

config=$(jq '.inbounds[0] |= (.type="vmess" | .users=[{uuid:"00000000-0000-4000-8000-000000000001"}])' "$node4")
printf '%s\n' "$config" >"$node4"
vmess=$(run url "${node4##*/}" ipv6 | sed -n 's/.*vmess:\/\/\([A-Za-z0-9+/=]*\).*/\1/p' | base64 -d)
[[ $(jq -r .add <<<"$vmess") == 2001:db8::6 ]]
printf '%s\n' "$saved_node" >"$node4"
echo "通过：VMess JSON 使用不带方括号的 IPv6"

config=$(jq '.inbounds[0] |= (.type="anytls" | .tls={enabled:true,acme:{domain:["example.org"]}})' "$node4")
printf '%s\n' "$config" >"$node4"
url6=$(run url "${node4##*/}" ipv6)
[[ $url6 == *'@[2001:db8::6]:32101?sni=example.org'* ]]
printf '%s\n' "$saved_node" >"$node4"
echo "通过：AnyTLS IP 入口保留域名 SNI"

# 入口切换同步重命名: 地址族段与实际监听一致
printf '9\n7\n2\n3\n' | run main >/dev/null
node6=$is_conf_dir/Socks-dual-testvm.json
assert_json "$node6" '.inbounds[0].listen == "::" and .inbounds[0].tag == "Socks-dual-testvm.json"'
[[ ! -e $is_conf_dir/Socks-v6-testvm.json ]]
echo "通过：交互菜单切换入口时同步重命名"

# 目标基础名被其他节点占用时, 重命名追加端口区分
jq -n --argjson port 32105 '{inbounds:[{type:"socks",tag:"Socks-v6-testvm.json",listen:"2001:db8::6",listen_port:$port,users:[{username:"tester",password:"test-password"}]}]}' >"$is_conf_dir/Socks-v6-testvm.json"
run ingress ipv6 "${node6##*/}" 2001:db8::6 >/dev/null
node6=$is_conf_dir/Socks-v6-testvm-32103.json
assert_json "$node6" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].tag == "Socks-v6-testvm-32103.json"'
[[ ! -e $is_conf_dir/Socks-dual-testvm.json ]]
echo "通过：入口重命名遇重名节点时追加端口，不覆盖其他节点"

# 重命名事务失败时恢复原节点, 不残留新名文件
reject_config=1
if run ingress dual "${node6##*/}" >/dev/null 2>&1; then echo "入口重命名失败未回滚"; exit 1; fi
reject_config=0
[[ -e $node6 && ! -e $is_conf_dir/Socks-dual-testvm.json ]]
echo "通过：入口重命名校验失败时恢复原节点"

# 基础名空出后, 再次切换入口回落到基础名, 与 add 命名规则一致
rm -f "$is_conf_dir/Socks-v6-testvm.json"
run ingress ipv6 "${node6##*/}" ::1 >/dev/null
node6=$is_conf_dir/Socks-v6-testvm.json
assert_json "$node6" '.inbounds[0].listen == "::1" and .inbounds[0].tag == "Socks-v6-testvm.json"'
[[ ! -e $is_conf_dir/Socks-v6-testvm-32103.json ]]
echo "通过：基础名空出后回落基础名，指定监听地址生效"

run ingress ipv4 "${node4##*/}" 127.0.0.1 >/dev/null
# 旧命名文件切换入口时保持原名, 待 change 时迁移
[[ -e $is_conf_dir/Socks-32101.json && $(jq -r '.inbounds[0].listen' "$node4") == "127.0.0.1" ]]
if [[ ${SING_BOX_BIN:-} ]] && command -v node >/dev/null; then
    for mode in ipv6 ipv4; do
        run egress "$mode" >/dev/null
        node "$repo_dir/tests/ingress-network.cjs" "$is_config_json" "$node4" "$node6" "$mode"
    done
    run ingress dual "${node4##*/}" >/dev/null
    node "$repo_dir/tests/ingress-network.cjs" "$is_config_json" "$node4" "$node6" ipv4 dual
fi
echo "全部入口测试通过"
