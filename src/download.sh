github_authenticated() {
    command -v gh &>/dev/null && GH_HOST=github.com gh auth status --hostname github.com &>/dev/null
}

get_latest_version() {
    local kind=$1 repo version
    case $kind in
    core) repo=$is_core_repo ;;
    sh) repo=$is_sh_repo ;;
    caddy) repo=$is_caddy_repo ;;
    *) err "未知下载类型: $kind"; return 1 ;;
    esac
    if [[ $kind == sh ]] && github_authenticated; then
        version=$(GH_HOST=github.com gh release view --repo "$repo" --json tagName --jq .tagName) || {
            err "获取脚本版本失败，请检查 GitHub 认证和仓库访问权限。"
            return 1
        }
    else
        version=$(_wget -T 20 -t 3 -qO- "https://api.github.com/repos/$repo/releases/latest" |
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    fi
    [[ $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] || {
        err "无法获取或识别 $kind 发布版本，请检查网络及仓库访问权限。"
        return 1
    }
    latest_ver=$version
}

download_fetch() {
    _wget -T 20 -t 3 -q "$1" -O "$2" || { err "下载失败: $1"; return 1; }
}

# 仅校验指定资产，不执行清单中其他路径，拒绝缺失或重复条目。
download_verify() {
    local archive=$1 manifest=$2 asset=$3 digest file expected= actual
    while read -r digest file; do
        file=${file#\*}
        [[ $file == "$asset" ]] || continue
        [[ ! $expected && $digest =~ ^[[:xdigit:]]{64}$ ]] ||
            { err "校验清单无效: $asset"; return 1; }
        expected=${digest,,}
    done <"$manifest"
    [[ $expected ]] || { err "校验清单缺少 $asset"; return 1; }
    actual=$(sha256sum "$archive") || return 1
    [[ ${actual%% *} == "$expected" ]] || { err "SHA256 校验失败: $asset"; return 1; }
}

download_unpack() {
    local archive=$1 destination=$2 strip=${3:-0} entry listing
    listing=$(tar -tzf "$archive") || { err "发布包损坏，无法读取。"; return 1; }
    while IFS= read -r entry; do
        case $entry in
        /* | .. | ../* | */../* | */..) err "发布包包含不安全路径。"; return 1 ;;
        esac
    done <<<"$listing"
    # 发布资产不需要符号链接、硬链接或设备文件。
    listing=$(LC_ALL=C tar -tvzf "$archive") || return 1
    while IFS= read -r entry; do
        [[ $entry == [-d]* ]] || { err "发布包包含不支持的文件类型。"; return 1; }
    done <<<"$listing"
    tar -xzf "$archive" --no-same-owner --no-same-permissions \
        --strip-components="$strip" -C "$destination" ||
        { err "解压发布包失败。"; return 1; }
}

download_verify_core() {
    local archive=$1 metadata=$2 version=$3 asset=$4 digest actual
    digest=$(jq -er --arg version "$version" --arg asset "$asset" '
        if .tag_name != $version then error("版本不一致") else
            [.assets[] | select(.name == $asset)] |
            if length != 1 then error("找不到唯一资产") else .[0].digest // "legacy" end
        end' "$metadata") || { err "无法读取官方内核校验信息。"; return 1; }
    if [[ $digest == legacy ]]; then
        warn "此官方旧版未提供 SHA256 摘要，仅通过 HTTPS 下载；建议升级到提供摘要的版本。"
        return 0
    fi
    [[ $digest =~ ^sha256:[[:xdigit:]]{64}$ ]] || { err "官方内核摘要无效。"; return 1; }
    actual=$(sha256sum "$archive") || return 1
    [[ ${actual%% *} == "${digest#sha256:}" ]] || { err "官方内核 SHA256 校验失败。"; return 1; }
}

download_restart() {
    local kind=$1 service=$is_core
    [[ $kind != caddy ]] || service=caddy
    if [[ $is_systemd ]]; then
        systemctl restart "$service" || return 1
        sleep 1
        systemctl is-active --quiet "$service"
    elif [[ $is_openrc ]]; then
        rc-service "$service" restart || return 1
        sleep 1
        rc-service "$service" status
    else
        err "找不到 systemd 或 OpenRC，不能确认服务运行状态。"
        return 1
    fi
}

# 子 shell 隔离下载状态；临时文件与目标同盘，先验证再替换。
download() (
    set -o pipefail
    local kind=$1 version=${2:-} restart=${3:-} parent stage lock target asset repo base
    local archive backup had_old= old_moved= installed= authenticated= binary actual
    local binary_replaced= restart_confirmed=
    [[ $version ]] || { get_latest_version "$kind" || return 1; version=$latest_ver; }
    [[ $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] || { err "发布版本格式无效。"; return 1; }
    case $kind in
    sh) target=$is_sh_dir; repo=$is_sh_repo; asset=code.tar.gz ;;
    core)
        target=$is_core_bin; repo=$is_core_repo
        asset="sing-box-${version#v}-linux-${is_arch}.tar.gz"
        ;;
    caddy)
        target=$is_caddy_bin; repo=$is_caddy_repo
        asset="caddy_${version#v}_linux_${is_arch}.tar.gz"
        ;;
    *) err "未知下载类型: $kind"; return 1 ;;
    esac
    parent=$(cd -- "$(dirname -- "$target")" && pwd -P) || return 1
    target=$parent/${target##*/}
    lock=$target.update.lock
    mkdir "$lock" 2>/dev/null || { err "其他更新正在执行，请稍后重试。"; return 1; }
    stage=$(mktemp -d "$parent/.singbox-update.XXXXXX") || { rmdir "$lock"; return 1; }
    cleanup_download() {
        local result=$?
        if [[ $old_moved && ! $installed ]]; then
            if ! mv -T -- "$stage/previous" "$target"; then
                warn "恢复旧脚本失败，备份保留在 $stage/previous"
                rmdir "$lock"
                return 1
            fi
        fi
        if [[ $binary_replaced && ! $restart_confirmed && $had_old ]]; then
            if cp -p -- "$backup" "$stage/restore" && mv -fT -- "$stage/restore" "$target"; then
                warn "更新失败或中断，已恢复旧内核。"
                [[ $restart != restart ]] || download_restart "$kind" || warn "旧服务仍未恢复，请检查日志。"
            else
                warn "自动恢复失败，请使用备份: $backup"
                result=1
            fi
        fi
        # stage 由已解析的目标父目录下 mktemp 原子创建，禁止清理其他路径。
        [[ $stage == "$parent"/.singbox-update.* && -d $stage && ! -L $stage ]] && rm -rf -- "$stage"
        rmdir "$lock"
        return "$result"
    }
    trap cleanup_download EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    archive=$stage/$asset
    base=https://github.com/$repo/releases/download/$version
    mkdir "$stage/source" || return 1
    if [[ $kind == sh ]] && github_authenticated; then
        authenticated=1
        GH_HOST=github.com gh release download "$version" --repo "$repo" \
            --pattern code.tar.gz --pattern sha256sums.txt --dir "$stage" ||
            { err "下载脚本失败，请检查 GitHub 认证和仓库访问权限。"; return 1; }
    else
        download_fetch "$base/$asset" "$archive" || return 1
    fi
    case $kind in
    sh)
        [[ $authenticated ]] || download_fetch "$base/sha256sums.txt" "$stage/sha256sums.txt" || return 1
        download_verify "$archive" "$stage/sha256sums.txt" "$asset" || return 1
        download_unpack "$archive" "$stage/source" || return 1
        for binary in install.sh sing-box.sh src/init.sh src/core.sh src/download.sh; do
            [[ -f $stage/source/$binary ]] || { err "发布包缺少 $binary"; return 1; }
        done
        grep -Fxq "is_sh_ver=$version" "$stage/source/sing-box.sh" ||
            { err "发布包中的脚本版本与目标版本不一致，未执行更新。"; return 1; }
        for binary in "$stage/source/"*.sh "$stage/source/src/"*.sh; do
            bash -n "$binary" || { err "脚本语法校验失败。"; return 1; }
        done
        chmod +x "$stage/source/sing-box.sh" || return 1
        if [[ -e $target || -L $target ]]; then
            mv -T -- "$target" "$stage/previous" || return 1
            old_moved=1
        fi
        mv -T -- "$stage/source" "$target" || { err "替换脚本失败，正在恢复旧版。"; return 1; }
        installed=1
        ;;
    core | caddy)
        if [[ $kind == core ]]; then
            download_fetch "https://api.github.com/repos/$repo/releases/tags/$version" "$stage/core.json" || return 1
            download_verify_core "$archive" "$stage/core.json" "$version" "$asset" || return 1
            download_unpack "$archive" "$stage/source" 1 || return 1
            binary=$stage/source/sing-box
        else
            download_fetch "$base/caddy_${version#v}_checksums.txt" "$stage/checksums.txt" || return 1
            download_verify "$archive" "$stage/checksums.txt" "$asset" || return 1
            download_unpack "$archive" "$stage/source" || return 1
            binary=$stage/source/caddy
        fi
        [[ -f $binary ]] && chmod 755 "$binary" || { err "发布包缺少可执行内核。"; return 1; }
        actual=$("$binary" version) || { err "新内核无法运行。"; return 1; }
        if [[ $kind == core ]]; then
            [[ $actual == "sing-box version ${version#v}"$'\n'* || $actual == "sing-box version ${version#v}" ]] ||
                { err "内核版本与目标版本不一致。"; return 1; }
            "$binary" check -c "$is_config_json" -C "$is_conf_dir" ||
                { err "新内核不兼容现有配置，旧版本未修改。"; return 1; }
        else
            [[ $actual == "$version "* || $actual == "$version" ]] ||
                { err "Caddy 版本与目标版本不一致。"; return 1; }
            [[ ! -f $is_caddyfile ]] || "$binary" validate --config "$is_caddyfile" --adapter caddyfile || return 1
        fi
        backup=$target.update.bak
        if [[ -f $target ]]; then
            cp -p -- "$target" "$stage/backup" && mv -fT -- "$stage/backup" "$backup" || return 1
            had_old=1
        fi
        mv -fT -- "$binary" "$target" || return 1
        binary_replaced=1
        if [[ $restart == restart ]] && ! download_restart "$kind"; then
            warn "新服务启动失败，请检查日志。"
            return 1
        fi
        restart_confirmed=1
        ;;
    esac
)
