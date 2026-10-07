#!/bin/bash
set -eo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
echo "CDN 测试临时目录: $test_dir"
# Windows 便携 Caddy 会自行解析 import，需要配置内使用它认识的绝对路径。
if [[ ${CADDY_BIN:-} && $(uname -s) == MINGW* ]]; then
    test_dir=$(cygpath -am "$test_dir")
fi
mkdir -p "$test_dir/conf" "$test_dir/caddy/sites" "$test_dir/caddy/233boy"
if [[ ${JQ_BIN:-} ]]; then
    jq() {
        # Git Bash 不应把 --arg 中的 WS 路径转换为 Windows 文件路径。
        local params=("$@") index excluded=
        for ((index = 0; index < ${#params[@]} - 2; index++)); do
            [[ ${params[$index]} != --arg ]] || excluded+="${params[$((index + 2))]};"
        done
        MSYS2_ARG_CONV_EXCL="$excluded" "$JQ_BIN" -b "$@"
    }
fi
is_sh_dir=$repo_dir
is_core=sing-box
is_core_name=sing-box
is_core_ver=1.12.12
if [[ ${SING_BOX_BIN:-} ]]; then
    is_core_ver=$("$SING_BOX_BIN" version | head -1 | tr -d '\r' | cut -d ' ' -f3)
fi
is_core_bin=check_core
is_conf_dir=$test_dir/conf
is_config_json=$test_dir/config.json
is_caddy_dir=$test_dir/caddy
is_caddy_conf=$is_caddy_dir/233boy
is_caddyfile=$is_caddy_dir/Caddyfile
is_caddy_bin=$test_dir/mock-caddy
is_http_port=80
is_https_port=443
is_caddy=1
is_systemd=1
is_openrc=
is_sh_ver=test
export CDN_TEST_DIR=$test_dir
export REJECT_CADDY=0
reject_core=0
fail_service=
fail_status=
dns_fail=0
probe_origin=1
probe_edge=1
probe_http_status=101
probe_accept='s3pPLMBiTxaQ9kYGzzhZRbK+xOo='
trace_exit=0
trace_http=200
proxy_fail=0
download_fail=0
used_port=
load() {
    case $1 in
    download.sh) download() { printf 'install %s\n' "$1" >>"$test_dir/service.log"; } ;;
    systemd.sh) install_service() { return 0; } ;;
    *) . "$repo_dir/src/$1" ;;
    esac
}
err() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
sleep() { :; }
load core.sh
load cdn.sh
load cdn-guide.sh
get_uuid() { tmp_uuid=00000000-0000-4000-8000-000000000001; }
get_port() { tmp_port=32001; }
is_port_used() { [[ $used_port != "$1" ]] || printf '%s\n' "$1"; }
check_core() {
    [[ $reject_core == 0 ]] || return 1
    if [[ ${SING_BOX_BIN:-} ]]; then "$SING_BOX_BIN" "$@"; fi
}
cat >"$is_caddy_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$CDN_TEST_DIR/caddy.log"
[[ $REJECT_CADDY == 0 ]] || exit 1
if [[ ${CADDY_BIN:-} ]]; then "$CADDY_BIN" "$@"; fi
EOF
chmod +x "$is_caddy_bin"
systemctl() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    [[ $1 != restart || $2 != "$fail_service" ]] &&
        [[ $1 != is-active || ${@: -1} != "$fail_status" ]]
}
rc-service() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    [[ $2 != restart || $1 != "$fail_service" ]]
}
_wget() {
    [[ $dns_fail == 0 ]] || return 1
    # 返回 CF 边缘 IP 而非本机地址，确保不误用旧的灰云检测。
    printf '%s\n' '{"Status":0,"Answer":[{"type":1,"data":"104.16.0.1"}]}'
}
curl() {
    local scope=edge arg output= headers= domain index
    local params=("$@")
    printf '%s\n' "$*" >>"$test_dir/probe.log"
    if [[ $* == *--proxy* ]]; then
        for ((index = 0; index < ${#params[@]} - 1; index++)); do
            [[ ${params[$index]} != --output ]] || output=${params[$((index + 1))]}
        done
        if [[ ${@: -1} == */cdn-cgi/trace ]]; then
            [[ $proxy_fail == 0 ]] || return 28
            printf 'ip=198.51.100.4\ncolo=HKG\n' >"$output"
        else
            [[ $download_fail == 0 ]] || return 28
            printf '200|1048576|0|2.0|524288'
        fi
        return 0
    fi
    if [[ ${@: -1} == */cdn-cgi/trace && $* != *--proxy* ]]; then
        for ((index = 0; index < ${#params[@]} - 1; index++)); do
            case ${params[$index]} in
            --output) output=${params[$((index + 1))]} ;;
            --dump-header) headers=${params[$((index + 1))]} ;;
            esac
        done
        domain=${@: -1}; domain=${domain#https://}; domain=${domain%%/*}
        printf 'h=%s\ncolo=HKG\nloc=CN\n' "$domain" >"$output"
        printf 'HTTP/1.1 %s Test\r\nServer: cloudflare\r\n' "$trace_http" >"$headers"
        printf '%s|0|0.05|0.15|0.20' "$trace_http"
        return "$trace_exit"
    fi
    for arg in "$@"; do [[ $arg != *:443:127.0.0.1 ]] || scope=origin; done
    [[ $scope != origin || $probe_origin == 1 ]] || return 60
    printf 'HTTP/1.1 %s Test Response\r\n' "$probe_http_status"
    printf 'Sec-WebSocket-Accept: %s\r\n' "$probe_accept"
    [[ $scope != edge || $probe_edge != 1 ]] || printf 'CF-Ray: abc123-HKG\r\n'
    printf '\r\n'
    # curl 收到 101 后会因等待 WebSocket 数据超时，这不应被误判为握手失败。
    return 28
}
run() ( set +e; main "$@"; )
assert_json() { jq -e "$2" "$1" >/dev/null; }
assert_absent() {
    local domain=$1
    [[ ! -f $is_caddy_conf/$domain.conf && ! -f $is_caddy_conf/$domain.conf.add &&
       ! -f $is_conf_dir/VLESS-WS-TLS-$domain.json && ! -d ${is_config_json}.network.lock ]]
    if compgen -G "$is_conf_dir/.cdn.*" >/dev/null; then echo "CDN 临时目录未清理"; exit 1; fi
}
printf '%s\n' '{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}]}' >"$is_config_json"
cat >"$is_caddyfile" <<EOF
{
    admin off
    http_port 80
    https_port 443
}
import $is_caddy_conf/*.conf
import $is_caddy_dir/sites/*.conf
EOF
printf '%s\n' '{"inbounds":[{"type":"socks","tag":"existing","listen":"127.0.0.1","listen_port":32999}]}' >"$is_conf_dir/Socks-32999.json"
original_config=$(cat "$is_config_json")
original_node=$(cat "$is_conf_dir/Socks-32999.json")
original_caddy=$(cat "$is_caddyfile")
output=$(run cdn EXAMPLE.org --yes)
node=$is_conf_dir/VLESS-WS-TLS-example.org.json
assert_json "$node" '.inbounds[0] | .type == "vless" and .listen == "127.0.0.1" and
    .listen_port == 32001 and .transport.type == "ws" and .tls == null and
    .transport.headers.host == "example.org"'
[[ $output == *'CF CDN 链路验证通过'* && $output == *'vless://'* &&
   $output == *'sni=example.org'* && $output != *'allowInsecure=1'* ]]
grep -q 'email acme-00000000@example.org' "$is_caddy_conf/example.org.conf.add"
grep -q disable_tlsalpn_challenge "$is_caddy_conf/example.org.conf.add"
[[ $(cat "$is_config_json") == "$original_config" && $(cat "$is_caddyfile") == "$original_caddy" &&
   $(cat "$is_conf_dir/Socks-32999.json") == "$original_node" ]]
echo "通过：仅需域名，默认 VLESS、随机联系地址、回环监听，保留出口和旧节点"

for protocol in vmess trojan; do
    output=$(run cdn "$protocol.example.org" "$protocol" admin@example.org --yes)
    [[ $output == *"$protocol://"* && $output == *'CF CDN 链路验证通过'* ]]
    grep -q 'email admin@example.org' "$is_caddy_conf/$protocol.example.org.conf.add"
done
assert_json "$is_conf_dir/Trojan-WS-TLS-trojan.example.org.json" \
    '.inbounds[0].users[0].password == "00000000-0000-4000-8000-000000000001"'
output=$(run url VLESS-WS-TLS-example.org.json)
[[ $output == *'@example.org:443?'* && $output == *'type=ws'* ]]
output=$(run url VMess-WS-TLS-vmess.example.org.json)
encoded=$(grep -o 'vmess://[A-Za-z0-9+/=]*' <<<"$output" | head -1)
decoded=$(printf '%s' "${encoded#vmess://}" | base64 -d)
jq -e '.add == "vmess.example.org" and .host == "vmess.example.org" and .port == "443" and .tls == "tls" and .net == "ws"' <<<"$decoded" >/dev/null
echo "通过：VMess/Trojan、自定义邮箱、真实 URL 导出"

probe_before=$(wc -l <"$test_dir/probe.log")
output=$(run cdn export example.org 104.16.0.1)
[[ $output == *'@104.16.0.1:443?'* && $output == *'sni=example.org'* &&
   $output == *'host=example.org'* && $output == *'path=%2F00000000-'* ]]
[[ $(wc -l <"$test_dir/probe.log") == "$probe_before" ]]
echo "通过：优选 IP 导出只修改连接地址，保留域名、凭据和路径且不触网"

output=$(run cdn check example.org 104.16.0.1)
[[ $output == *'CF 边缘 TLS 通过'* && $output == *'不是客户端线路'* ]]
trace_exit=28
if run cdn check example.org 104.16.0.1 >/dev/null 2>&1; then exit 1; fi
trace_exit=0
trace_http=403
if run cdn check example.org 104.16.0.1 >/dev/null 2>&1; then exit 1; fi
trace_http=200
echo "通过：域名预检区分 TLS/HTTP 失败，不把 VPS 测试当客户端线路"

printf '\357\273\277"IP 地址",延迟\r\n"104.16.0.1",10\r\n"104.16.0.1",11\r\n"2606:4700::abcd",20\r\n' >"$test_dir/candidates.csv"
output=$(run cdn export example.org --csv "$test_dir/candidates.csv")
[[ $(grep -c '^vless://' <<<"$output") == 2 && $output == *'@[2606:4700::abcd]:443?'* ]]
output=$(run cdn export vmess.example.org 104.16.0.1)
decoded=$(printf '%s' "${output#vmess://}" | base64 -d)
jq -e '.add == "104.16.0.1" and .sni == "vmess.example.org" and .host == "vmess.example.org" and .net == "ws"' <<<"$decoded" >/dev/null
output=$(run cdn export trojan.example.org 104.16.0.1)
[[ $output == 'trojan://00000000-0000-4000-8000-000000000001@104.16.0.1:443?'* ]]
printf 'IP 地址,延迟\nnot-an-ip,1\n' >"$test_dir/invalid.csv"
if run cdn export example.org --csv "$test_dir/invalid.csv" >/dev/null 2>&1; then exit 1; fi
if run cdn export example.org 127.0.0.1 >/dev/null 2>&1; then exit 1; fi
if run cdn export example.org 198.18.0.1 >/dev/null 2>&1; then exit 1; fi
run cdn status example.org 104.16.0.1 >/dev/null
echo "通过：CSV BOM/CRLF、去重、IPv6、三种分享协议和优选IP状态检查"

cat >"$test_dir/client-core" <<'EOF'
#!/bin/bash
if [[ $1 == run ]]; then exec sleep 2; fi
cp -- "$3" "$CDN_TEST_DIR/last-client.json"
if [[ ${SING_BOX_BIN:-} ]]; then "$SING_BOX_BIN" "$@"; fi
EOF
chmod +x "$test_dir/client-core"
original_core=$is_core_bin
is_core_bin=$test_dir/client-core
output=$(run cdn test example.org 104.16.0.1)
[[ $output == *'实际代理访问通过'* && $output == *'1 MiB 下载完成'* ]]
assert_json "$test_dir/last-client.json" '.outbounds[0] |
    .server == "104.16.0.1" and .tls.enabled and .tls.server_name == "example.org" and .transport.type == "ws"'
proxy_fail=1
if run cdn test example.org >/dev/null 2>&1; then exit 1; fi
proxy_fail=0
download_fail=1
if run cdn test example.org >/dev/null 2>&1; then exit 1; fi
download_fail=0
run cdn test vmess.example.org >/dev/null
assert_json "$test_dir/last-client.json" '.outbounds[0].security == "auto"'
run cdn test trojan.example.org >/dev/null
assert_json "$test_dir/last-client.json" '.outbounds[0].password != null'
is_core_bin=$original_core
echo "通过：实际代理测试的配置、认证转发失败和下载失败结果，不改服务端节点"

output=$(printf 'menu.example.org\n\n\nyes\nn\nn\n' | run cdn)
[[ $output == *'CF CDN 链路验证通过'* ]]
output=$(printf '11\nmain.example.org\n\n\nyes\nn\nn\n' | run main)
[[ $output == *'CF CDN 链路验证通过'* ]]
output=$(printf ' https://GUIDE.example.org/ \n2\n104.16.0.1\nyes\nn\nn\n' | run cdn guide)
[[ $output == *'[1/5]'* && $output == *'[5/5]'* && $output != *'请输入邮箱'* ]]
[[ -f $is_conf_dir/VMess-WS-TLS-guide.example.org.json && -f $test_dir/cdn-links/guide.example.org.txt ]]
grep -q 'email acme-00000000@guide.example.org' "$is_caddy_conf/guide.example.org.conf.add"
node_before=$(cat "$node")
service_before=$(wc -l <"$test_dir/service.log")
output=$(printf 'example.org\n104.16.0.1\nn\nn\n' | run cdn guide)
[[ $output == *'复用现有配置'* && $(cat "$node") == "$node_before" &&
   $(wc -l <"$test_dir/service.log") == "$service_before" ]]
if printf 'no\n' | run cdn cancelled.example.org >/dev/null 2>&1; then exit 1; fi
assert_absent cancelled.example.org
if run cdn eof.example.org </dev/null >/dev/null 2>&1; then exit 1; fi
assert_absent eof.example.org
echo "通过：CLI、主菜单、确认取消和 EOF"

run cdn retire.example.org --yes >/dev/null
retired_before=$(cat "$is_conf_dir/VLESS-WS-TLS-retire.example.org.json")
if printf 'no\n' | run cdn remove retire.example.org >/dev/null 2>&1; then exit 1; fi
reject_core=1
if run cdn remove retire.example.org --yes >/dev/null 2>&1; then exit 1; fi
reject_core=0
[[ $(cat "$is_conf_dir/VLESS-WS-TLS-retire.example.org.json") == "$retired_before" ]]
REJECT_CADDY=1
if run cdn remove retire.example.org --yes >/dev/null 2>&1; then exit 1; fi
REJECT_CADDY=0
fail_service=caddy
if run cdn remove retire.example.org --yes >/dev/null 2>&1; then exit 1; fi
fail_service=
[[ -f $is_caddy_conf/retire.example.org.conf && -f $is_caddy_conf/retire.example.org.conf.add ]]
run cdn remove retire.example.org --yes >/dev/null
assert_absent retire.example.org
[[ $(cat "$node") == "$node_before" && $(cat "$is_conf_dir/Socks-32999.json") == "$original_node" ]]
if compgen -G "$is_conf_dir/.cdn-remove.*" >/dev/null; then exit 1; fi
if run cdn remove example.org unexpected >/dev/null 2>&1; then exit 1; fi
echo "通过：旧CDN确认删除、失败恢复和不保留兼容配置，其他节点不受影响"

run cdn old-wizard.example.org --yes >/dev/null
old_choice=0
while IFS= read -r old_domain; do
    old_choice=$((old_choice + 1))
    [[ $old_domain != old-wizard.example.org ]] || break
done < <(cdn_other_domains replacement.example.org)
output=$(printf 'replacement.example.org\n3\n\nYES\nno\nYES\n%s\nYES\n' "$old_choice" | run cdn guide)
[[ $output == *'已删除旧 CDN：old-wizard.example.org'* &&
   -f $is_conf_dir/Trojan-WS-TLS-replacement.example.org.json ]]
assert_absent old-wizard.example.org
is_core_bin=$test_dir/client-core
proxy_fail=1
if output=$(printf 'unfinished.example.org\n\n\nyes\n\n' | run cdn guide 2>&1); then exit 1; fi
[[ $output == *'暂不清理旧节点'* && -f $is_conf_dir/VLESS-WS-TLS-unfinished.example.org.json &&
   $(cat "$node") == "$node_before" ]]
proxy_fail=0
is_core_bin=$original_core
echo "通过：引导内选择协议、确认客户端可用后清理旧CDN；测试失败不进入删除"

expect_rejection() {
    if run cdn "$@" >/dev/null 2>&1; then echo "应拒绝参数: $*"; exit 1; fi
}
expect_rejection 'https://example.org' --yes
expect_rejection '../example.org' --yes
expect_rejection $'a.org\nimport evil' --yes
expect_rejection 'example.org:443' --yes
expect_rejection '127.0.0.1' --yes
expect_rejection '-bad.example.org' --yes
expect_rejection 'a..example.org' --yes
expect_rejection good.example.org reality --yes
expect_rejection good.example.org anytls --yes
expect_rejection good.example.org vless $'a@example.org\n}' --yes
expect_rejection good.example.org --unknown
expect_rejection status example.org extra
expect_rejection example.org --yes
dns_fail=1
expect_rejection no-dns.example.org --yes
dns_fail=0
is_https_port=8443
expect_rejection wrong-port.example.org --yes
is_https_port=443
assert_absent no-dns.example.org
assert_absent wrong-port.example.org
mkdir "${is_config_json}.network.lock"
expect_rejection locked.example.org --yes
[[ -d ${is_config_json}.network.lock ]]
rmdir "${is_config_json}.network.lock"
assert_absent locked.example.org
printf '# 其他站点，不能覆盖\n' >"$is_caddy_conf/reserved.example.org.conf"
expect_rejection reserved.example.org --yes
[[ $(cat "$is_caddy_conf/reserved.example.org.conf") == '# 其他站点，不能覆盖' ]]
before=$(cat "$node")
if run change VLESS-WS-TLS-example.org.json id auto >/dev/null 2>&1; then exit 1; fi
if run add vws example.org >/dev/null 2>&1; then exit 1; fi
[[ $(cat "$node") == "$before" ]]
echo "通过：参数注入、重复域名、DNS、非标准端口和破坏性旧管理流程均被拒绝"

reject_core=1
expect_rejection core-fail.example.org --yes
reject_core=0
assert_absent core-fail.example.org
REJECT_CADDY=1
expect_rejection caddy-fail.example.org --yes
REJECT_CADDY=0
assert_absent caddy-fail.example.org
fail_service=sing-box
expect_rejection restart-fail.example.org --yes
fail_service=caddy
expect_rejection restart-caddy.example.org --yes
fail_service=
fail_status=caddy
expect_rejection caddy-exit.example.org --yes
fail_status=
assert_absent restart-fail.example.org
assert_absent restart-caddy.example.org
assert_absent caddy-exit.example.org
[[ $(cat "$is_caddyfile") == "$original_caddy" && $(cat "$node") == "$before" ]]
echo "通过：双配置校验失败、服务重启失败和启动早退全部回滚"

probe_origin=0
set +e
output=$(run cdn pending.example.org --yes 2>&1)
result=$?
set -e
[[ $result == 2 && $output == *'源站尚未就绪'* && $output != *'CF CDN 链路验证通过'* ]]
[[ -f $is_conf_dir/VLESS-WS-TLS-pending.example.org.json ]]
probe_origin=1
probe_edge=0
set +e
output=$(run cdn status example.org 2>&1)
result=$?
set -e
[[ $result == 2 && $output == *'尚未验证 CF CDN 链路'* ]]
probe_edge=1
run cdn status example.org >/dev/null
for probe_http_status in 200 301 403 525; do
    if cdn_probe example.org /test edge; then echo "错误接受 HTTP $probe_http_status"; exit 1; fi
done
probe_http_status=101
probe_accept=invalid
if cdn_probe example.org /test edge; then echo "错误接受无效握手摘要"; exit 1; fi
probe_accept='s3pPLMBiTxaQ9kYGzzhZRbK+xOo='
grep -q -- '--noproxy \* --http1.1 --proto =https' "$test_dir/probe.log"
if grep -Eq -- '--insecure|--location' "$test_dir/probe.log"; then exit 1; fi
echo "通过：区分证书待签发、灰云和 CF 链路验证，不把 101 后超时误判为失败"

is_systemd=
is_openrc=1
run cdn openrc.example.org --yes >/dev/null
grep -q '^caddy restart$' "$test_dir/service.log"
grep -q '^sing-box restart$' "$test_dir/service.log"
echo "通过：OpenRC 服务管理"
is_systemd=1
is_openrc=

# 新装 Caddy 路径与失败清理；不碰已存在站点。
is_caddy=
is_caddy_dir=$test_dir/fresh
is_caddy_conf=$is_caddy_dir/233boy
is_caddyfile=$is_caddy_dir/Caddyfile
# 二进制函数允许模拟下载后的 Caddy，无需在测试中真实安装服务。
is_caddy_bin=check_caddy
check_caddy() { "$test_dir/mock-caddy" "$@"; }
used_port=443
expect_rejection busy.example.org --yes
used_port=
REJECT_CADDY=1
expect_rejection fresh-fail.example.org --yes
REJECT_CADDY=0
assert_absent fresh-fail.example.org
[[ ! -f $is_caddyfile ]]
grep -q '^disable caddy$' "$test_dir/service.log"
run cdn fresh.example.org --yes >/dev/null
[[ -f $is_caddyfile ]]
grep -q '^install caddy$' "$test_dir/service.log"
echo "通过：首次安装、端口占用拒绝和失败后关闭新增服务自启"
# cdn_set 的子进程必须隔离内部状态，不能污染同一调用者的下一次操作。
[[ ! ${is_protocol:-} && ! ${is_config_file:-} && ! ${host:-} ]]
echo "全部 CDN 测试通过"
