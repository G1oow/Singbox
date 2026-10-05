# IPv4 / IPv6 出口策略

## 使用

安装本分支脚本后，以 root 执行：

```bash
sing-box egress ipv6        # IPv6 优先，IPv4 回退
sing-box egress ipv4        # IPv4 优先，IPv6 回退
sing-box egress ipv6-only   # 仅解析 IPv6，不支持 IPv6 的目标域名会失败
sing-box egress ipv4-only   # 仅解析 IPv4
sing-box egress auto        # 清除地址族偏好，恢复默认策略
sing-box egress status      # 查看当前策略，不修改配置
sing-box egress             # 交互选择
```

菜单入口：`sing-box` → **其他** → **设置出口策略**。
也接受内核策略名称 `prefer_ipv4`、`prefer_ipv6`、`ipv4_only`、`ipv6_only`。

## 作用范围

- 只修改 `/etc/sing-box/config.json` 中 `tag: "direct"`、`type: "direct"` 的默认出口。
- 不修改客户端连接地址、入站监听、系统网络设置、自定义出口或路由规则。
- 对服务器收到并解析的**目标域名**生效。客户端已解析好的 IP、直接访问的 IP 不会被转换到另一地址族；`only` 不是全局封禁另一地址族。
- 自定义路由若已提前解析域名，或将流量发往其他出口，应单独检查其策略。本命令不会覆盖它们。
- IPv6 优先需要 VPS 有可用的公网 IPv6 路由；目标网站也需提供 IPv6 地址。优先策略允许回退，实际出口不保证始终是指定地址族。
- IPv4 入站可以使用 IPv6 出口，反之亦然；二者不是同一个设置。

## DNS 与版本兼容

sing-box 1.12 及以上使用 `domain_resolver.strategy`，旧版本使用 `domain_strategy`。
未设置 DNS 时，脚本按需增加 `egress-local` 本地解析器；已有 DNS 则优先复用。

`sing-box dns ...` 更换 DNS 后保留出口策略并重新绑定解析器。
`sing-box dns none` 表示回到系统 DNS，不会清除出口策略。
`egress auto` 仅清除地址族偏好，保留解析器和其他设置；需要清除 DNS 定制时另执行 `sing-box dns none`。

修改前会使用当前内核执行完整配置校验（主配置及 `conf` 目录），校验失败不覆盖原文件。
修改成功后通过 systemd 或 OpenRC 重启服务，现有连接可能中断。
重启失败会恢复原配置并尝试恢复服务；若仍失败，查看日志排查。

上一次修改前的配置保存在 `/etc/sing-box/config.json.network.bak`，包含敏感配置，请勿公开。
`fix-config.json` 会重建主配置并清除出口策略，之后需要重新设置。

## 从此仓库安装

仓库：<https://github.com/G1oow/Singbox>。私有仓库需要先使用 GitHub CLI 认证，
一键安装命令及迁移步骤见 [构建、发布与更新](release.md)。已具备仓库读取权限时也可本地安装：

```bash
gh repo clone G1oow/Singbox
cd Singbox
bash install.sh --local-install
```

安装和 `sing-box update sh` 均使用本仓库的稳定版 Release。
已有上游安装需要先按迁移文档替换脚本，不能靠旧版更新命令自动切换仓库。
更新脚本不会清除出口策略；已有安装请先备份，不要直接重装。

## 本地验证

需要 Bash 和项目原有依赖 jq，不需要 root 或真实服务：

```bash
bash -n src/egress.sh src/dns.sh src/core.sh src/help.sh
bash tests/egress.sh
```

额外使用真实 sing-box 内核校验生成配置：

```bash
SING_BOX_BIN=/path/to/sing-box bash tests/egress.sh
```

测试使用临时配置和模拟的服务管理命令，不改 `/etc/sing-box`，不启动代理服务。
已使用 sing-box 1.11.4、1.12.12、1.13.14 的 Windows 内核执行配置校验。
源码测试与内核配置校验不能替代真实双栈 VPS 上的出口连通性测试。

配置依据：[Dial Fields](https://sing-box.sagernet.org/configuration/shared/dial/)。
