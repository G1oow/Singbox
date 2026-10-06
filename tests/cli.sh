#!/bin/bash
set -eo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# 跳过系统探测，但执行真实入口的参数保存与 init 的最终分派。
run_entry() (
    set -- "$@"
    source <(sed '/^\. \/etc\/sing-box\/sh\/src\/init.sh$/,$d' "$repo_dir/sing-box.sh")
    load() {
        . "$repo_dir/src/$1"
        add() { printf '<%s>\n' "$@"; }
    }
    source <(sed -n '/^load core.sh$/,$p' "$repo_dir/src/init.sh")
)
actual=$(run_entry add socks 30001 'test user' 'two words *')
expected=$(printf '<%s>\n' socks 30001 'test user' 'two words *')
[[ $actual == "$expected" ]] || { echo "失败：入口拆分了含空格或通配符的参数"; exit 1; }
echo "通过：CLI 参数中的空格和通配符原样保留"

source "$repo_dir/src/core.sh"
capture_args() { printf '<%s>\n' "$@"; }
is_core_bin=capture_args
actual=$(main bin check -c '/tmp/config with spaces.json' '*')
[[ $actual == "$(printf '<%s>\n' check -c '/tmp/config with spaces.json' '*')" ]]
change() { capture_args "$@"; }
actual=$(main change Socks-30001.json passwd 'two  words *')
[[ $actual == "$(printf '<%s>\n' Socks-30001.json passwd 'two  words *')" ]]
update() { [[ $1 == sh ]]; }
main U
echo "通过：内核透传与 change 保留参数，U 仍只更新脚本"
