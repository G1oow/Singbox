#!/bin/bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -f -- "$test_dir/config.json" "$test_dir/config.json.network.bak" "$test_dir/service.log" "$test_dir/check.log"; rmdir -- "$test_dir"' EXIT

# Windows 便携版 jq 默认输出 CRLF；生产 Linux 无需此适配。
if [[ ${JQ_BIN:-} ]]; then
    jq() { "$JQ_BIN" -b "$@"; }
fi
command -v jq >/dev/null || { echo "需要 jq"; exit 1; }

is_sh_dir=$repo_dir
is_core=sing-box
is_config_json=$test_dir/config.json
is_conf_dir=$repo_dir/tests/fixtures
is_core_bin=check_core
is_systemd=1
is_openrc=
is_core_ver=1.12.12
load() { . "$is_sh_dir/src/$1"; }
err() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
sleep() { return 0; }
load core.sh
load egress.sh
load dns.sh

check_core() {
    printf '%s\n' "$*" >>"$test_dir/check.log"
    [[ ${reject_config:-0} == 0 ]] || return 1
    [[ $1 == check && $2 == -c && $4 == -C && $5 == "$is_conf_dir" ]] || return 1
    jq -e . "$3" >/dev/null || return 1
    if [[ ${SING_BOX_BIN:-} ]]; then
        "$SING_BOX_BIN" "$@"
    fi
}

systemctl() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    if [[ $1 == restart && ${fail_restart:-0} == 1 ]] &&
        [[ $(grep -c '^restart ' "$test_dir/service.log") == 1 ]]; then
        return 1
    fi
    return 0
}

rc-service() {
    printf '%s\n' "$*" >>"$test_dir/service.log"
    return 0
}

fixture() {
    reject_config=0
    fail_restart=0
    is_systemd=1
    is_openrc=
    : >"$test_dir/service.log"
    : >"$test_dir/check.log"
    cat >"$is_config_json" <<'JSON'
{
  "log": {"disabled": true},
  "dns": {},
  "inbounds": [{"type": "socks", "tag": "test", "listen": "::", "listen_port": 12345}],
  "outbounds": [
    {"tag": "direct", "type": "direct", "connect_timeout": "5s"},
    {"tag": "custom", "type": "direct"}
  ],
  "route": {"rules": [{"domain": ["example.com"], "outbound": "custom"}]}
}
JSON
}

assert_json() {
    jq -e "$1" "$is_config_json" >/dev/null || { echo "断言失败: $1"; exit 1; }
}

assert_unchanged() {
    [[ $(cat "$is_config_json") == "$before" ]] || { echo "原配置被意外修改"; exit 1; }
}

assert_status() {
    local status
    status=$(main egress status) || return 1
    [[ $status == *"默认 direct 出口策略: $1"* ]] || { echo "出口状态不匹配: $status"; exit 1; }
}

if [[ ${SING_BOX_BIN:-} ]]; then
    is_core_ver=$("$SING_BOX_BIN" version | sed -n '1p' | tr -d '\r' | cut -d ' ' -f3)
fi
modern=0
if [[ $(printf '%s\n' 1.12.0 "$is_core_ver" | sort -V | head -n1) == 1.12.0 ]]; then
    modern=1
fi
echo "测试内核版本: $is_core_ver"

fixture
before=$(cat "$is_config_json")
assert_status auto
assert_unchanged
[[ ! -s $test_dir/service.log ]]
echo "通过：status 只读"

if main egress invalid >/dev/null 2>&1; then echo "未拒绝无效策略"; exit 1; fi
if main egress ipv6 unexpected >/dev/null 2>&1; then echo "未拒绝多余参数"; exit 1; fi
assert_unchanged
echo "通过：无效参数不修改配置"

fixture
config=$(jq '.outbounds |= map(select(.tag != "direct"))' "$is_config_json")
printf '%s\n' "$config" >"$is_config_json"
before=$(cat "$is_config_json")
if main egress ipv6 >/dev/null 2>&1; then echo "未拒绝缺失的默认出口"; exit 1; fi
assert_unchanged
echo "通过：缺失默认 direct 时不猜测或修改其他出口"

