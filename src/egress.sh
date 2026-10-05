# 默认 direct 出口的地址族策略；不修改入站、系统路由或其他出口。
egress_current() {
    jq -er '
        [.outbounds[]? | select(.tag == "direct" and .type == "direct")][0] // {}
        | (if (.domain_resolver | type) == "object" then .domain_resolver.strategy else null end)
          // .domain_strategy // "auto"
        | if . == "" then "auto" else . end
    ' "$1"
}

egress_config() {
    local strategy=$1 config=$2 refresh=${3:-keep} modern=false
    case $strategy in
    auto | prefer_ipv4 | prefer_ipv6 | ipv4_only | ipv6_only) ;;
    *) err "无法识别出口策略: $strategy"; return 1 ;;
    esac
    if [[ $is_core_ver =~ ^v?([0-9]+)\.([0-9]+) ]]; then
        if ((BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 12))); then
            modern=true
        fi
    else
        err "无法识别 sing-box 版本: $is_core_ver"
        return 1
    fi

    jq --arg strategy "$strategy" --arg refresh "$refresh" --argjson modern "$modern" '
        def direct: .outbounds[] | select(.tag == "direct" and .type == "direct");
        def resolver_object:
            if type == "object" then . else {server: .} end;
        ([.outbounds[]? | select(.tag == "direct" and .type == "direct")] | length) as $count
        | if $count == 0 and $strategy == "auto" then .
          elif $count != 1 then error("需要唯一的 tag=direct、type=direct 出口")
          elif $modern then
            . as $config
            | if $strategy != "auto" or ($refresh == "refresh" and (direct | has("domain_resolver"))) then
                (direct) |= (
                    (.domain_resolver // null) as $old
                    | ($config.route.default_domain_resolver
                       // $config.dns.final // $config.dns.servers[0].tag // "egress-local") as $default
                    | (if $refresh == "refresh" then $default else ($old // $default) end
                       | resolver_object) as $resolver
                    | .domain_resolver = ((if ($old | type) == "object" then $old else {} end) + $resolver)
                    | if $strategy == "auto" then del(.domain_resolver.strategy)
                      else .domain_resolver.strategy = $strategy end
                    | del(.domain_strategy)
                )
                | if (direct | .domain_resolver.server) == "egress-local"
                     and ([.dns.servers[]? | select(.tag == "egress-local")] | length) == 0 then
                    .dns.servers = ((.dns.servers // []) + [{type: "local", tag: "egress-local"}])
                  else . end
              else
                (direct) |= (
                    del(.domain_strategy)
                    | if (.domain_resolver | type) == "object" then del(.domain_resolver.strategy) else . end
                )
              end
          else
            (direct) |= (
                if $strategy == "auto" then del(.domain_strategy)
                else .domain_strategy = $strategy end
            )
            | if $strategy != "auto" and ((.dns.servers // []) | length) == 0 then
                .dns.servers = [{address: "local", tag: "egress-local"}]
              else . end
          end
    ' "$config"
}

egress_restart() {
    if [[ $is_systemd ]]; then
        systemctl restart "$is_core" && systemctl is-active --quiet "$is_core"
    elif [[ $is_openrc ]]; then
        rc-service "$is_core" restart && rc-service "$is_core" status
    else
        warn "未找到 systemd 或 OpenRC，无法应用网络配置。"
        return 1
    fi
}

# DNS 与出口策略共用事务入口，避免校验失败时覆盖有效配置。
egress_apply() (
    local candidate backup="${is_config_json}.network.bak"
    candidate=$(mktemp "${is_config_json}.network.XXXXXX") || return 1
    trap 'rm -f -- "$candidate"' EXIT
    cp -p "$is_config_json" "$candidate" && printf '%s\n' "$1" >"$candidate" || return 1
    if ! "$is_core_bin" check -c "$candidate" -C "$is_conf_dir"; then
        err "配置校验失败，原配置未修改。"
        return 1
    fi
    cp -p "$is_config_json" "$backup" && mv -f "$candidate" "$is_config_json" || return 1
    if ! egress_restart; then
        if cp -p "$backup" "$candidate" && mv -f "$candidate" "$is_config_json"; then
            warn "重启失败，已恢复原配置，正在尝试恢复服务。"
            egress_restart || warn "服务仍未恢复，请检查 sing-box 日志。"
        else
            warn "自动恢复失败，请使用备份恢复: $backup"
        fi
        return 1
    fi
)

egress_set() {
    local strategy=${1,,} config
    local modes=(prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only auto)
    [[ $# -gt 1 ]] && { err "用法: $is_core egress [ipv4|ipv6|ipv4-only|ipv6-only|auto|status]"; return 1; }
    if [[ ! $strategy ]]; then
        msg "\n当前默认 direct 出口策略: $(egress_current "$is_config_json")"
        ask list is_egress_choice "IPv4优先 IPv6优先 仅IPv4解析 仅IPv6解析 恢复默认" "\n请选择出口策略:\n"
        strategy=${modes[$REPLY - 1]}
    fi
    case $strategy in
    status)
        strategy=$(egress_current "$is_config_json") || return 1
        msg "\n默认 direct 出口策略: $strategy\n"
        return 0
        ;;
    4 | ipv4) strategy=prefer_ipv4 ;;
    6 | ipv6) strategy=prefer_ipv6 ;;
    ipv4-only) strategy=ipv4_only ;;
    ipv6-only) strategy=ipv6_only ;;
    default) strategy=auto ;;
    esac
    config=$(egress_config "$strategy" "$is_config_json") || return 1
    egress_apply "$config" || return 1
    msg "\n已更新默认 direct 出口策略: $strategy"
    msg "策略作用于服务器解析的目标域名，不转换客户端直接请求的 IP 地址。"
    [[ $strategy == *_only ]] && warn "仅解析指定地址族；不支持该地址族的目标域名将无法访问。"
    msg "切换前配置已备份: ${is_config_json}.network.bak\n"
}
