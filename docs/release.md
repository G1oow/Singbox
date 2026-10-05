# 构建、发布与更新

## 自动化流程

仓库：<https://github.com/G1oow/Singbox>。

| 事件 | 测试 | 构建包 | 稳定版 Release |
| --- | --- | --- | --- |
| PR 创建、更新、重开、转为可评审 | 是 | Actions Artifact | 否 |
| 推送或合并到 `main` | 是 | Actions Artifact | 是 |
| 在 `main` 手动运行 workflow | 是 | Actions Artifact | 是 |

PR 运行只有读取权限，不使用 `pull_request_target`。发布权限仅授予主分支的发布 job。
同一个 PR 更新后会取消旧运行；较旧的主分支提交不会覆盖较新提交的稳定版。
私有仓库的 Actions 和 Release 仍然私有，workflow 不会更改仓库可见性。

流程使用 sing-box 1.11.4、1.12.12、1.13.14 的 Linux 内核校验配置，并运行出口策略、下载及打包回归测试。
成功后生成：

- `code.tar.gz`：脚本安装包，根目录包含 `install.sh`、`sing-box.sh`、`src/` 和文档。
- `sha256sums.txt`：用于检查下载文件完整性。

版本格式为 `v<主版本>.<次版本>.<Actions 运行编号>`，例如 `v1.19.1`。
版本会写入发布包内的 `sing-box.sh`，但不会回写源码、循环触发提交。
重跑同一次 workflow 会复用版本；Actions Artifact 保留 14 天，稳定版 Release 长期保留。

## 私有仓库的认证

本仓库当前为私有仓库，匿名 `wget` 无法下载其 Release。
在 VPS 安装 [GitHub CLI](https://cli.github.com/)，然后**以运行 sing-box 管理脚本的用户（通常是 root）**登录：

```bash
gh auth login --hostname github.com
gh repo view G1oow/Singbox
```

若使用 Fine-grained token，仅选择此仓库并授予 `Contents: Read`；
也可由部署环境安全注入 `GH_TOKEN`。不要把令牌写入脚本、仓库、Release 或命令历史。
Git SSH 登录与 Release API 登录不同，仅配置 SSH Key 不足以下载私有 Release。
以后仓库若由所有者改为公开，未登录 gh 时可以自动使用 wget，不需修改脚本。

## 新 VPS 安装

认证后下载发布包：

```bash
workdir=$(mktemp -d)
gh release download --repo G1oow/Singbox \
  --pattern code.tar.gz --pattern sha256sums.txt --dir "$workdir"
cd "$workdir"
sha256sum -c sha256sums.txt
tar -xzf code.tar.gz
bash install.sh --local-install
```

安装会修改系统服务和代理配置，仅在准备安装的 VPS 上执行。
下载核心仍使用 SagerNet 官方仓库，不使用本仓库编译的内核。

## 已使用本分支的 VPS

完成认证后：

```bash
sing-box update sh
sing-box version
sing-box egress status
```

更新仅覆盖脚本目录，不修改 `/etc/sing-box/config.json` 或 `conf/`，
不会主动重启 sing-box 服务，因此出口策略保持不变。
命令会读取本仓库最新稳定版，拒绝版本号与目标 Release 不一致的包。

## 从原上游脚本迁移

旧脚本仍然指向原上游，首次不能靠旧版 `update sh` 切换仓库。
请先备份 `/etc/sing-box/sh`，并确认两个命令入口仍指向该目录中的 `sing-box.sh`。
认证后下载并校验本仓库发布包，再只替换脚本目录：

```bash
workdir=$(mktemp -d)
gh release download --repo G1oow/Singbox \
  --pattern code.tar.gz --pattern sha256sums.txt --dir "$workdir"
cd "$workdir"
sha256sum -c sha256sums.txt
tar -xzf code.tar.gz -C /etc/sing-box/sh
chmod +x /etc/sing-box/sh/sing-box.sh
sing-box version
sing-box update sh
```

不要使用 `reinstall` 迁移：该命令会卸载后重装，而不是仅更新脚本。

## 查看构建包

PR 页面 → Checks → **测试、构建与发布** → Artifacts → `singbox-v...`。
下载并解压 Artifact ZIP 后，即可得到 `code.tar.gz` 和校验和文件。
PR 构建包用于测试，不会成为 `update sh` 的更新来源。

本地构建无需安装额外构建依赖，使用 Bash、GNU tar、gzip、sha256sum：

```bash
bash tests/release.sh
bash scripts/package.sh v1.19.0 /tmp/singbox-package
```
