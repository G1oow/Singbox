#!/bin/bash
set -euo pipefail

# 显式运行的 VPS 冒烟测试：只监听回环，不安装或操作任何系统服务。
: "${SING_BOX_BIN:?请指定已校验的 sing-box 可执行文件}"
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in curl jq ss sha256sum; do
    command -v "$tool" >/dev/null || { echo "缺少测试工具: $tool" >&2; exit 1; }
done
umask 077
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/singbox-ipv4-live.XXXXXX")
core_pid=
stop_core() {
    if [[ $core_pid ]]; then
        kill "$core_pid" 2>/dev/null || :
        for _ in {1..30}; do
            kill -0 "$core_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$core_pid" 2>/dev/null && kill -KILL "$core_pid" 2>/dev/null || :
        wait "$core_pid" 2>/dev/null || :
        core_pid=
    fi
}
trap stop_core EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
err() { printf '%s\n' "$*" >&2; return 1; }
source "$repo_dir/src/egress.sh"
is_core_ver=$("$SING_BOX_BIN" version | sed -n 's/^sing-box version //p' | head -n 1)
endpoint=https://one.one.one.one/cdn-cgi/trace
direct_ip=$(curl -q -4 --noproxy '*' -fsS --connect-timeout 5 --max-time 20 "$endpoint" |
    sed -n 's/^ip=//p')
[[ $direct_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { echo "无法确定 IPv4 公网出口" >&2; exit 1; }
[[ ! ${EXPECTED_IPV4:-} || $direct_ip == "$EXPECTED_IPV4" ]] ||
    { echo "实际 IPv4 出口与预期不一致: $direct_ip" >&2; exit 1; }
password=$("$SING_BOX_BIN" generate uuid)
port=
for _ in {1..30}; do
    candidate=$((20000 + RANDOM % 30000))
    if [[ ! $(ss -H -ltn "sport = :$candidate") ]]; then
        port=$candidate
        break
    fi
done
[[ $port ]] || { echo "找不到空闲的回环测试端口" >&2; exit 1; }
jq -n --argjson port "$port" --arg password "$password" '{
    log: {level:"warn"},
    dns: {},
    inbounds: [{type:"socks",tag:"ipv4-test",listen:"127.0.0.1",listen_port:$port,
                users:[{username:"ipv4-test",password:$password}]}],
    outbounds: [{type:"direct",tag:"direct"}]
}' >"$test_dir/raw.json"
egress_config prefer_ipv4 "$test_dir/raw.json" >"$test_dir/base.json"
printf '内核: %s\n直接 IPv4 出口: %s\n测试目录: %s\n' "$is_core_ver" "$direct_ip" "$test_dir"
printf 'strategy\toutbound_ipv4\tlistener\n' >"$test_dir/report.tsv"

for strategy in prefer_ipv4 ipv4_only auto prefer_ipv6; do
    config=$test_dir/$strategy.json
    egress_config "$strategy" "$test_dir/base.json" >"$config"
    "$SING_BOX_BIN" check -c "$config"
    "$SING_BOX_BIN" run -c "$config" >"$test_dir/$strategy.log" 2>&1 &
    core_pid=$!
    ready=
    for _ in {1..50}; do
        kill -0 "$core_pid" 2>/dev/null || { cat "$test_dir/$strategy.log" >&2; exit 1; }
        listener=$(ss -H -ltn "sport = :$port" | awk '{print $4}')
        if [[ $listener == "127.0.0.1:$port" ]]; then ready=1; break; fi
        sleep 0.1
    done
    [[ $ready ]] || { echo "IPv4 回环监听未就绪" >&2; exit 1; }
    proxy_ip=$(curl -q -4 --noproxy '' --socks5-hostname "127.0.0.1:$port" \
        --proxy-user "ipv4-test:$password" -fsS --connect-timeout 5 --max-time 25 "$endpoint" |
        sed -n 's/^ip=//p')
    [[ $proxy_ip == "$direct_ip" ]] ||
        { echo "$strategy 代理出口异常: $proxy_ip" >&2; exit 1; }
    printf '通过：%s，SOCKS5 IPv4 入口 → HTTPS 目标，出口 %s\n' "$strategy" "$proxy_ip"
    printf '%s\t%s\t%s\n' "$strategy" "$proxy_ip" "$listener" >>"$test_dir/report.tsv"
    stop_core
    [[ ! $(ss -H -ltn "sport = :$port") ]] ||
        { echo "测试监听端口未释放" >&2; exit 1; }
done
echo "全部 IPv4 实网测试通过；测试进程和监听端口已关闭。"
