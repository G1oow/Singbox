#!/bin/bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
echo "添加入口测试临时目录: $test_dir"
mkdir "$test_dir/conf"
if [[ ${JQ_BIN:-} ]]; then
    jq() { "$JQ_BIN" -b "$@"; }
fi
is_sh_dir=$repo_dir
is_core=sing-box
is_core_name=sing-box
is_core_ver=1.12.12
is_core_bin=check_core
is_config_json=$test_dir/config.json
is_conf_dir=$test_dir/conf
is_core_status=running
is_sh_ver=test
is_machine_id=testvm
is_systemd=1
is_openrc=
fail_ipv4=0
fail_ipv6=0
reject_address=0
reject_config=0
fail_restart=0
fail_ready=0
load() {
    . "$repo_dir/src/$1"
    if [[ $1 == ingress.sh ]]; then
        ingress_ipv6_assigned() { [[ $reject_address == 0 ]]; }
    fi
}
err() { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
sleep() { printf 'wait %s\n' "$1" >>"$test_dir/service.log"; }
load core.sh
get_uuid() { tmp_uuid=00000000-0000-4000-8000-000000000001; }
is_port_used() { return 0; }
manage() { printf 'legacy restart\n' >>"$test_dir/service.log"; }
_wget() {
    printf '%s\n' "$*" >>"$test_dir/lookup.log"
    case $1 in
    -4) [[ $fail_ipv4 == 0 ]] || return 1; printf 'ip=198.51.100.4\n' ;;
    -6) [[ $fail_ipv6 == 0 ]] || return 1; printf 'ip=2001:db8::6\n' ;;
    *) printf '{"Answer":[{"data":"2001:db8::6"}]}\n' ;;
    esac
}
check_core() {
    printf '%s\n' "$*" >>"$test_dir/check.log"
    [[ $reject_config == 0 ]] || return 1
    if [[ ${SING_BOX_BIN:-} ]]; then
        "$SING_BOX_BIN" "$@"
    elif [[ $1 == generate && $2 == reality-keypair ]]; then
        printf 'PrivateKey: test-private\nPublicKey: test-public\n'
    fi
}
systemctl() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    if [[ $1 == restart && $fail_restart == 1 ]] &&
        [[ $(grep -c '^restart ' "$test_dir/service.log") == 1 ]]; then
        return 1
    fi
    if [[ $1 == is-active && $fail_ready == 1 ]] &&
        [[ $(grep -c '^restart ' "$test_dir/service.log") == 1 ]] &&
        grep -q '^wait 1$' "$test_dir/service.log"; then
        return 1
    fi
    return 0
}
run() (
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
: >"$test_dir/lookup.log"
: >"$test_dir/service.log"
run egress ipv6 >/dev/null
before=$(cat "$is_config_json")

output=$(run add socks 32201 tester secret --ingress ipv6)
assert_json "$is_conf_dir/Socks-v6-testvm.json" '.inbounds[0].listen == "2001:db8::6"'
[[ $output == *'@[2001:db8::6]:32201'* && $(cat "$is_config_json") == "$before" ]]
if grep -q '^-4' "$test_dir/lookup.log"; then echo "IPv6 添加流程不应先获取 IPv4"; exit 1; fi
echo "通过：命令行直接创建 IPv6 节点并立即显示正确链接"

first_node=$(cat "$is_conf_dir/Socks-v6-testvm.json")
output=$(run add --ingress ipv4 socks 32202 tester secret)
assert_json "$is_conf_dir/Socks-v4-testvm.json" '.inbounds[0].listen == "0.0.0.0"'
[[ $output == *'@198.51.100.4:32202'* ]]
output=$(run add socks 32203 tester secret --ingress=dual)
assert_json "$is_conf_dir/Socks-dual-testvm.json" '.inbounds[0].listen == "::"'
[[ $output == *'双栈入口可分别导出链接'* ]]
[[ $(cat "$is_conf_dir/Socks-v6-testvm.json") == "$first_node" && $(cat "$is_config_json") == "$before" ]]
echo "通过：新建 IPv4、IPv6、双栈节点共存，均保留同一个出口策略"

: >"$test_dir/lookup.log"
fail_ipv4=1
output=$(run add socks 32204 tester secret --ingress ipv6 --listen '[2001:db8::7]')
[[ $output == *'@[2001:db8::7]:32204'* && ! -s $test_dir/lookup.log ]]
output=$(run add socks 32205 tester secret --ingress ipv6)
[[ $output == *'@[2001:db8::6]:32205'* ]]
if grep -q '^-4' "$test_dir/lookup.log"; then echo "IPv6-only VPS 添加不应探测 IPv4"; exit 1; fi
output=$(run add socks 32206 tester secret)
assert_json "$is_conf_dir/Socks-dual-testvm-32206.json" '.inbounds[0].listen == "::"'
[[ $output == *'@[2001:db8::6]:32206'* ]]
if run add socks 32220 tester secret --ingress ipv4 >/dev/null 2>&1; then exit 1; fi
[[ ! -f $is_conf_dir/Socks-v4-testvm-32220.json ]]
echo "通过：IPv6-only VPS 可直接添加，旧命令保持双栈并正确回退 IPv6"

# 驱动真实“添加配置”菜单，而不是先创建再调用 ingress。
socks_choice=
for index in "${!protocol_list[@]}"; do
    [[ ${protocol_list[$index]} != Socks ]] || socks_choice=$((index + 1))
done
: >"$test_dir/lookup.log"
output=$(printf '1\n%s\n2\n\n32207\ntester\nsecret\n' "$socks_choice" | run main)
assert_json "$is_conf_dir/Socks-v6-testvm-32207.json" '.inbounds[0].listen == "2001:db8::6"'
[[ $output == *'请选择新节点的入口策略'* && $output == *'@[2001:db8::6]:32207'* ]]
if grep -q '^-4' "$test_dir/lookup.log"; then exit 1; fi
output=$(printf '%s\n2\n2001:db8::8\n32208\ntester\nsecret\n' "$socks_choice" | run add)
assert_json "$is_conf_dir/Socks-v6-testvm-32208.json" '.inbounds[0].listen == "2001:db8::8"'
[[ $output == *'@[2001:db8::8]:32208'* ]]
echo "通过：主菜单和 add 交互流程均可选择 IPv6、自动或手动填写地址"

fail_ipv4=0
output=$(run add reality 32209 00000000-0000-4000-8000-000000000001 example.org --ingress ipv6)
assert_json "$is_conf_dir/VLESS-REALITY-v6-testvm.json" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].tls.reality.enabled'
[[ $output == *'@[2001:db8::6]:32209'* ]]
echo "通过：默认 VLESS-REALITY 协议也直接使用 IPv6 入口"

