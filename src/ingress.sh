# 将 IPv6 展开为内核 /proc/net/if_inet6 使用的 32 位十六进制格式。
ingress_ipv6_hex() {
    local address=${1,,} left right group missing
    local groups=() tail=()
    [[ $address =~ ^[0-9a-f:]+$ && $address == *:* ]] || return 1
    if [[ $address == *::* ]]; then
        left=${address%%::*}
        right=${address#*::}
        [[ $right != *::* && $left != :* && $left != *: && $right != :* && $right != *: ]] || return 1
        [[ ! $left ]] || IFS=: read -r -a groups <<<"$left"
        [[ ! $right ]] || IFS=: read -r -a tail <<<"$right"
        missing=$((8 - ${#groups[@]} - ${#tail[@]}))
        ((missing > 0)) || return 1
        while ((missing-- > 0)); do groups+=(0); done
        groups+=("${tail[@]}")
    else
        [[ $address != :* && $address != *: ]] || return 1
        IFS=: read -r -a groups <<<"$address"
        ((${#groups[@]} == 8)) || return 1
    fi
    for group in "${groups[@]}"; do
        [[ $group =~ ^[0-9a-f]{1,4}$ ]] || return 1
    done
    for group in "${groups[@]}"; do printf '%04x' "$((16#$group))"; done
}

ingress_valid_ip() {
    local family=$1 address=$2 hex part
    local parts=()
    if [[ $family == ipv4 ]]; then
        [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        IFS=. read -r -a parts <<<"$address"
        for part in "${parts[@]}"; do
            [[ ${#part} -le 3 && ( $part == 0 || $part != 0* ) ]] || return 1
            ((10#$part <= 255)) || return 1
        done
    else
        hex=$(ingress_ipv6_hex "$address") || return 1
        # 排除未指定、IPv4 映射、组播和需要作用域的链路本地地址。
        [[ $hex != 00000000000000000000000000000000 &&
           $hex != 00000000000000000000ffff* && $hex != ff* &&
           $hex != fe[89ab]* ]] || return 1
    fi
}

ingress_ipv6_assigned() {
    local hex
    [[ -r /proc/net/if_inet6 ]] || return 0
    hex=$(ingress_ipv6_hex "$1") || return 1
    grep -q "^$hex " /proc/net/if_inet6
}

ingress_public_ip() {
    local family=$1 address
    address=$(_wget "-${family#ipv}" -T 8 -t 1 -qO- https://one.one.one.one/cdn-cgi/trace | sed -n 's/^ip=//p') || {
        err "获取 $family 公网地址失败，请检查该地址族的连通性。"
        return 1
    }
    if ! ingress_valid_ip "$family" "$address"; then
        err "无法获取可用的 $family 公网地址，请检查该地址族的连通性。"
        return 1
    fi
    printf '%s\n' "$address"
}

ingress_family() {
    case $1 in
    "::" | "") echo dual ;;
    *:*) echo ipv6 ;;
    *) echo ipv4 ;;
    esac
}

ingress_is_caddy() {
    jq -e '.inbounds[0] | .listen == "127.0.0.1" and (.transport.headers.host // "") != ""' "$1" >/dev/null
}

ingress_status() {
    local file=$1 listen
    listen=$(jq -er '.inbounds[0].listen' "$file") || return 1
    if ingress_is_caddy "$file"; then
        msg "${file##*/}: Caddy 反代入口（后端 $listen，不由 ingress 修改）"
    else
        msg "${file##*/}: $(ingress_family "$listen")，监听 $listen"
    fi
}

ingress_set() {
    local mode=${1,,} name=$2 address=$3 config target
    local is_config_file= is_auto_get_config= selection
    local modes=(ipv4 ipv6 dual)
    [[ $# -le 3 ]] || { err "用法: $is_core ingress [ipv4|ipv6|dual|status] [name] [address]"; return 1; }
    case $mode in
    "" | ipv4 | ipv6 | dual | status) ;;
    *) err "无法识别入口策略: $mode"; return 1 ;;
    esac
    [[ $mode != status || ! $address ]] || { err "status 不接受额外地址。"; return 1; }
    if [[ $mode == status && ! $name ]]; then
        for target in "$is_conf_dir"/*.json; do
            [[ -f $target ]] || continue
            ingress_status "$target" || return 1
        done
        return 0
    fi
    get file "$name" || [[ $is_config_file ]] || return 1
    target=$is_conf_dir/$is_config_file
    [[ $mode != status ]] || { ingress_status "$target"; return; }
    if [[ ! $mode ]]; then
        ask list selection "仅IPv4 仅IPv6 双栈" "\n请选择该节点的入口策略:\n"
        mode=${modes[$REPLY - 1]}
    fi
    jq -e '(.inbounds | length) == 1 and (.inbounds[0].listen | type) == "string"' "$target" >/dev/null ||
        { err "仅支持包含一个监听入站的节点配置。"; return 1; }
    if ingress_is_caddy "$target"; then
        err "此节点由 Caddy 接入，不能通过修改本地后端监听来切换公网入口。"
        return 1
    fi
    case $mode in
    ipv4)
        address=${address:-0.0.0.0}
        ingress_valid_ip ipv4 "$address" || { err "无效的 IPv4 监听地址。"; return 1; }
        ;;
    ipv6)
        if [[ ! $address ]]; then
            address=$(ingress_public_ip ipv6) || return 1
        fi
        address=${address#[}
        address=${address%]}
        ingress_valid_ip ipv6 "$address" || { err "IPv6-only 需要具体 IPv6 地址，不能使用 ::、IPv4 映射或链路本地地址。"; return 1; }
        ingress_ipv6_assigned "$address" || { err "该 IPv6 地址未分配给本机，请显式指定 VPS 的 IPv6 地址。"; return 1; }
        ;;
    dual)
        [[ ! $address ]] || { err "dual 使用 ::，不接受额外监听地址。"; return 1; }
        address=::
        ;;
    esac
    config=$(jq --arg address "$address" '.inbounds[0].listen=$address' "$target") || return 1
    load network.sh
    network_apply "$target" "$config" || return 1
    msg "\n已更新入口: $is_config_file → $mode ($address)"
    msg "其他节点和出口策略未修改。原配置备份: ${target}.network.bak\n"
}

# URI 的 IPv6 主机需要方括号；VMess JSON 地址则必须保持原始 IP。
ingress_addr() {
    local listen=${is_ingress_listen:-::} family address
    family=$(ingress_family "$listen")
    case ${is_address_family:-} in
    "" | ipv4 | ipv6) ;;
    *) err "链接地址族必须是 ipv4 或 ipv6。"; return 1 ;;
    esac
    if [[ $host ]]; then
        [[ ! $is_address_family ]] || { err "Caddy/域名反代节点请使用原域名链接，不支持强制 IP 链接。"; return 1; }
        address=$host
    elif [[ $is_address_family && $family != dual && $family != "$is_address_family" ]]; then
        err "该节点只监听 $family，不能生成 $is_address_family 入口链接。"
        return 1
    elif [[ $listen != "::" && $listen != 0.0.0.0 && $listen ]]; then
        address=$listen
    elif [[ $is_address_family || $family == ipv4 ]]; then
        address=$(ingress_public_ip "${is_address_family:-ipv4}") || return 1
    elif [[ $is_anytls_domain ]]; then
        address=$is_anytls_domain
    else
        get_ip || return 1
        address=$ip
    fi
    is_addr_host=$address
    is_addr=$address
    [[ $address != *:* ]] || is_addr="[$address]"
    return 0
}
