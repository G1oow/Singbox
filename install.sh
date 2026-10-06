#!/bin/bash

author=233boy
# github=https://github.com/233boy/sing-box

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e ${red}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }
_cyan() { echo -e ${cyan}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_magenta() { echo -e ${magenta}$@${none}; }
_red_bg() { echo -e "\e[41m$@${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $@\n" && exit 1
}

warn() {
    echo -e "\n$is_warn $@\n"
}

# root
[[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT用户.${none}"

# apt-get, yum, zypper or apk
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu or Debian or CentOS or SUSE or Alpine)${none}."

# systemd or openrc
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
[[ ! $is_systemd && ! $is_openrc ]] && {
    err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}, 请安装 systemd 或确认 OpenRC 已启用."
}

# wget installed or none
is_wget=$(type -P wget)

# x64
case $(uname -m) in
amd64 | x86_64)
    is_arch=amd64
    ;;
*aarch64* | *armv8*)
    is_arch=arm64
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
# 脚本使用本仓库发布包；内核仍使用 SagerNet 官方发行版。
is_sh_repo=G1oow/Singbox
is_pkg="wget tar gzip bash ca-certificates"
command -v sha256sum &>/dev/null || is_pkg="$is_pkg coreutils"
# Alpine: gcompat provides glibc compatibility for prebuilt binaries
[[ $cmd =~ apk ]] && is_pkg="$is_pkg gcompat jq"
is_config_json=$is_core_dir/config.json
tmp_var_lists=(
    tmpcore
    tmpsh
    tmpjq
    is_core_ok
    is_sh_ok
    is_jq_ok
    is_pkg_ok
)

tmpdir=

# load bash script.
load() {
    . "$is_sh_dir/src/$1"
}

# 保留 HTTPS 证书校验，缺少 CA 时先修复系统依赖。
_wget() {
    [[ $proxy ]] && export https_proxy=$proxy
    wget -T 20 "$@"
}

# 安装器可以独立下载运行，因此加载发布包代码前自行校验其摘要和路径。
install_verify() {
    local archive=$1 manifest=$2 asset=$3 digest file expected= actual
    while read -r digest file; do
        [[ ${file#\*} == "$asset" ]] || continue
        [[ ! $expected && $digest =~ ^[[:xdigit:]]{64}$ ]] || return 1
        expected=${digest,,}
    done <"$manifest"
    actual=$(sha256sum "$archive") || return 1
    [[ $expected && ${actual%% *} == "$expected" ]]
}

install_unpack() {
    local archive=$1 destination=$2 entry listing
    listing=$(tar -tzf "$archive") || return 1
    while IFS= read -r entry; do
        case $entry in
        /* | .. | ../* | */../* | */..) return 1 ;;
        esac
    done <<<"$listing"
    listing=$(LC_ALL=C tar -tvzf "$archive") || return 1
    while IFS= read -r entry; do
        [[ $entry == [-d]* ]] || return 1
    done <<<"$listing"
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$destination"
}

install_cleanup() {
    local result=$? pid
    for pid in $(jobs -pr); do kill "$pid" 2>/dev/null || :; done
    wait 2>/dev/null || :
    [[ $tmpdir == "$install_temp_root"/singbox-install.* && -d $tmpdir && ! -L $tmpdir ]] &&
        rm -rf -- "$tmpdir"
    return "$result"
}

# print a mesage
msg() {
    case $1 in
    warn)
        local color=$yellow
        ;;
    err)
        local color=$red
        ;;
    ok)
        local color=$green
        ;;
    esac

    echo -e "${color}$(date +'%T')${none}) ${2}"
}

# show help msg
show_help() {
    echo -e "Usage: $0 [-f xxx | -l | -p xxx | -v xxx | -h]"
    echo -e "  -f, --core-file <path>          自定义 $is_core_name 文件路径, e.g., -f /root/$is_core-linux-amd64.tar.gz"
    echo -e "  -l, --local-install             本地获取安装脚本, 使用当前目录"
    echo -e "  -p, --proxy <addr>              使用代理下载, e.g., -p http://127.0.0.1:2333"
    echo -e "  -v, --core-version <ver>        自定义 $is_core_name 版本, e.g., -v v1.8.13"
    echo -e "  -h, --help                      显示此帮助界面\n"

    exit 0
}

