# CF 普通 CDN 只承载 HTTP/WebSocket；不把 REALITY、QUIC 或裸 TCP 伪装成 CDN 节点。
cdn_valid_domain() {
    local domain=$1 label
    local labels=()
    [[ ${#domain} -le 253 && $domain == *.* && $domain != *[!a-z0-9.-]* &&
       $domain != *..* && $domain != *. && ! $domain =~ ^[0-9.]+$ ]] || return 1
    IFS=. read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
    done
}

cdn_valid_email() {
    local email=$1 domain=${1#*@}
    [[ ${#email} -le 254 && $email =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*@[a-zA-Z0-9.-]+$ ]] || return 1
    cdn_valid_domain "${domain,,}"
}

cdn_is_managed() {
    local domain=${1,,}
    domain=${domain%.}
    cdn_valid_domain "$domain" && [[ -f $is_caddy_conf/$domain.conf.add ]] &&
        grep -Fxq '# sing-box-cf-cdn-v1' "$is_caddy_conf/$domain.conf.add"
}

cdn_dns_ready() {
    local domain=$1 type response
    for type in A AAAA; do
        response=$(_wget -T 8 -t 1 -qO- --header='accept: application/dns-json' \
            "https://one.one.one.one/dns-query?name=$domain&type=$type") || continue
        if jq -e '.Status == 0 and any(.Answer[]?; (.type == 1 or .type == 28))' \
            <<<"$response" >/dev/null 2>&1; then
            return 0
        fi
    done
    warn "域名尚无可用的公网 A/AAAA 解析，或 DNS 查询失败。请先在 CF 中解析到本机。"
    return 1
}

cdn_restart_caddy() {
    if [[ $is_systemd ]]; then
        systemctl restart caddy || return 1
        sleep 1
        systemctl is-active --quiet caddy
    elif [[ $is_openrc ]]; then
        rc-service caddy restart || return 1
        sleep 1
        rc-service caddy status
    else
        return 1
    fi
}

# 不跟随跳转，不使用环境代理，不跳过 TLS 校验；101 和固定握手摘要验证真实 WS 上游。
cdn_probe() {
    local domain=$1 path=$2 scope=$3 headers address=${4:-} result
    local options=()
    [[ $scope != origin ]] || address=127.0.0.1
    if [[ $address ]]; then
        [[ $address != *:* ]] || address="[$address]"
        options=(--resolve "$domain:443:$address")
    fi
    if headers=$(curl -q --silent --show-error --noproxy '*' --http1.1 --proto '=https' \
        --connect-timeout 3 --max-time 5 "${options[@]}" \
        --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
        --header 'Sec-WebSocket-Version: 13' \
        --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        --dump-header - --output /dev/null "https://$domain$path" 2>/dev/null); then
        result=0
    else
        result=$?
    fi
    [[ $result == 0 || $result == 28 ]] || return 1
    headers=${headers//$'\r'/}
    grep -Eq '^HTTP/1\.[01] 101( |$)' <<<"$headers" &&
        grep -Eiq '^Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=[[:space:]]*$' <<<"$headers" ||
        return 1
    [[ $scope != edge ]] || grep -Eiq '^cf-ray: [a-z0-9-]+' <<<"$headers"
}

cdn_status() {
    local domain=$1 address=${2:-} path= file found=
    [[ $# -le 2 ]] || { warn "用法: sb cdn status <domain> [IP]"; return 1; }
    if [[ $address ]]; then
        load cdn-guide.sh
        address=$(cdn_address "$address") || { warn "优选地址必须是公网 IP。"; return 1; }
    fi
    cdn_valid_domain "$domain" && cdn_is_managed "$domain" ||
        { warn "没有找到该域名的 CDN 配置。"; return 1; }
    command -v curl >/dev/null || { warn "状态检查需要 curl，请先安装。"; return 1; }
    for file in "$is_conf_dir"/*-WS-TLS-"$domain".json; do
        [[ -f $file ]] || continue
        path=$(jq -er --arg domain "$domain" '.inbounds[0] |
            select(.listen == "127.0.0.1" and .transport.type == "ws" and
                   .transport.headers.host == $domain) | .transport.path' "$file") || return 1
        found=1
        break
    done
    [[ $found ]] || { warn "找不到对应的 WebSocket 入站。"; return 1; }
    if ! cdn_probe "$domain" "$path" origin; then
        warn "源站尚未就绪：证书可能仍在申请，或 Caddy / sing-box 未正常运行。"
        msg "检查 TCP 80/443、A/AAAA、CAA、ACME 限流及服务日志；稍后运行: sb cdn status $domain"
        return 2
    fi
    msg "源站证书校验及 WebSocket 握手通过。"
    if ! cdn_probe "$domain" "$path" edge "$address"; then
        warn "尚未验证 CF CDN 链路，不能视为接入成功。"
        msg "确认橙云、Full (strict)、边缘证书、WebSockets 和 WAF 放行，然后运行: sb cdn status $domain"
        return 2
    fi
    msg "CF CDN 链路验证通过：HTTPS + CF-Ray + WebSocket 101。"
    msg "该检查来自当前机器，不等同于客户端线路、代理认证或吞吐测试；是否提速取决于实际线路。"
}

cdn_apply() (
    local domain=$1 protocol=$2 email=$3 uuid=$4 path=$5 port=$6
    local lock="${is_config_json}.network.lock" stage= node= site= addon=
    local node_created= site_created= addon_created= root_created= services_touched= confirmed=
    local old_caddy=${is_caddy:-} caddy_started= caddy_installed= file
    local name="${protocol}-WS-TLS-${domain}.json"
    local check_args=(-c "$is_config_json")
    mkdir "$lock" 2>/dev/null || { warn "其他网络配置操作正在执行，请稍后重试。"; return 1; }
    cleanup_cdn() {
        local result=$?
        if [[ ! $confirmed ]]; then
            [[ ! $node_created ]] || rm -f -- "$is_conf_dir/$name"
            [[ ! $site_created ]] || rm -f -- "$is_caddy_conf/$domain.conf"
            [[ ! $addon_created ]] || rm -f -- "$is_caddy_conf/$domain.conf.add"
            [[ ! $root_created ]] || rm -f -- "$is_caddyfile"
            if [[ $services_touched ]]; then
                network_restart || warn "sing-box 恢复失败，请检查服务日志。"
            fi
            if [[ $caddy_started ]]; then
                if [[ $old_caddy ]]; then
                    cdn_restart_caddy || warn "Caddy 恢复失败，请检查服务日志。"
                elif [[ $is_systemd ]]; then
                    systemctl stop caddy || :
                else
                    rc-service caddy stop || :
                fi
            fi
            if [[ $caddy_installed ]]; then
                if [[ $is_systemd ]]; then
                    systemctl disable caddy || :
                else
                    rc-update del caddy default || :
                fi
            fi
            warn "CDN 配置未应用，已撤销本次新增配置；已下载的 Caddy 和 ACME 存储不会删除。"
        fi
        if [[ $stage ]]; then
            rm -f -- "$stage/node" "$stage/site" "$stage/addon" "$stage/Caddyfile"
            rmdir -- "$stage"
        fi
        rmdir -- "$lock"
        return "$result"
    }
    trap cleanup_cdn EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    umask 077
    # 只新建专属域名，绝不覆盖已有节点或反代站点。
    for file in "$is_caddy_conf/$domain.conf" "$is_caddy_conf/$domain.conf.add" \
        "$is_conf_dir"/*-WS-TLS-"$domain".json; do
        [[ ! -e $file && ! -L $file ]] || { warn "域名已被使用，不会覆盖: $file"; return 1; }
    done
    stage=$(mktemp -d "$is_conf_dir/.cdn.XXXXXX") || return 1
    node=$stage/node; site=$stage/site; addon=$stage/addon
    jq -n --arg tag "$name" --arg protocol "${protocol,,}" --arg uuid "$uuid" \
        --arg host "$domain" --arg path "$path" --argjson port "$port" \
        '{inbounds:[{tag:$tag,type:$protocol,listen:"127.0.0.1",listen_port:$port,
          users:[(if $protocol == "trojan" then {password:$uuid} else {uuid:$uuid} end)],
          transport:{type:"ws",path:$path,headers:{host:$host},
                     early_data_header_name:"Sec-WebSocket-Protocol"}}]}' >"$node" || return 1
    for file in "$is_conf_dir"/*.json; do
        [[ ! -f $file ]] || check_args+=(-c "$file")
    done
    "$is_core_bin" check "${check_args[@]}" -c "$node" || { warn "sing-box 配置校验失败。"; return 1; }
    if [[ ! $is_caddy ]]; then
        caddy_installed=1
        get install-caddy || return 1
    fi
    mkdir -p "$is_caddy_conf" "$is_caddy_dir/sites" || return 1
    cat >"$addon" <<EOF
# sing-box-cf-cdn-v1
# 仅使用 HTTP-01，CF 不透传 TLS-ALPN-01；证书由 Caddy 自动续期。
tls {
    issuer acme {
        dir https://acme-v02.api.letsencrypt.org/directory
        email $email
        disable_tlsalpn_challenge
    }
}
EOF
    cat >"$site" <<EOF
$domain:443 {
    reverse_proxy $path 127.0.0.1:$port
    import "$is_caddy_conf/$domain.conf.add"
}
EOF
    if [[ -f $is_caddyfile ]]; then
        cp -p "$is_caddyfile" "$stage/Caddyfile" || return 1
    else
        cat >"$stage/Caddyfile" <<EOF
{
    admin off
    http_port 80
    https_port 443
}
import $is_caddy_conf/*.conf
import $is_caddy_dir/sites/*.conf
EOF
    fi
    # 先发布站点（运行中的 Caddy 不会自动加载文件），校验整份配置后再启动服务。
    ln -T "$addon" "$is_caddy_conf/$domain.conf.add" || return 1
    addon_created=1
    ln -T "$site" "$is_caddy_conf/$domain.conf" || return 1
    site_created=1
    "$is_caddy_bin" validate --config "$stage/Caddyfile" --adapter caddyfile ||
        { warn "Caddy 配置校验失败。"; return 1; }
    if [[ ! -f $is_caddyfile ]]; then
        ln -T "$stage/Caddyfile" "$is_caddyfile" || return 1
        root_created=1
    fi
    ln -T "$node" "$is_conf_dir/$name" || return 1
    node_created=1
    services_touched=1
    network_restart || return 1
    caddy_started=1
    cdn_restart_caddy || return 1
    confirmed=1
)

cdn_set() (
    case ${1:-} in
    "" | guide)
        [[ $# -le 1 ]] || { warn "用法: sb cdn guide"; return 1; }
        load cdn-guide.sh
        cdn_wizard
        return $?
        ;;
    export | check | test | remove)
        load cdn-guide.sh
        "cdn_$1" "${@:2}"
        return $?
        ;;
    esac
    local domain= protocol=vless email= accepted= arg
    local args=()
    for arg in "$@"; do
        case $arg in
        --yes) accepted=1 ;;
        --*) warn "未知参数: $arg"; return 1 ;;
        *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"
    if [[ ${1:-} == status ]]; then
        [[ $# -ge 2 && $# -le 3 && ! $accepted ]] || { warn "用法: sb cdn status <domain> [IP]"; return 1; }
        cdn_status "${2,,}" "${3:-}"
        return $?
    fi
    [[ $# -le 3 ]] || { warn "用法: sb cdn [domain] [vless|vmess|trojan] [email] [--yes]"; return 1; }
    domain=${1,,}; protocol=${2:-vless}; protocol=${protocol,,}; email=${3:-}
    if [[ ! $domain ]]; then
        read -r -p '请输入已解析到本机的 CF 域名: ' domain || return 1
        domain=${domain,,}
    fi
    cdn_valid_domain "$domain" || { warn "请输入有效域名，不包含协议、端口、路径或通配符。"; return 1; }
    case $protocol in
    vless) protocol=VLESS ;;
    vmess) protocol=VMess ;;
    trojan) protocol=Trojan ;;
    *) warn "CF CDN 仅支持本功能的 VLESS/VMess/Trojan WebSocket，不支持 REALITY、TUIC、Hysteria2、AnyTLS 或裸 TCP。"; return 1 ;;
    esac
    [[ ! $email ]] || cdn_valid_email "$email" || { warn "ACME 联系邮箱格式无效。"; return 1; }
    command -v curl >/dev/null || { warn "需要 curl 验证证书和 CDN 链路，请先安装后重试。"; return 1; }
    [[ $is_systemd || $is_openrc ]] || { warn "需要 systemd 或 OpenRC 管理服务。"; return 1; }
    [[ ${is_http_port:-80} == 80 && ${is_https_port:-443} == 443 ]] ||
        { warn "CDN 要求使用 TCP 80/443；不会自动修改现有非标准 Caddy 端口。"; return 1; }
    if [[ $is_caddy ]]; then
        [[ -f $is_caddyfile && ! -L $is_caddyfile ]] &&
            grep -Fxq "import $is_caddy_conf/*.conf" "$is_caddyfile" ||
            { warn "现有 Caddyfile 不是脚本管理的配置，不会自动修改。"; return 1; }
    else
        [[ ! -e $is_caddy_bin && ! -e $is_caddyfile ]] ||
            { warn "检测到未纳管的 Caddy，请先人工检查，避免覆盖。"; return 1; }
        [[ ! $(is_port_used 80) && ! $(is_port_used 443) ]] ||
            { warn "TCP 80/443 已占用，不会终止现有服务或随机改用其他端口。"; return 1; }
    fi
    cdn_is_managed "$domain" &&
        { warn "该域名已有 CDN 节点，请使用: sb cdn status $domain"; return 1; }
    cdn_dns_ready "$domain" || return 1
    get_uuid
    local uuid=$tmp_uuid
    [[ $uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
        { warn "生成随机凭据失败。"; return 1; }
    # 联系地址不是邮箱开户；仅使用用户提供的域名，避免冒用第三方邮箱。
    [[ $email ]] || email="acme-${uuid%%-*}@$domain"
    cdn_valid_email "$email" || { warn "生成的邮箱过长，请显式提供有效的 ACME 联系邮箱。"; return 1; }
    get_uuid
    local path="/$tmp_uuid"
    [[ $path =~ ^/[0-9a-fA-F-]{36}$ ]] || return 1
    get_port
    local port=$tmp_port
    [[ $port =~ ^[0-9]+$ && $port -ge 445 && $port -le 65535 ]] || return 1
    msg "将新增 $protocol-WS-TLS 节点（不转换或删除旧节点），反代仅监听本机随机端口。"
    msg "ACME 联系地址: $email（自动生成的地址不代表已创建真实邮箱）。"
    msg "请确认：CF A/AAAA 指向本机、开启橙云和 WebSockets、SSL/TLS 使用 Full (strict)。"
    msg "放行 TCP 80/443；/.well-known/acme-challenge/* 不得被强制 HTTPS、WAF 或身份验证拦截。"
    msg "将安装/复用 Caddy、申请并自动续期 Let's Encrypt 证书、重启 Caddy 和 sing-box，现有连接可能短暂中断。"
    msg "申请证书需接受 CA 服务条款，域名将进入公开证书透明度日志；此功能不会修改 CF 账户、DNS 或防火墙。"
    msg "Cloudflare 自助协议限制 VPN 或类似代理用途，请确认适用条款：https://www.cloudflare.com/terms/"
    if [[ ! $accepted ]]; then
        read -r -p '确认继续？输入 yes: ' arg || return 1
        [[ $arg == yes ]] || { msg "已取消。"; return 1; }
    fi
    load network.sh
    cdn_apply "$domain" "$protocol" "$email" "$uuid" "$path" "$port" || return 1
    msg "配置已应用，正在等待源站证书（最多约 2 分钟）；这还不代表 CDN 已就绪。"
    local attempt
    for ((attempt = 0; attempt < 12; attempt++)); do
        cdn_probe "$domain" "$path" origin && break
        sleep 5
    done
    # 子进程内安装 Caddy 后，父进程同样需要知道站点已被纳管。
    is_caddy=1
    local is_config_file="$protocol-WS-TLS-$domain.json"
    info "$protocol-WS-TLS-$domain.json" || return 1
    cdn_status "$domain"
)
