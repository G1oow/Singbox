network_restart() {
    if [[ $is_systemd ]]; then
        systemctl restart "$is_core" && systemctl is-active --quiet "$is_core"
    elif [[ $is_openrc ]]; then
        rc-service "$is_core" restart && rc-service "$is_core" status
    else
        warn "未找到 systemd 或 OpenRC，无法应用网络配置。"
        return 1
    fi
}

# 主配置和节点配置共用事务；校验时替换目标文件，避免重复加载同一入站。
network_apply() (
    local target=$1 config=$2 candidate backup="${1}.network.bak"
    local lock="${is_config_json}.network.lock" file found=
    local check_args=()
    [[ -f $target ]] || { err "找不到配置文件: $target"; return 1; }
    if [[ $target != "$is_config_json" && ${target%/*} != "$is_conf_dir" ]]; then
        err "只允许修改主配置或节点目录中的配置。"
        return 1
    fi
    mkdir "$lock" 2>/dev/null || { err "其他网络配置操作正在执行，请稍后重试。"; return 1; }
    candidate=$(mktemp "${target}.network.XXXXXX") || { rmdir "$lock"; return 1; }
    trap 'rm -f -- "$candidate"; rmdir -- "$lock"' EXIT
    cp -p "$target" "$candidate" && printf '%s\n' "$config" >"$candidate" || return 1
    if [[ $target == "$is_config_json" ]]; then
        check_args=(-c "$candidate" -C "$is_conf_dir")
    else
        check_args=(-c "$is_config_json")
        for file in "$is_conf_dir"/*.json; do
            [[ -f $file ]] || continue
            if [[ $file == "$target" ]]; then
                check_args+=(-c "$candidate")
                found=1
            else
                check_args+=(-c "$file")
            fi
        done
        [[ $found ]] || { err "节点必须是 conf 目录中的 JSON 文件。"; return 1; }
    fi
    if ! "$is_core_bin" check "${check_args[@]}"; then
        err "配置校验失败，原配置未修改。"
        return 1
    fi
    cp -p "$target" "$backup" && mv -f "$candidate" "$target" || return 1
    if ! network_restart; then
        if cp -p "$backup" "$candidate" && mv -f "$candidate" "$target"; then
            warn "重启失败，已恢复原配置，正在尝试恢复服务。"
            network_restart || warn "服务仍未恢复，请检查 sing-box 日志。"
        else
            warn "自动恢复失败，请使用备份恢复: $backup"
        fi
        return 1
    fi
)
