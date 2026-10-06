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

如果仓库为私有，匿名 `wget` 无法下载其 Release。
在 VPS 安装 [GitHub CLI](https://cli.github.com/)，然后**以运行 sing-box 管理脚本的用户（通常是 root）**登录：

```bash
gh auth login --hostname github.com
gh repo view G1oow/Singbox
```

若使用 Fine-grained token，仅选择此仓库并授予 `Contents: Read`；
也可由部署环境安全注入 `GH_TOKEN`。不要把令牌写入脚本、仓库、Release 或命令历史。
Git SSH 登录与 Release API 登录不同，仅配置 SSH Key 不足以下载私有 Release。
以后仓库若由所有者改为公开，未登录 gh 时可以自动使用 wget，不需修改脚本。

## 一键安装（新 VPS）

**仅在新 VPS 上以 root 执行。** 引导入口需要 Bash、tar、gzip、sha256sum，以及 curl 或已认证的 GitHub CLI。
命令会在当前目录保存 `get.sh`；请使用空工作目录，避免覆盖自己的同名文件。
安装器会安装必要依赖并配置系统服务。已有安装使用 `sb U`，不要重复安装。

### 公开仓库

```bash
curl -fsSLO https://raw.githubusercontent.com/G1oow/Singbox/main/get.sh && bash get.sh
```

### 私有仓库

先完成上面的 GitHub CLI 认证，再下载并运行同一个引导入口：

```bash
gh api repos/G1oow/Singbox/contents/get.sh -H 'Accept: application/vnd.github.raw+json' > get.sh && bash get.sh
```

`get.sh` 先确定稳定版标签，再从**同一个 Release**下载发布包和校验清单；
SHA256、归档路径、版本或解压检查失败时不会执行安装器。内部临时目录退出时自动清理，
下载的 `get.sh` 保留在当前目录，便于审阅或复用。整个流程不把访问令牌写入脚本或 URL。
引导脚本本身依赖 HTTPS 和仓库访问权限建立信任；SHA256 检查不等于发布者签名。

### 指定版本或本地内核

```bash
bash get.sh --help
bash get.sh --core-version v1.13.14
bash get.sh --core-file "/root/core archive.tar.gz"
```

指定脚本版本使用 `--release <实际存在的 Release 标签>`；`--core-version` 只指定内核版本。
本地内核请使用绝对路径，其来源和摘要需要自行确认。
短入口需先提交到远程 `main`，对应安装器需完成 Release 发布；仅修改本地文件不会改变远程下载结果。

下载内核仍使用 SagerNet 官方仓库，不使用本仓库编译的内核：

- 所有下载保留 HTTPS 证书校验；证书错误应检查系统时间、CA 和网络，不使用跳过验证选项。
- 脚本和 jq 校验官方发布的 SHA256 清单；内核校验 GitHub 官方 Release 资产的 SHA256 元数据。
- 1.11.4 等旧内核没有资产摘要时会明确警告，仅保留 HTTPS 保护；建议使用提供摘要的新版。
- 临时目录使用 `mktemp -d` 原子创建；首次安装的配置目录仅 root 可访问，私钥权限为 `600`。
- 不再向 `/root/.bashrc` 重复追加 alias，`sb` 与 `sing-box` 使用命令符号链接。

## 已使用本分支的 VPS

完成认证后：

```bash
sb U
sb v
sb egress status
```

更新仅覆盖脚本目录，不修改 `/etc/sing-box/config.json` 或 `conf/`，
不会主动重启 sing-box 服务，因此出口策略保持不变。
`sb U` 等价于 `sing-box update sh`，其中 `U` 必须大写；`sb u` 默认更新内核。
更新会校验 SHA256、包内版本及脚本语法，在隔离目录解压后整体替换脚本目录；
替换失败时恢复旧脚本，不在原目录直接解压覆盖。更新锁用于拒绝并发更新。

### 更新内核或 Caddy

```bash
sb update core
sb update caddy
```

新二进制需通过摘要（旧内核例外）、版本及现有配置检查后才会替换；
备份分别保存在 `/etc/sing-box/bin/sing-box.update.bak` 和 `/usr/local/bin/caddy.update.bak`。
更新命令等待重启和运行状态确认；失败返回非零状态，恢复旧二进制并尝试恢复服务。
如果旧服务仍未恢复，脚本会提示查看日志，不会报告更新成功。

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

Shell 文件通过 `.gitattributes` 固定使用 LF 换行；发布回归测试会按原始字节拒绝 CRLF，
避免 Windows 上通过检查的脚本在 Linux VPS 上出现语法错误。
IPv4-only VPS 的回环代理与实际公网出口验证见[IPv4 实网测试](egress.md#ipv4-only-vps-实网验证)。
