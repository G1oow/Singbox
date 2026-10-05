#!/bin/bash
set -euo pipefail

version=${1:-}
output_dir=${2:-}
if [[ ! $version =~ ^v[0-9]+(\.[0-9]+){2,}$ || ! $output_dir ]]; then
    echo "用法: bash scripts/package.sh v1.19.1 /path/to/output" >&2
    exit 1
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
temp_dir=$(mktemp -d)
trap 'rm -f -- "$temp_dir/sing-box.sh"; rmdir -- "$temp_dir"' EXIT
cd -- "$repo_dir"

sed "s/^is_sh_ver=.*/is_sh_ver=$version/" sing-box.sh >"$temp_dir/sing-box.sh"
grep -Fxq "is_sh_ver=$version" "$temp_dir/sing-box.sh"
timestamp=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}

# 仅打包运行文件和文档，排除 .git、workflow、令牌及本地构建产物。
tar --sort=name --mtime="@$timestamp" --owner=0 --group=0 --numeric-owner \
    -cf - install.sh LICENSE README.md src/*.sh docs/*.md \
    -C "$temp_dir" sing-box.sh | gzip -n >"$output_dir/code.tar.gz"
(
    cd -- "$output_dir"
    sha256sum code.tar.gz >sha256sums.txt
)
echo "已构建 $version: $output_dir/code.tar.gz"
