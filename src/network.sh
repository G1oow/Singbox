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
    local target=$1 config=$2 operation=${3:-update} source=${4:-$1} candidate backup
    local lock="${is_config_json}.network.lock" file found= committed= confirmed=
    local check_args=()
    if [[ $target != "$is_config_json" && ( ${target%/*} != "$is_conf_dir" || $target != *.json ) ]]; then
        err "只允许修改主配置或节点目录中的配置。"
        return 1
    fi
    [[ ! -L $target && ! -L $source ]] || { err "不修改符号链接配置。"; return 1; }
    if [[ $operation == replace ]]; then
        [[ ${source%/*} == "$is_conf_dir" && $source == *.json && -f $source ]] ||
            { err "原节点必须位于 conf 目录中。"; return 1; }
        [[ $target != "$source" ]] || operation=update
    fi
    case $operation in
    update) [[ -f $target ]] || { err "找不到配置文件: $target"; return 1; } ;;
    create | replace)
        [[ ${target%/*} == "$is_conf_dir" && $target == *.json ]] ||
            { err "新节点必须位于 conf 目录中。"; return 1; }
        [[ ! -e $target && ! -L $target ]] ||
            { err "节点已存在，不会覆盖: $target；请更换端口或使用 change。"; return 1; }
        ;;
    *) err "未知网络配置操作: $operation"; return 1 ;;
    esac
    mkdir "$lock" 2>/dev/null || { err "其他网络配置操作正在执行，请稍后重试。"; return 1; }
    if [[ $# -ge 5 && $(cat "$source") != "$5" ]]; then
        rmdir "$lock"
        err "节点已被其他操作修改，请重新读取后再试。"
        return 1
    fi
    backup=$source.network.bak
    [[ ! -L $backup ]] || { rmdir "$lock"; err "备份路径不能是符号链接。"; return 1; }
    candidate=$(mktemp "${target}.network.XXXXXX") || { rmdir "$lock"; return 1; }
    cleanup_network() {
        local result=$?
        if [[ $committed && ! $confirmed ]]; then
            if [[ $operation == create ]]; then
                rm -f -- "$target" || { warn "无法撤销新节点: $target"; return 1; }
            else
                if ! cp -p "$backup" "$candidate" || ! mv -f "$candidate" "$source"; then
                    warn "自动恢复失败，请使用备份恢复: $backup"
                    rm -f -- "$candidate"
                    rmdir "$lock"
                    return 1
                fi
                [[ $operation != replace ]] || rm -f -- "$target"
            fi
            warn "应用失败，已恢复原配置，正在尝试恢复服务。"
            network_restart || warn "服务仍未恢复，请检查 sing-box 日志。"
        fi
        rm -f -- "$candidate"
        rmdir -- "$lock"
        return "$result"
    }
    trap cleanup_network EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ $operation == create ]] || cp -p "$source" "$candidate" || return 1
    chmod 600 "$candidate" || return 1
    printf '%s\n' "$config" >"$candidate" || return 1
    if [[ $target == "$is_config_json" ]]; then
        check_args=(-c "$candidate" -C "$is_conf_dir")
    else
        check_args=(-c "$is_config_json")
        for file in "$is_conf_dir"/*.json; do
            [[ -f $file ]] || continue
            if [[ $file == "$source" ]]; then
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
    if [[ $operation != create ]]; then
        cp -p "$source" "$backup" && chmod 600 "$backup" || return 1
    fi
    if [[ $operation == create || $operation == replace ]]; then
        # 同目录硬链接提供原子且不覆盖已有文件的创建语义。
        ln -T "$candidate" "$target" || { err "无法创建节点，目标可能已存在。"; return 1; }
        if [[ $operation == replace ]] && ! rm -f -- "$source"; then
            rm -f -- "$target"
            return 1
        fi
    else
        mv -f "$candidate" "$target" || return 1
    fi
    # 新建使用硬链接，回滚前先解除临时链接，避免覆盖备份时改到已提交文件。
    rm -f -- "$candidate"
    committed=1
    network_restart || return 1
    confirmed=1
)