# install dependent pkg
install_pkg() {
    cmd_not_found=
    for i in $*; do
        [[ ! $(type -P $i) ]] && cmd_not_found="$cmd_not_found,$i"
    done
    if [[ $cmd_not_found ]]; then
        pkg=$(echo $cmd_not_found | sed 's/,/ /g')
        msg warn "安装依赖包 >${pkg}"
        if [[ $cmd =~ apk ]]; then
            apk update &>/dev/null
            apk add $pkg &>/dev/null
        else
            $cmd install -y $pkg &>/dev/null
            if [[ $? != 0 ]]; then
                [[ $cmd =~ yum ]] && yum install epel-release -y &>/dev/null
                if [[ $cmd =~ zypper ]]; then
                    $cmd --non-interactive refresh &>/dev/null
                else
                    $cmd update -y &>/dev/null
                fi
                $cmd install -y $pkg &>/dev/null
            fi
        fi
        [[ $? == 0 ]] && >$is_pkg_ok
    else
        >$is_pkg_ok
    fi
}

# download file
download() {
    local link name tmpfile is_ok version base metadata authenticated=
    case $1 in
    core)
        metadata=https://api.github.com/repos/$is_core_repo/releases/latest
        [[ ! $is_core_ver ]] || metadata=https://api.github.com/repos/$is_core_repo/releases/tags/$is_core_ver
        _wget -t 3 -q "$metadata" -O "$tmpdir/core-release.json" || return 1
        version=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$tmpdir/core-release.json")
        [[ $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] || return 1
        printf '%s\n' "$version" >"$tmpdir/core.version" || return 1
        link="https://github.com/${is_core_repo}/releases/download/${version}/${is_core}-${version#v}-linux-${is_arch}.tar.gz"
        name=$is_core_name
        tmpfile=$tmpcore
        is_ok=$is_core_ok
        ;;
    sh)
        mkdir "$tmpdir/sh-download" || return 1
        if command -v gh &>/dev/null && GH_HOST=github.com gh auth status --hostname github.com &>/dev/null; then
            authenticated=1
            version=$(GH_HOST=github.com gh release view --repo "$is_sh_repo" --json tagName --jq .tagName) || return 1
        else
            metadata=$(_wget -t 3 -qO- "https://api.github.com/repos/$is_sh_repo/releases/latest") || return 1
            version=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<<"$metadata")
        fi
        [[ $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] || return 1
        printf '%s\n' "$version" >"$tmpdir/sh.version" || return 1
        base=https://github.com/$is_sh_repo/releases/download/$version
        if [[ $authenticated ]]; then
            GH_HOST=github.com gh release download "$version" --repo "$is_sh_repo" \
                --pattern code.tar.gz --pattern sha256sums.txt --dir "$tmpdir/sh-download" || return 1
        else
            _wget -t 3 -q "$base/code.tar.gz" -O "$tmpdir/sh-download/code.tar.gz" || return 1
            _wget -t 3 -q "$base/sha256sums.txt" -O "$tmpdir/sh-download/sha256sums.txt" || return 1
        fi
        install_verify "$tmpdir/sh-download/code.tar.gz" "$tmpdir/sh-download/sha256sums.txt" code.tar.gz ||
            { msg err "脚本发布包 SHA256 校验失败"; return 1; }
        mv -f "$tmpdir/sh-download/code.tar.gz" "$is_sh_ok"
        return
        ;;
    jq)
        link=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$is_arch
        name="jq"
        tmpfile=$tmpjq
        is_ok=$is_jq_ok
        ;;
    esac

    [[ $link ]] || return 1
    msg warn "下载 ${name} > ${link}"
    _wget -t 3 -q "$link" -O "$tmpfile" || return 1
    if [[ $1 == jq ]]; then
        _wget -t 3 -q https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt \
            -O "$tmpdir/jq.sha256" || return 1
        install_verify "$tmpfile" "$tmpdir/jq.sha256" "jq-linux-$is_arch" ||
            { msg err "jq SHA256 校验失败"; return 1; }
    fi
    mv -f "$tmpfile" "$is_ok"
}

