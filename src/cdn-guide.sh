cdn_node_file() {
    local domain=${1,,} file found=
    cdn_valid_domain "$domain" && cdn_is_managed "$domain" ||
        { warn "未找到此域名的 CDN 节点: $domain"; return 1; }
    for file in "$is_conf_dir"/*-WS-TLS-"$domain".json; do
        [[ -f $file && ! -L $file ]] || continue
        [[ ! $found ]] || { warn "同域名存在多个节点，请先人工检查。"; return 1; }
        jq -e --arg domain "$domain" '.inbounds[0] |
            (.type == "vless" or .type == "vmess" or .type == "trojan") and
            .listen == "127.0.0.1" and .transport.type == "ws" and
            .transport.headers.host == $domain' "$file" >/dev/null || return 1
        found=$file
    done
    [[ $found ]] || { warn "缺少 CDN 入站文件。"; return 1; }
    printf '%s\n' "$found"
}

cdn_address() {
    local address=$1 hex first second
    if [[ $address == \[* ]]; then
        [[ $address == *\] ]] || return 1
        address=${address:1:${#address}-2}
    fi
    load ingress.sh
    if [[ $address == *:* ]]; then
        ingress_valid_ip ipv6 "$address" || return 1
        hex=$(ingress_ipv6_hex "$address") || return 1
        [[ $hex != 00000000000000000000000000000001 && $hex != f[cd]* ]] || return 1
    else
        ingress_valid_ip ipv4 "$address" || return 1
        IFS=. read -r first second _ <<<"$address"
        [[ $first -ne 0 && $first -ne 10 && $first -ne 127 && $first -lt 224 &&
           ! ( $first -eq 100 && $second -ge 64 && $second -le 127 ) &&
           ! ( $first -eq 198 && ( $second -eq 18 || $second -eq 19 ) ) &&
           ! ( $first -eq 169 && $second -eq 254 ) &&
           ! ( $first -eq 172 && $second -ge 16 && $second -le 31 ) &&
           ! ( $first -eq 192 && $second -eq 168 ) ]] || return 1
    fi
    printf '%s\n' "$address"
}

# CFST 的 IP 是第一列；只读取前 10 个去重后的候选，不按 TCP 排名承诺实际速度。
cdn_addresses() {
    local arg line field address csv= header= count=0 seen=$'\n'
    local values=()
    while (($#)); do
        case $1 in
        --csv)
            [[ $# -ge 2 && ! $csv && -f $2 ]] ||
                { warn "--csv 需要一个当前机器可读的 CSV 文件。"; return 1; }
            csv=$2; shift 2
            ;;
        --*) warn "未知参数: $1"; return 1 ;;
        *)
            arg=${1//,/ }
            read -r -a values <<<"$arg"
            for address in "${values[@]}"; do
                address=$(cdn_address "$address") ||
                    { warn "请输入公网 IPv4/IPv6 地址，不要填写域名或端口。"; return 1; }
                [[ $seen != *$'\n'"$address"$'\n'* ]] || continue
                ((count < 10)) || { warn "一次最多填写 10 个候选 IP。"; return 1; }
                printf '%s\n' "$address"; seen+="$address"$'\n'; count=$((count + 1))
            done
            shift
            ;;
        esac
    done
    if [[ $csv ]]; then
        while IFS= read -r line || [[ $line ]]; do
            line=${line%$'\r'}
            line=${line#$'\xef\xbb\xbf'}
            field=${line%%,*}; field=${field#\"}; field=${field%\"}
            if [[ ! $header ]]; then
                case $field in
                "IP 地址" | "IP Address" | IP | ip) header=1; continue ;;
                *) warn "CSV 第一列应为 IP 地址 / IP。"; return 1 ;;
                esac
            fi
            [[ $line ]] || continue
            ((count < 10)) || break
            address=$(cdn_address "$field") || { warn "CSV 包含无效 IP: $field"; return 1; }
            [[ $seen != *$'\n'"$address"$'\n'* ]] || continue
            printf '%s\n' "$address"; seen+="$address"$'\n'; count=$((count + 1))
        done <"$csv"
        [[ $header && $count -gt 0 ]] || { warn "CSV 没有可用候选 IP。"; return 1; }
    fi
}

cdn_link() {
    local file=$1 domain=$2 address=$3 authority=$3 protocol json
    protocol=$(jq -er '.inbounds[0].type' "$file") || return 1
    if [[ $protocol == vmess ]]; then
        json=$(jq -c --arg domain "$domain" --arg address "$address" '.inbounds[0] |
            {v:"2",ps:("CF-"+$address),add:$address,port:"443",id:.users[0].uuid,
             aid:"0",net:"ws",type:"none",tls:"tls",sni:$domain,host:$domain,path:.transport.path}' "$file") || return 1
        printf 'vmess://%s\n' "$(printf '%s' "$json" | base64 -w 0)"
    else
        [[ $address != *:* ]] || authority="[$address]"
        jq -r --arg domain "$domain" --arg address "$authority" '.inbounds[0] |
            "\(.type)://\((.users[0].uuid // .users[0].password)|@uri)@\($address):443?encryption=none&security=tls&sni=\($domain)&type=ws&host=\($domain)&path=\(.transport.path|@uri)#\(("CF-"+$domain)|@uri)"' "$file"
    fi
}

cdn_export() {
    local domain=${1,,} file addresses address
    [[ $domain ]] || { warn "用法: sb cdn export <domain> [IP...] [--csv file]"; return 1; }
    shift
    file=$(cdn_node_file "$domain") || return 1
    addresses=$(cdn_addresses "$@") || return 1
    [[ $addresses ]] || addresses=$domain
    msg "链接含访问凭据，请勿公开。只替换连接地址，保留 SNI、Host、路径和凭据；导出不代表已通过客户端测速。" >&2
    while IFS= read -r address; do
        cdn_link "$file" "$domain" "$address" || return 1
    done <<<"$addresses"
}

cdn_check() (
    local domain=${1,,} addresses address resolved temp metrics http verify tcp tls first curl_exit failed=0
    local options=()
    cdn_valid_domain "$domain" || { warn "用法: sb cdn check <domain> [IP...] [--csv file]"; return 1; }
    shift
    addresses=$(cdn_addresses "$@") || return 1
    [[ $addresses ]] || addresses=$domain
    command -v curl >/dev/null || { warn "需要 curl 执行 HTTPS 检查。"; return 1; }
    temp=$(mktemp -d) || return 1
    trap 'rm -f -- "$temp/body" "$temp/headers" "$temp/error"; rmdir "$temp"' EXIT
    msg "检查位置是当前机器，不是客户端线路。--noproxy 不会绕过 TUN；请在实际使用网络另外验证。"
    while IFS= read -r address; do
        options=()
        if [[ $address != "$domain" ]]; then
            resolved=$address
            [[ $address != *:* ]] || resolved="[$address]"
            options=(--resolve "$domain:443:$resolved")
        fi
        if metrics=$(curl -q --noproxy '*' --http1.1 --proto '=https' --silent --show-error \
            --connect-timeout 5 --max-time 8 "${options[@]}" --dump-header "$temp/headers" \
            --output "$temp/body" --write-out '%{http_code}|%{ssl_verify_result}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}' \
            "https://$domain/cdn-cgi/trace" 2>"$temp/error"); then
            curl_exit=0
        else
            curl_exit=$?
        fi
        IFS='|' read -r http verify tcp tls first <<<"$metrics"
        if [[ $curl_exit == 0 && $http == 200 && $verify == 0 ]] &&
            grep -Fxq "h=$domain" "$temp/body" &&
            grep -Eiq '^server: cloudflare' "$temp/headers" &&
            grep -Eq '^colo=[A-Z0-9]+' "$temp/body"; then
            msg "$address：CF 边缘 TLS 通过，TLS 完成 ${tls}s，首字节 ${first}s。"
            grep -E '^(loc|colo)=' "$temp/body"
        else
            failed=2
            warn "$address：检查未通过（curl=$curl_exit，HTTP=${http:-000}）。"
            if [[ $curl_exit != 0 ]]; then
                msg "连接或 TLS 未完成；不能仅凭超时判定 TCP 不通，也不能把 verify=0 当作证书已通过。"
            else
                msg "请检查橙云、CF 边缘证书和 WAF。/cdn-cgi/trace 必须返回该域名的 CF 信息。"
            fi
            msg "若同一 IP 的公共域名正常而此域名反复失败，请换自有域名/网络做对照，不要关闭证书验证。"
        fi
    done <<<"$addresses"
    msg "此检查只到 CF 边缘，不验证回源、WebSocket、代理认证或速度；未配置源站时首页可能返回 525/526。"
    return "$failed"
)

cdn_client_config() {
    local file=$1 domain=$2 address=$3 port=$4 modern=false
    local major=${is_core_ver%%.*} minor=${is_core_ver#*.}
    minor=${minor%%.*}
    if (( ${major:-0} > 1 || (${major:-0} == 1 && ${minor:-0} >= 12) )); then modern=true; fi
    jq --arg domain "$domain" --arg address "$address" --argjson port "$port" --argjson modern "$modern" '
        .inbounds[0] as $node |
        {log:{level:"warn"},
         dns:{servers:[(if $modern then {type:"local",tag:"local"} else {address:"local",tag:"local"} end)]},
         inbounds:[{type:"socks",tag:"cdn-test",listen:"127.0.0.1",listen_port:$port}],
         outbounds:[({type:$node.type,tag:"proxy",server:$address,server_port:443,
             tls:{enabled:true,server_name:$domain},transport:$node.transport} +
             (if $node.type == "trojan" then {password:$node.users[0].password}
              elif $node.type == "vmess" then {uuid:$node.users[0].uuid,security:"auto"}
              else {uuid:$node.users[0].uuid} end))],
         route:({final:"proxy"} + if $modern then {default_domain_resolver:"local"} else {} end)}' "$file"
}

cdn_test() (
    local domain=${1,,} address=${2:-} file temp pid= port metrics http bytes verify seconds speed exit_ip
    [[ $# -ge 1 && $# -le 2 ]] || { warn "用法: sb cdn test <domain> [IP]"; return 1; }
    file=$(cdn_node_file "$domain") || return 1
    if [[ $address ]]; then
        address=$(cdn_address "$address") || { warn "请输入公网 IP。"; return 1; }
    else
        address=$domain
    fi
    command -v curl >/dev/null || { warn "代理测试需要 curl。"; return 1; }
    msg "测试从当前机器发起，将下载 1 MiB；不是大陆客户端测速，不会改变节点配置。"
    umask 077
    temp=$(mktemp -d) || return 1
    cleanup_cdn_test() {
        local result=$?
        if [[ $pid ]]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
        rm -f -- "$temp/client.json" "$temp/client.log" "$temp/trace"
        rmdir "$temp"
        return "$result"
    }
    trap cleanup_cdn_test EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    get_port
    port=$tmp_port
    cdn_client_config "$file" "$domain" "$address" "$port" >"$temp/client.json" || return 1
    "$is_core_bin" check -c "$temp/client.json" || return 1
    "$is_core_bin" run -c "$temp/client.json" >"$temp/client.log" 2>&1 &
    pid=$!
    sleep 1
    kill -0 "$pid" 2>/dev/null || { warn "临时客户端启动失败。"; tail -5 "$temp/client.log"; return 2; }
    if ! curl -q --fail --silent --show-error --noproxy 'localhost,127.0.0.1' \
        --proxy "socks5h://127.0.0.1:$port" --connect-timeout 15 --max-time 30 \
        --output "$temp/trace" https://www.cloudflare.com/cdn-cgi/trace; then
        warn "实际代理请求失败；WebSocket 101 并不代表认证和转发已成功。"
        return 2
    fi
    exit_ip=$(sed -n 's/^ip=//p' "$temp/trace" | tr -d '\r')
    cdn_address "$exit_ip" >/dev/null || { warn "测试响应缺少有效出口 IP。"; return 2; }
    msg "实际代理访问通过，出口 IP：$exit_ip"
    if ! metrics=$(curl -q --fail --silent --show-error --noproxy 'localhost,127.0.0.1' \
        --proxy "socks5h://127.0.0.1:$port" --connect-timeout 15 --max-time 45 \
        --output /dev/null --write-out '%{http_code}|%{size_download}|%{ssl_verify_result}|%{time_total}|%{speed_download}' \
        'https://speed.cloudflare.com/__down?bytes=1048576'); then
        warn "小文件下载未完成，不能把连接成功称为提速。"
        return 2
    fi
    IFS='|' read -r http bytes verify seconds speed <<<"$metrics"
    [[ $http == 200 && $bytes == 1048576 && $verify == 0 ]] ||
        { warn "下载结果不完整或 TLS 校验未通过。"; return 2; }
    msg "1 MiB 下载完成：${seconds}s，${speed} B/s。单次小文件结果不代表长期速度或加速保证。"
)

cdn_remove() (
    local domain=${1,,} accepted=${2:-} file stage lock="${is_config_json}.network.lock"
    local target ready= touched= reply result
    local targets=() moved=()
    [[ $# -ge 1 && $# -le 2 && ( ! $accepted || $accepted == --yes ) ]] ||
        { warn "用法: sb cdn remove <domain> [--yes]"; return 1; }
    file=$(cdn_node_file "$domain") || return 1
    targets=("$file" "$is_caddy_conf/$domain.conf" "$is_caddy_conf/$domain.conf.add")
    msg "将删除 $domain 的 CDN 入站、Caddy 站点和已导出链接，不保留兼容路由；其他域名与独立 REALITY 不受影响。"
    if [[ ! $accepted ]]; then
        read -r -p '确认删除？输入 yes: ' reply || return 1
        [[ ${reply,,} == yes ]] || { msg "已取消删除。"; return 1; }
    fi
    load network.sh
    mkdir "$lock" 2>/dev/null || { warn "其他网络配置操作正在执行。"; return 1; }
    stage=$(mktemp -d "$is_conf_dir/.cdn-remove.XXXXXX") || { rmdir "$lock"; return 1; }
    cleanup_cdn_remove() {
        result=$?
        if [[ ! $ready ]]; then
            for target in "${moved[@]}"; do
                mv -- "$stage/${target##*/}" "$target" ||
                    { warn "恢复失败，文件保留在 $stage"; rmdir "$lock"; return 1; }
            done
            if [[ $touched ]]; then
                network_restart || warn "sing-box 恢复失败，请检查服务。"
                cdn_restart_caddy || warn "Caddy 恢复失败，请检查服务。"
            fi
        else
            for target in "${moved[@]}"; do rm -f -- "$stage/${target##*/}"; done
            rm -f -- "${is_core_dir:-${is_conf_dir%/*}}/cdn-links/$domain.txt"
        fi
        rmdir "$stage" "$lock"
        return "$result"
    }
    trap cleanup_cdn_remove EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for target in "${targets[@]}"; do
        [[ -e $target ]] || continue
        [[ ! -L $target ]] || { warn "不处理符号链接配置。"; return 1; }
        mv -- "$target" "$stage/${target##*/}" || return 1
        moved+=("$target")
    done
    "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" || return 1
    "$is_caddy_bin" validate --config "$is_caddyfile" --adapter caddyfile || return 1
    touched=1
    network_restart && cdn_restart_caddy || return 1
    ready=1
    msg "已删除旧 CDN：$domain（未保留兼容配置）。"
)

