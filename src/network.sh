network_restart() {
    if [[ $is_systemd ]]; then
        systemctl restart "$is_core" || return 1
        # Type=simple 可能在绑定端口前返回成功，稍后确认进程未因启动错误退出。
        sleep 1
        systemctl is-active --quiet "$is_core"
    elif [[ $is_openrc ]]; then
        rc-service "$is_core" restart || return 1
        sleep 1
        rc-service "$is_core" status
    else
        warn "未找到 systemd 或 OpenRC，无法应用网络配置。"
        return 1
    fi
}

# 主配置和节点配置共用事务；校验时替换目标文件，避免重复加载同一入站。
network_apply() (
    local target=$1 config=$2 operation=${3:-update} candidate backup="${1}.network.bak"
    local lock="${is_config_json}.network.lock" file found=
    local check_args=()
    if [[ $target != "$is_config_json" && ${target%/*} != "$is_conf_dir" ]]; then
        err "只允许修改主配置或节点目录中的配置。"
        return 1
    fi
    case $operation in
    update) [[ -f $target ]] || { err "找不到配置文件: $target"; return 1; } ;;
    create)
        [[ ${target%/*} == "$is_conf_dir" && $target == *.json ]] ||
            { err "新节点必须位于 conf 目录中。"; return 1; }
        [[ ! -e $target && ! -L $target ]] ||
            { err "节点已存在，不会覆盖: $target；请更换端口或使用 change。"; return 1; }
        ;;
    *) err "未知网络配置操作: $operation"; return 1 ;;
    esac
    mkdir "$lock" 2>/dev/null || { err "其他网络配置操作正在执行，请稍后重试。"; return 1; }
    candidate=$(mktemp "${target}.network.XXXXXX") || { rmdir "$lock"; return 1; }
    trap 'rm -f -- "$candidate"; rmdir -- "$lock"' EXIT
    if [[ $operation == update ]]; then
        cp -p "$target" "$candidate" || return 1
    fi
    printf '%s\n' "$config" >"$candidate" || return 1
    if [[ $target == "$is_config_json" ]]; then
        check_args=(-c "$candidate" -C "$is_conf_dir")
    else
        check_args=(-c "$is_config_json")
        for file in "$is_conf_dir"/*.json; do
            [[ -f $file ]] || continue
            if [[ $file == "$target" ]]; then
                [[ $operation != create ]] || { err "节点已存在，创建已中止。"; return 1; }
                check_args+=(-c "$candidate")
                found=1
            else
                check_args+=(-c "$file")
            fi
        done
        if [[ $operation == create ]]; then
            check_args+=(-c "$candidate")
        else
            [[ $found ]] || { err "节点必须是 conf 目录中的 JSON 文件。"; return 1; }
        fi
    fi
    if ! "$is_core_bin" check "${check_args[@]}"; then
        err "配置校验失败，原配置未修改。"
        return 1
    fi
    if [[ $operation == create ]]; then
        # 同目录硬链接提供原子且不覆盖已有文件的创建语义。
        ln -T "$candidate" "$target" || { err "无法创建节点，目标可能已存在。"; return 1; }
        rm -f -- "$candidate"
    else
        cp -p "$target" "$backup" && mv -f "$candidate" "$target" || return 1
    fi
    if ! network_restart; then
        if [[ $operation == create ]]; then
            if rm -f -- "$target"; then
                warn "重启失败，已撤销新节点，正在尝试恢复原服务。"
                network_restart || warn "服务仍未恢复，请检查 sing-box 日志。"
            else
                warn "无法撤销新节点，请检查: $target"
            fi
        elif cp -p "$backup" "$candidate" && mv -f "$candidate" "$target"; then
            warn "重启失败，已恢复原配置，正在尝试恢复服务。"
            network_restart || warn "服务仍未恢复，请检查 sing-box 日志。"
        else
            warn "自动恢复失败，请使用备份恢复: $backup"
        fi
        return 1
    fi
)