# get server ip
get_ip() {
    ip=$(_wget -4 -t 1 -qO- https://one.one.one.one/cdn-cgi/trace | sed -n 's/^ip=//p')
    [[ $ip ]] || ip=$(_wget -6 -t 1 -qO- https://one.one.one.one/cdn-cgi/trace | sed -n 's/^ip=//p')
    [[ $ip ]]
}

# check background tasks status
check_status() {
    # dependent pkg install fail
    [[ ! -f $is_pkg_ok ]] && {
        msg err "安装依赖包失败"
        if [[ $cmd =~ apk ]]; then
            msg err "请尝试手动安装依赖包: apk update; apk add $is_pkg"
        else
            msg err "请尝试手动安装依赖包: $cmd update -y; $cmd install -y $is_pkg"
        fi
        is_fail=1
    }

    # download file status
    if [[ $is_wget ]]; then
        [[ ! -f $is_core_ok ]] && {
            msg err "下载 ${is_core_name} 失败"
            is_fail=1
        }
        [[ ! -f $is_sh_ok ]] && {
            msg err "下载 ${is_core_name} 脚本失败"
            msg err "私有仓库请先安装 GitHub CLI，并以当前用户执行 gh auth login --hostname github.com"
            is_fail=1
        }
        [[ ! -f $is_jq_ok ]] && {
            msg err "下载 jq 失败"
            is_fail=1
        }
    else
        [[ ! $is_fail ]] && {
            is_wget=1
            [[ ! $is_core_file ]] && download core &
            [[ ! $local_install ]] && download sh &
            [[ $jq_not_found ]] && download jq &
            get_ip
            wait
            check_status
        }
    fi

    # found fail status, remove tmp dir and exit.
    [[ $is_fail ]] && {
        exit_and_del_tmpdir
    }
}

# parameters check
pass_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -f | --core-file)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 /root/$is_core-linux-amd64.tar.gz]"
            } || [[ ! -f $2 ]] && {
                err "($2) 不是一个常规的文件."
            }
            is_core_file=$2
            shift 2
            ;;
        -l | --local-install)
            [[ ! -f ${PWD}/src/core.sh || ! -f ${PWD}/src/download.sh || ! -f ${PWD}/$is_core.sh ]] && {
                err "当前目录 (${PWD}) 非完整的脚本目录."
            }
            local_install=1
            shift 1
            ;;
        -p | --proxy)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 http://127.0.0.1:2333 or -p socks5://127.0.0.1:2333]"
            }
            proxy=$2
            shift 2
            ;;
        -v | --core-version)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 v1.8.13]"
            }
            is_core_ver=v${2//v/}
            [[ $is_core_ver =~ ^v[0-9]+(\.[0-9]+)+$ ]] || err "内核版本格式无效。"
            shift 2
            ;;
        -h | --help)
            show_help
            ;;
        *)
            err "($1) 为未知参数，请使用 --help 查看帮助。"
            ;;
        esac
    done
    [[ $is_core_ver && $is_core_file ]] && {
        err "无法同时自定义 ${is_core_name} 版本和 ${is_core_name} 文件."
    }
}

# exit and remove tmpdir
exit_and_del_tmpdir() {
    [[ ! $1 ]] && {
        msg err "哦豁.."
        msg err "安装过程出现错误..."
        echo -e "反馈问题) https://github.com/${is_sh_repo}/issues"
        echo
        exit 1
    }
    exit 0
}