output=$(run add ss 32211 test-password chacha20-ietf-poly1305 --ingress ipv6)
assert_json "$is_conf_dir/Shadowsocks-v6-testvm.json" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].type == "shadowsocks"'
[[ $output == *'@[2001:db8::6]:32211'* ]]
echo "通过：Shadowsocks 添加同样使用选定的 IPv6 入口"

: >"$test_dir/lookup.log"
output=$(run gen socks 32210 tester secret --ingress ipv6 --listen 2001:db8::10)
json=$(sed -n '/^{/,$p' <<<"$output")
[[ $(jq -r '.inbounds[0].listen' <<<"$json") == 2001:db8::10 ]]
output=$(run gen socks 32210 tester secret --ingress ipv4)
json=$(sed -n '/^{/,$p' <<<"$output")
[[ $(jq -r '.inbounds[0].listen' <<<"$json") == 0.0.0.0 ]]
if run gen socks 32210 tester secret --ingress ipv6 >/dev/null 2>&1; then exit 1; fi
[[ ! -s $test_dir/lookup.log && ! -f $is_conf_dir/Socks-v4-testvm-32210.json ]]
echo "通过：gen 支持入口参数，离线验证不探测网络、不写入文件"

if [[ $(printf '%s\n' 1.12.0 "$is_core_ver" | sort -V | sed -n '1p') == 1.12.0 ]]; then
    # 只验证域名检查是否到达配置校验，不启动 ACME 或写入该节点。
    : >"$test_dir/check.log"
    : >"$test_dir/lookup.log"
    reject_config=1
    if output=$(run add anytls 32212 secret example.org --ingress ipv6 \
        --listen 2001:0DB8:0:0:0:0:0:6 </dev/null 2>&1); then exit 1; fi
    reject_config=0
    [[ $output == *'配置校验失败'* ]]
    grep -q 'type=aaaa' "$test_dir/lookup.log"
    grep -q '^check ' "$test_dir/check.log"
    [[ ! -f $is_conf_dir/AnyTLS-v6-testvm.json ]]
    echo "通过：AnyTLS IPv6 添加验证 AAAA，兼容 IPv6 地址的不同写法"
fi

expect_rejection() {
    if run add socks 32220 tester secret "$@" >/dev/null 2>&1; then
        echo "未拒绝错误选项: $*"
        exit 1
    fi
    [[ ! -f $is_conf_dir/Socks-v4-testvm-32220.json && ! -f $is_conf_dir/Socks-v6-testvm-32220.json ]]
}
expect_rejection --ingress
expect_rejection --ingress wrong
expect_rejection --ingress ipv6 --ingress ipv4
expect_rejection --listen
expect_rejection --listen=
expect_rejection --listen 2001:db8::20
expect_rejection --ingress dual --listen 2001:db8::20
expect_rejection --ingress ipv6 --listen ::
expect_rejection --ingress ipv6 --listen fe80::1
if run add </dev/null >/dev/null 2>&1; then echo "交互输入结束时应取消添加"; exit 1; fi
reject_address=1
expect_rejection --ingress ipv6 --listen 2001:db8::20
reject_address=0
fail_ipv6=1
expect_rejection --ingress ipv6
fail_ipv6=0
if run add wss example.org --ingress ipv6 >/dev/null 2>&1; then exit 1; fi
[[ ! -f $is_conf_dir/VMess-WS-TLS-dual-testvm.json ]]
echo "通过：缺失、冲突、无效地址和不支持的反代入口参数均在创建前拒绝"