cdn_other_domains() {
    local excluded=$1 file domain
    for file in "$is_caddy_conf"/*.conf.add; do
        [[ -f $file ]] || continue
        domain=${file##*/}; domain=${domain%.conf.add}
        [[ $domain != "$excluded" ]] || continue
        cdn_node_file "$domain" >/dev/null 2>&1 && printf '%s\n' "$domain"
    done
    return 0
}

cdn_wizard() (
    local domain= protocol=vless reply input addresses= primary file links result=0 choice index
    local is_dont_show_info=1
    local address_args=() old_domains=()
    msg "CF CDN 引导配置"
    msg "协议可选，随机邮箱/凭据/路径自动生成；随机邮箱只是 ACME 联系地址，不是可收信的邮箱。"
    msg "Cloudflare 自助协议限制 VPN/类似代理用途，请先确认适用条款：https://www.cloudflare.com/terms/"
    msg "[1/5] 域名准备"
    msg "A/AAAA 指向本机，开启橙云、WebSockets、Full (strict)，放行 TCP 80/443。"
    msg "ACME 验证路径不得被强制 HTTPS、WAF 或 Access 拦截。输入 q 可退出。"
    while :; do
        read -r -p "域名${domain:+（回车重试 $domain）}: " input || return 1
        [[ $input != q ]] || return 1
        [[ ! $input ]] || domain=$input
        domain=${domain#"${domain%%[![:space:]]*}"}
        domain=${domain%"${domain##*[![:space:]]}"}
        domain=${domain,,}; domain=${domain#https://}; domain=${domain#http://}; domain=${domain%/}
        if ! cdn_valid_domain "$domain"; then
            warn "域名格式不正确。可粘贴 https://node.example.com/，不要带端口、其他路径或参数。"
            continue
        fi
        if cdn_check "$domain"; then break; fi
        msg "当前检查未通过。请修正设置后回车重试，或换一个自有域名；这不是自动判定域名被屏蔽。"
    done
    msg "[2/5] 协议与优选入口"
    if cdn_is_managed "$domain"; then
        msg "该域名已有节点，将复用现有配置，不重新生成凭据或申请证书。"
    else
        while :; do
            msg "1) VLESS（默认）  2) VMess  3) Trojan；均使用 WebSocket + TLS。"
            read -r -p '选择协议 [1]: ' reply || return 1
            case ${reply:-1} in
            1) protocol=vless; break ;;
            2) protocol=vmess; break ;;
            3) protocol=trojan; break ;;
            *) warn "请输入 1、2 或 3。" ;;
            esac
        done
    fi
    msg "优选 IP 应在实际客户端网络测得，测速时绕过原 SG/TUN。此处不在 VPS 上冒充大陆测速。"
    while :; do
        read -r -p '粘贴 IP（空格/逗号分隔），或 @当前机器的CSV路径；回车先用域名: ' input || return 1
        address_args=()
        if [[ $input == @* ]]; then
            address_args=(--csv "${input#@}")
        elif [[ $input ]]; then
            address_args=("$input")
        fi
        if ! addresses=$(cdn_addresses "${address_args[@]}"); then
            msg "CSV 必须已上传到当前机器，也可直接粘贴 IP。"
            continue
        fi
        [[ ! $addresses ]] && break
        if cdn_check "$domain" "${address_args[@]}"; then break; fi
        msg "有候选未通过，请只填写通过的 IP，或回车先使用域名。"
    done
    primary=${addresses%%$'\n'*}
    msg "[3/5] 配置证书和节点"
    if cdn_is_managed "$domain"; then
        cdn_status "$domain" || return $?
    else
        msg "将创建 $protocol 节点，自动生成 ACME 联系邮箱并申请公开证书、自动续期。"
        msg "会安装/复用 Caddy 并重启服务，已有连接可能短暂中断；暂不删除任何旧节点。"
        read -r -p '确认创建？输入 yes: ' reply || return 1
        [[ ${reply,,} == yes ]] || { msg "已取消。"; return 1; }
        if cdn_set "$domain" "$protocol" --yes; then
            :
        else
            result=$?
            msg "配置未完全就绪；修正提示问题后再次运行 sb cdn，不需要重复创建。旧节点未删除。"
            return "$result"
        fi
    fi
    msg "[4/5] 验证与导出"
    cdn_status "$domain" "$primary" || return $?
    read -r -p '执行本机实际代理与 1 MiB 下载测试？[Y/n]: ' reply || return 1
    if [[ ${reply,,} != n && ${reply,,} != no ]]; then
        if cdn_test "$domain" "$primary"; then :; else result=$?; fi
    else
        msg "已跳过本机代理测试，不能视为客户端验收通过。"
    fi
    links=$(cdn_export "$domain" "${address_args[@]}") || return 1
    file="${is_core_dir:-${is_conf_dir%/*}}/cdn-links/$domain.txt"
    [[ ! -L ${file%/*} && ! -L $file ]] || { warn "导出路径不能是符号链接。"; return 1; }
    umask 077
    mkdir -p "${file%/*}" && chmod 700 "${file%/*}" || return 1
    printf '%s\n' "$links" >"$file" && chmod 600 "$file" || return 1
    msg "$links"
    msg "链接已保存（含凭据，请勿公开）：$file"
    msg "导入客户端后，在实际网络验证访问和下载；SNI/Host 保持 $domain，不能关闭证书校验。"
    msg "[5/5] 清理旧 CDN（可选）"
    readarray -t old_domains < <(cdn_other_domains "$domain")
    if [[ ${#old_domains[@]} -gt 0 && $result == 0 ]]; then
        read -r -p '已在实际客户端验证新节点可用？[y/N]: ' reply || return 1
        if [[ ${reply,,} == y || ${reply,,} == yes ]]; then
            for index in "${!old_domains[@]}"; do msg "$((index + 1))) ${old_domains[$index]}"; done
            while :; do
                read -r -p '选择要删除的旧 CDN 编号（回车不删除）: ' choice || return 1
                [[ $choice ]] || break
                if [[ $choice =~ ^[1-9][0-9]?$ ]] && ((choice <= ${#old_domains[@]})); then
                    cdn_remove "${old_domains[$((choice - 1))]}" || return 1
                    break
                fi
                warn "请输入列表中的编号。"
            done
        fi
    elif [[ $result != 0 ]]; then
        msg "本机实际代理测试未通过，暂不清理旧节点。"
    else
        msg "没有其他受本脚本管理的 CDN 节点。"
    fi
    msg "引导结束。优选 IP 和 CF 接入不保证提速；独立 REALITY、其他网站和 CF DNS 未修改。"
    return "$result"
)