# main
main() {

    # check old version
    [[ -e $is_sh_bin || -e $is_core_dir ]] && {
        err "检测到已有安装或配置目录。请使用 sb U 更新；不要重复安装或覆盖现有配置。"
    }

    # check parameters
    [[ $# -gt 0 ]] && pass_args "$@"
    umask 077
    install_temp_root=$(cd -- "${TMPDIR:-/tmp}" && pwd -P) || err "无法访问临时目录。"
    tmpdir=$(mktemp -d "$install_temp_root/singbox-install.XXXXXX") || err "无法创建安全临时目录。"
    trap install_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for i in "${tmp_var_lists[@]}"; do
        export "$i=$tmpdir/$i"
    done

    # show welcome msg
    clear
    echo
    echo "........... $is_core_name script by $author .........."
    echo

    # start installing...
    msg warn "开始安装..."
    [[ $is_core_ver ]] && msg warn "${is_core_name} 版本: ${yellow}$is_core_ver${none}"
    [[ $proxy ]] && msg warn "使用代理: ${yellow}$proxy${none}"
    # create tmpdir
    # if is_core_file, copy file
    [[ $is_core_file ]] && {
        cp -f "$is_core_file" "$is_core_ok" || exit_and_del_tmpdir
        msg warn "${yellow}${is_core_name} 文件使用 > $is_core_file${none}"
    }
    # local dir install sh script
    [[ $local_install ]] && {
        >$is_sh_ok
        msg warn "${yellow}本地获取安装脚本 > $PWD ${none}"
    }

    if [[ $is_systemd ]]; then
        timedatectl set-ntp true &>/dev/null
        [[ $? != 0 ]] && {
            is_ntp_on=1
        }
    fi

    # install dependent pkg
    if [[ $cmd =~ apk ]]; then
        # Alpine: force install full versions to replace BusyBox applets
        apk update &>/dev/null && apk add $is_pkg &>/dev/null
        [[ $? == 0 ]] && >$is_pkg_ok
    else
        install_pkg $is_pkg
    fi
    [[ -f $is_pkg_ok ]] || exit_and_del_tmpdir
    is_wget=$(type -P wget)

    # jq
    if [[ $(type -P jq) ]]; then
        >$is_jq_ok
    else
        jq_not_found=1
    fi
    # if wget installed. download core, sh, jq, get ip
    [[ $is_wget ]] && {
        [[ ! $is_core_file ]] && download core &
        [[ ! $local_install ]] && download sh &
        [[ $jq_not_found ]] && download jq &
        get_ip
    }

    # waiting for background tasks is done
    wait

    # check background tasks status
    check_status

    # get server ip.
    [[ ! $ip ]] && {
        msg err "获取服务器 IP 失败."
        exit_and_del_tmpdir
    }

    # 先在隔离目录验证脚本与内核，再写入安装路径。
    mkdir "$tmpdir/source" "$tmpdir/core" || exit_and_del_tmpdir
    if [[ $local_install ]]; then
        cp -R -- "$PWD/install.sh" "$PWD/sing-box.sh" "$PWD/src" "$tmpdir/source/" || exit_and_del_tmpdir
        for i in LICENSE README.md docs; do
            [[ ! -e $PWD/$i ]] || cp -R -- "$PWD/$i" "$tmpdir/source/" || exit_and_del_tmpdir
        done
    else
        install_unpack "$is_sh_ok" "$tmpdir/source" || exit_and_del_tmpdir
        grep -Fxq "is_sh_ver=$(cat "$tmpdir/sh.version")" "$tmpdir/source/sing-box.sh" || exit_and_del_tmpdir
    fi
    for i in "$tmpdir/source/"*.sh "$tmpdir/source/src/"*.sh; do
        bash -n "$i" || exit_and_del_tmpdir
    done
    # jq 便携版先完成摘要校验，随后才允许执行。
    jq_bin=$(type -P jq)
    if [[ $jq_not_found ]]; then
        chmod 755 "$is_jq_ok" || exit_and_del_tmpdir
        jq_bin=$is_jq_ok
        "$jq_bin" --version >/dev/null || exit_and_del_tmpdir
    fi
    jq() { "$jq_bin" "$@"; }
    . "$tmpdir/source/src/download.sh" || exit_and_del_tmpdir
    declare -F download_verify_core download_unpack >/dev/null ||
        err "发布包缺少安全下载功能，请使用包含本次改动的新 Release。"
    if [[ ! $is_core_file ]]; then
        is_core_ver=$(cat "$tmpdir/core.version") || exit_and_del_tmpdir
        download_verify_core "$is_core_ok" "$tmpdir/core-release.json" "$is_core_ver" \
            "sing-box-${is_core_ver#v}-linux-${is_arch}.tar.gz" || exit_and_del_tmpdir
    else
        warn "本地内核由你提供，请自行确认来源及摘要。"
    fi
    download_unpack "$is_core_ok" "$tmpdir/core" 1 || exit_and_del_tmpdir
    [[ -f $tmpdir/core/$is_core ]] || exit_and_del_tmpdir
    chmod 755 "$tmpdir/core/$is_core" || exit_and_del_tmpdir
    is_version_output=$("$tmpdir/core/$is_core" version) || exit_and_del_tmpdir
    is_downloaded_version=$(sed -n 's/^sing-box version //p' <<<"$is_version_output" | head -n 1)
    [[ $is_downloaded_version =~ ^[0-9]+(\.[0-9]+)+$ ]] || exit_and_del_tmpdir
    [[ ! $is_core_ver || ${is_core_ver#v} == "$is_downloaded_version" ]] || exit_and_del_tmpdir
    is_core_ver=$is_downloaded_version

    mkdir -p "$is_sh_dir" "$is_core_dir/bin" "$is_log_dir" "$is_conf_dir" || exit_and_del_tmpdir
    chmod 700 "$is_core_dir" "$is_conf_dir" || exit_and_del_tmpdir
    cp -R -- "$tmpdir/source/." "$is_sh_dir/" || exit_and_del_tmpdir
    cp -- "$tmpdir/core/$is_core" "$is_core_bin" || exit_and_del_tmpdir

    # 两个真实命令入口，不再重复修改 /root/.bashrc。
    ln -sf "$is_sh_dir/$is_core.sh" "$is_sh_bin" || exit_and_del_tmpdir
    ln -sf "$is_sh_dir/$is_core.sh" "${is_sh_bin/$is_core/sb}" || exit_and_del_tmpdir

    if [[ $jq_not_found ]]; then
        mv -f "$is_jq_ok" /usr/bin/jq || exit_and_del_tmpdir
        jq_bin=/usr/bin/jq
    fi
    chmod 755 "$is_core_bin" "$is_sh_bin" "${is_sh_bin/$is_core/sb}" || exit_and_del_tmpdir

    # show a tips msg
    msg ok "生成配置文件..."

    # create service
    load systemd.sh
    is_new_install=1
    install_service "$is_core" || exit_and_del_tmpdir

    load core.sh
    # create a reality config
    add reality || exit_and_del_tmpdir
    # wait for background tasks (e.g., OpenRC service start)
    wait
    "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" || exit_and_del_tmpdir
    download_restart core || exit_and_del_tmpdir
    # remove tmp dir and exit.
    exit_and_del_tmpdir ok
}

# start.
main "$@"