: >"$test_dir/service.log"
reject_config=1
expect_rejection --ingress ipv6
reject_config=0
[[ ! -s $test_dir/service.log ]]
fail_restart=1
expect_rejection --ingress ipv6
fail_restart=0
[[ $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
: >"$test_dir/service.log"
fail_ready=1
expect_rejection --ingress ipv6
fail_ready=0
[[ $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
[[ $(cat "$is_config_json") == "$before" && $(cat "$is_conf_dir/Socks-v6-testvm.json") == "$first_node" ]]
# 同名节点 (协议-地址族-机器ID) 已被其他节点占用时, 新建同名节点必须拒绝覆盖.
printf '%s\n' '{"inbounds":[{"type":"socks","tag":"occupied","listen":"127.0.0.1","listen_port":32290,"users":[{"username":"tester","password":"test-password"}]}]}' >"$is_conf_dir/Socks-v4-testvm-32209.json"
occupied_node=$(cat "$is_conf_dir/Socks-v4-testvm-32209.json")
if run add socks 32209 another-user another-password --ingress ipv4 >/dev/null 2>&1; then exit 1; fi
[[ $(cat "$is_conf_dir/Socks-v4-testvm-32209.json") == "$occupied_node" ]]
[[ ! -d ${is_config_json}.network.lock ]]
if compgen -G "$is_conf_dir/*.network.*" >/dev/null; then echo "存在未清理的创建临时文件"; exit 1; fi
echo "通过：校验、重启或启动后早退失败均撤销新节点，不覆盖同名节点及出口配置"

: >"$test_dir/lookup.log"
fail_ipv4=1
fail_ipv6=1
run change Socks-v6-testvm.json passwd changed-password >/dev/null
assert_json "$is_conf_dir/Socks-v6-testvm.json" '.inbounds[0].listen == "2001:db8::6" and .inbounds[0].users[0].password == "changed-password"'
[[ $(cat "$is_config_json") == "$before" && ! -s $test_dir/lookup.log ]]
echo "通过：添加、展示、后续修改均保持入口与出口独立"

original=$(cat "$is_conf_dir/Socks-v6-testvm.json")
: >"$test_dir/service.log"
reject_config=1
if run change Socks-v6-testvm.json passwd rejected >/dev/null 2>&1; then
    echo "失败：修改已有节点绕过配置校验"; exit 1
fi
reject_config=0
[[ $(cat "$is_conf_dir/Socks-v6-testvm.json") == "$original" && ! -s $test_dir/service.log ]]
fail_restart=1
if run change Socks-v6-testvm.json port 32230 >/dev/null 2>&1; then echo "重启失败仍报告修改成功"; exit 1; fi
fail_restart=0
[[ $(cat "$is_conf_dir/Socks-v6-testvm.json") == "$original" && ! -e $is_conf_dir/Socks-v6-testvm-32230.json ]]
[[ $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
other=$(cat "$is_conf_dir/Socks-v4-testvm.json")
is_port_used() { [[ $1 == 32202 ]] && echo occupied; }
if run change Socks-v6-testvm.json port 32202 >/dev/null 2>&1; then echo "改端口覆盖了其他节点占用的端口"; exit 1; fi
is_port_used() { return 0; }
[[ $(cat "$is_conf_dir/Socks-v4-testvm.json") == "$other" && $(cat "$is_conf_dir/Socks-v6-testvm.json") == "$original" ]]
echo "通过：修改校验失败不落盘，重启失败恢复原节点，不覆盖其他节点或其端口"

special_password='two  words * \ " // password'
run change Socks-v6-testvm.json passwd "$special_password" >/dev/null
[[ $(jq -r '.inbounds[0].users[0].password' "$is_conf_dir/Socks-v6-testvm.json") == "$special_password" ]]
run change Socks-v6-testvm.json port 32231 >/dev/null
[[ $(jq -r '.inbounds[0].listen_port' "$is_conf_dir/Socks-v6-testvm.json") == 32231 ]]
# 修改旧命名节点时迁移为新命名: 协议-IPv6/v4-机器ID, 同名重名时追加端口区分.
printf '%s\n' '{"inbounds":[{"type":"socks","tag":"legacy","listen":"2001:db8::6","listen_port":32233,"users":[{"username":"tester","password":"legacy-password"}]}]}' >"$is_conf_dir/Socks-32233.json"
run change Socks-32233.json passwd "$special_password" >/dev/null
[[ ! -e $is_conf_dir/Socks-32233.json ]]
legacy=$is_conf_dir/Socks-v6-testvm-32233.json
[[ $(jq -r '.inbounds[0].users[0].password' "$legacy") == "$special_password" ]]
url=$(run url Socks-v6-testvm-32233.json)
credentials=$(sed -n 's/.*socks:\/\/\([^@]*\)@.*/\1/p' <<<"$url" | base64 -d)
[[ $credentials == "tester:$special_password" ]]
echo "通过：密码中的空格、引号、反斜杠和通配符在修改、读取和分享链接中保持不变"
echo "全部添加入口测试通过"