fixture
for mode in ipv4 ipv6 ipv4-only ipv6-only auto; do
    case $mode in
    ipv4) expected=prefer_ipv4 ;;
    ipv6) expected=prefer_ipv6 ;;
    ipv4-only) expected=ipv4_only ;;
    ipv6-only) expected=ipv6_only ;;
    auto) expected=auto ;;
    esac
    main egress "$mode" >/dev/null
    assert_status "$expected"
    assert_json '.inbounds[0].listen == "::" and .outbounds[0].connect_timeout == "5s"
        and .outbounds[1] == {"tag":"custom","type":"direct"}
        and .route.rules[0].outbound == "custom"'
    if ((modern)); then
        assert_json '.outbounds[0] | has("domain_strategy") | not'
    else
        assert_json '.outbounds[0] | has("domain_resolver") | not'
    fi
done
echo "通过：五种策略、状态显示与无关配置保留"

fixture
before=$(cat "$is_config_json")
main egress prefer_ipv6 >/dev/null
[[ $(cat "$is_config_json.network.bak") == "$before" ]]
main egress prefer_ipv6 >/dev/null
assert_json '[.dns.servers[] | select(.tag == "egress-local")] | length == 1'
echo "通过：备份与重复设置不增加重复解析器"

fixture
main egress ipv6 >/dev/null
main dns 11 >/dev/null
assert_status prefer_ipv6
if ((modern)); then
    assert_json '.outbounds[0].domain_resolver.server == "dns"'
fi
main dns none >/dev/null
assert_status prefer_ipv6
if ((modern)); then
    assert_json '.outbounds[0].domain_resolver.server == "egress-local"'
fi
main egress auto >/dev/null
main dns 88 >/dev/null
assert_status auto
main dns none >/dev/null
assert_status auto
echo "通过：DNS 更换、系统 DNS、恢复默认相互兼容"

fixture
before=$(cat "$is_config_json")
reject_config=1
if main egress ipv6 >/dev/null 2>&1; then echo "未处理校验失败"; exit 1; fi
assert_unchanged
[[ ! -s $test_dir/service.log ]]
if main dns 11 >/dev/null 2>&1; then echo "DNS 未处理校验失败"; exit 1; fi
assert_unchanged
echo "通过：内核校验失败不写入、不重启"

fixture
before=$(cat "$is_config_json")
fail_restart=1
if main egress ipv6 >/dev/null 2>&1; then echo "未处理重启失败"; exit 1; fi
assert_unchanged
[[ $(grep -c '^restart ' "$test_dir/service.log") == 2 ]]
echo "通过：重启失败回滚并恢复服务"

fixture
is_systemd=
is_openrc=1
main egress ipv4 >/dev/null
grep -q '^sing-box restart$' "$test_dir/service.log"
grep -q '^sing-box status$' "$test_dir/service.log"
echo "通过：OpenRC 重启与状态检查"

fixture
printf '2\n' | main egress >/dev/null
assert_status prefer_ipv6
echo "通过：交互选择"

fixture
printf '9\n6\n1\n' | main main >/dev/null
assert_status prefer_ipv4
echo "通过：主菜单入口"

if ((modern)); then
    fixture
    config=$(jq '.dns.servers=[{type:"local",tag:"custom-dns"}]
        |.outbounds[0].domain_resolver={server:"custom-dns",rewrite_ttl:60}' "$is_config_json")
    printf '%s\n' "$config" >"$is_config_json"
    main egress ipv6 >/dev/null
    assert_json '.outbounds[0].domain_resolver == {server:"custom-dns",rewrite_ttl:60,strategy:"prefer_ipv6"}'
    main dns 11 >/dev/null
    assert_json '.outbounds[0].domain_resolver == {server:"dns",rewrite_ttl:60,strategy:"prefer_ipv6"}'
    main egress auto >/dev/null
    assert_json '.outbounds[0].domain_resolver == {server:"dns",rewrite_ttl:60}'
    echo "通过：保留自定义解析器参数"
fi

echo "全部测试通过"

# 沿用现有三个内核版本的 CI 测试入口，不额外增加 workflow 权限或依赖。
bash "$repo_dir/tests/ingress.sh"
bash "$repo_dir/tests/add-ingress.sh"
