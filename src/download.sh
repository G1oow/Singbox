github_authenticated() {
    command -v gh &>/dev/null && GH_HOST=github.com gh auth status --hostname github.com &>/dev/null
}

get_latest_version() {
    case $1 in
    core)
        name=$is_core_name
        url="https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM"
        ;;
    sh)
        name="$is_core_name 脚本"
        url="https://api.github.com/repos/$is_sh_repo/releases/latest?v=$RANDOM"
        ;;
    caddy)
        name="Caddy"
        url="https://api.github.com/repos/$is_caddy_repo/releases/latest?v=$RANDOM"
        ;;
    esac
    if [[ $1 == sh ]] && github_authenticated; then
        latest_ver=$(GH_HOST=github.com gh release view --repo "$is_sh_repo" --json tagName --jq .tagName) || {
            err "获取脚本版本失败，请检查 GitHub 认证和仓库访问权限。"
            return 1
        }
    else
        latest_ver=$(_wget -qO- "$url" | grep tag_name | grep -E -o 'v([0-9.]+)')
    fi
    [[ ! $latest_ver ]] && {
        [[ $1 == sh ]] && warn "私有仓库需要 GitHub CLI：请以运行脚本的用户执行 gh auth login --hostname github.com"
        err "获取 ${name} 最新版本失败."
        return 1
    }
    [[ $1 == sh && ! $latest_ver =~ ^v[0-9]+(\.[0-9]+)+$ ]] && {
        err "无法识别脚本发布版本: $latest_ver"
        return 1
    }
    unset name url
}
download() {
    latest_ver=$2
    [[ ! $latest_ver ]] && { get_latest_version "$1" || return 1; }
    # tmp dir
    tmpdir=$(mktemp -d) || { err "无法创建下载临时目录。"; return 1; }
    case $1 in
    core)
        name=$is_core_name
        tmpfile=$tmpdir/$is_core.tar.gz
        link="https://github.com/${is_core_repo}/releases/download/${latest_ver}/${is_core}-${latest_ver:1}-linux-${is_arch}.tar.gz"
        download_file
        tar zxf $tmpfile --strip-components 1 -C $is_core_dir/bin
        chmod +x $is_core_bin
        ;;
    sh)
        name="$is_core_name 脚本"
        tmpfile=$tmpdir/sh.tar.gz
        link="https://github.com/${is_sh_repo}/releases/download/${latest_ver}/code.tar.gz"
        if github_authenticated; then
            if ! GH_HOST=github.com gh release download "$latest_ver" --repo "$is_sh_repo" --pattern code.tar.gz --output "$tmpfile"; then
                rm -f "$tmpfile"
                rmdir "$tmpdir"
                err "下载脚本失败，请检查 GitHub 认证和仓库访问权限。"
                return 1
            fi
        else
            download_file
        fi
        if ! tar -xOf "$tmpfile" sing-box.sh | grep -Fx "is_sh_ver=$latest_ver" >/dev/null; then
            rm -f "$tmpfile"
            rmdir "$tmpdir"
            err "发布包中的脚本版本与目标版本不一致，未执行更新。"
            return 1
        fi
        tar zxf "$tmpfile" -C "$is_sh_dir" || { err "解压脚本失败。"; return 1; }
        chmod +x "$is_sh_bin" "${is_sh_bin/$is_core/sb}" || return 1
        rm -f "$tmpfile"
        rmdir "$tmpdir"
        unset latest_ver
        return
        ;;
    caddy)
        name="Caddy"
        tmpfile=$tmpdir/caddy.tar.gz
        # https://github.com/caddyserver/caddy/releases/download/v2.6.4/caddy_2.6.4_linux_amd64.tar.gz
        link="https://github.com/${is_caddy_repo}/releases/download/${latest_ver}/caddy_${latest_ver:1}_linux_${is_arch}.tar.gz"
        download_file
        tar zxf $tmpfile -C $tmpdir
        cp -f $tmpdir/caddy $is_caddy_bin
        chmod +x $is_caddy_bin
        ;;
    esac
    rm -rf $tmpdir
    unset latest_ver
}
download_file() {
    if ! _wget -t 5 -c $link -O $tmpfile; then
        rm -rf $tmpdir
        [[ $name == "$is_core_name 脚本" ]] && warn "私有仓库需要 GitHub CLI：请以运行脚本的用户执行 gh auth login --hostname github.com"
        err "\n下载 ${name} 失败.\n"
    fi
}
