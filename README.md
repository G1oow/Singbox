# 介绍

最好用的 sing-box 一键安装脚本 & 管理脚本

# 特点

- 快速安装
- 无敌好用
- 零学习成本
- 自动化 TLS
- 简化所有流程
- 兼容 sing-box 命令
- 强大的快捷参数
- 支持所有常用协议
- 一键添加 VLESS-REALITY (默认)
- 一键添加 TUIC
- 一键添加 Trojan
- 一键添加 Hysteria2
- 一键添加 AnyTLS
- 一键添加 Shadowsocks 2022
- 一键添加 VMess-(TCP/HTTP/QUIC)
- 一键添加 VMess-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 VLESS-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 Trojan-(WS/H2/HTTPUpgrade)-TLS
- 引导式新增 CF CDN 节点（协议可选、邮箱自动生成、优选 IP/CSV 导出、验证与旧节点清理）
- 一键启用 BBR
- 一键更改伪装网站
- 一键更改 (端口/UUID/密码/域名/路径/加密方式/SNI/等...)
- 还有更多...

# 一键安装

仓库公开后，可使用下面的命令安装最新稳定版，**无需 GitHub CLI 或 Token**。
如果仓库为私有，请使用[认证安装方式](docs/release.md#私有仓库)。

**仅用于新 VPS，以 root 执行。** 系统需已安装 Bash、curl、tar、gzip 和 sha256sum。
安装会配置代理服务；已有安装请勿重复运行，原上游脚本请先按[迁移说明](docs/release.md#从原上游脚本迁移)切换。
请在空工作目录中执行，避免覆盖已有的 `get.sh`。

```bash
curl -fsSLO https://raw.githubusercontent.com/G1oow/Singbox/main/get.sh && bash get.sh
```

引导脚本会锁定同一个 Release，下载并校验 SHA256、检查归档路径和包内版本，再从独立目录安装。
下载、校验或解压失败不会执行安装器；内部临时目录自动清理，`get.sh` 保留供审阅或复用。
新短入口需先提交到远程 `main`，对应安装器需完成 Release 发布；仅修改本地文件不会使远程命令生效。

所有下载保留 HTTPS 证书校验。内核使用官方资产摘要；没有摘要的旧版会明确警告，而不是声称已通过 SHA256 校验。
详见[下载校验与版本选择](docs/release.md#指定版本或本地内核)。

# 快速开始

安装完成后，运行以下命令打开管理菜单：

```bash
sb
```

`sb` 与 `sing-box` 等价，原有长命令继续可用：

```bash
sb help        # 查看命令
sb U           # 更新脚本，注意大写 U
sb s           # 查看运行状态
sb a reality   # 添加 REALITY 节点
sb cdn         # 打开 CF CDN 引导，协议可选、邮箱自动生成
```

`sb u` 默认更新内核，不等同于 `sb U`。更新脚本会先校验再替换；内核更新失败会尝试恢复旧版。
更多说明：[IPv4 / IPv6 入口策略](docs/ingress.md) · [出口策略](docs/egress.md) · [安装、迁移与自动发布](docs/release.md)。

## CF CDN 边缘接入

```bash
sb cdn                                    # 分步引导，小白推荐
sb cdn node.example.com vmess              # 快速创建，自动生成 ACME 联系地址
sb cdn check node.example.com              # 预检 CF 边缘 TLS
sb cdn export node.example.com --csv /root/tcp-result.csv
sb cdn test node.example.com 104.16.0.1     # 示例 IP；从当前机器测试代理及 1 MiB 下载
sb cdn remove old.example.com              # 确认后删除指定旧 CDN
```

先在 CF 将专用域名解析到 VPS，开启橙云、WebSockets 和 **Full (strict)**，放行 TCP 80/443，
确保 ACME HTTP 验证路径不被强制 HTTPS、WAF 或 Access 拦截。脚本会确认后安装或复用 Caddy，
创建新的节点并导出链接；向导最后可选择清理旧 CDN，不保留兼容路由，不触及独立 REALITY。

随机联系地址不代表创建真实邮箱，向导不询问邮箱。普通 CDN 不支持直接代理 REALITY、
TUIC、Hysteria2 等协议。CSV 须已在当前机器，VPS 检查不能代替大陆客户端测速。
CF 接入不保证提速，且其自助协议限制 VPN/类似代理用途；前置条件和限制见 [CF CDN 使用说明](docs/cdn.md)。

# 设计理念

设计理念为：**高效率，超快速，极易用**

脚本基于作者的自身使用需求，以 **多配置同时运行** 为核心设计

并且专门优化了，添加、更改、查看、删除、这四项常用功能

你只需要一条命令即可完成 添加、更改、查看、删除、等操作

例如，添加一个配置仅需不到 1 秒！瞬间完成添加！其他操作亦是如此！

脚本的参数非常高效率并且超级易用，请掌握参数的使用

# 文档

本分支：[安装与更新](docs/release.md) · [入口策略](docs/ingress.md) · [出口策略](docs/egress.md)

原作者教程：[安装及使用](https://233boy.com/sing-box/sing-box-script/)

# 帮助

使用：`sb help`（等价于 `sing-box help`），以当前安装版本输出为准。

```text
sing-box script by 233boy
Usage: sing-box [options]... [args]...

基本:
   v, version                                      显示当前版本
   ip                                              返回当前主机的 IP
   pbk                                             同等于 sing-box generate reality-keypair
   get-port                                        返回一个可用的端口
   ss2022                                          返回一个可用于 Shadowsocks 2022 的密码

一般:
   a, add [protocol] [args... | auto]              添加配置
   c, change [name] [option] [args... | auto]      更改配置
   d, del [name]                                   删除配置**
   i, info [name]                                  查看配置
   qr [name] [ipv4|ipv6]                           二维码信息，可选入口地址族
   url [name] [ipv4|ipv6]                          URL 信息，可选入口地址族
   log                                             查看日志
更改:
   full [name] [...]                               更改多个参数
   id [name] [uuid | auto]                         更改 UUID
   host [name] [domain]                            更改域名
   port [name] [port | auto]                       更改端口
   path [name] [path | auto]                       更改路径
   passwd [name] [password | auto]                 更改密码
   key [name] [Private key | auto] [Public key]    更改密钥
   method [name] [method | auto]                   更改加密方式
   sni [name] [ ip | domain]                       更改 serverName
   new [name] [...]                                更改协议
   web [name] [domain]                             更改伪装网站

进阶:
   dns [...]                                       设置 DNS
   egress [ipv4|ipv6|ipv4-only|ipv6-only|auto|status] 设置默认 direct 出口策略
   ingress [ipv4|ipv6|dual|status] [name] [address] 设置节点入口
   cdn / cdn guide                                CF CDN 引导：协议可选，邮箱自动生成
   cdn <domain> [vless|vmess|trojan] [--yes]        快速创建 CDN 节点
   cdn check <domain> [IP...] [--csv file]         当前机器的 CF 边缘 TLS 预检
   cdn status <domain> [IP]                        检查源站证书和 CF WebSocket
   cdn test <domain> [IP]                          本机代理及 1 MiB 下载测试
   cdn export <domain> [IP...] [--csv file]        导出优选 IP 链接，保留 SNI/Host
   cdn remove <domain> [--yes]                     确认删除指定 CDN
   dd, ddel [name...]                              删除多个配置**
   fix [name]                                      修复一个配置
   fix-all                                         修复全部配置
   fix-caddyfile                                   修复 Caddyfile
   fix-config.json                                 修复 config.json
   import                                          导入 sing-box/v2ray 脚本配置

管理:
   un, uninstall                                   卸载
   u, update [core | sh | caddy] [ver]             更新
   U, update.sh                                    更新脚本
   s, status                                       运行状态
   start, stop, restart [caddy]                    启动, 停止, 重启
   t, test                                         测试运行
   reinstall                                       重装脚本

测试:
   debug [name]                                    显示一些 debug 信息, 仅供参考
   gen [...]                                       同等于 add, 但只显示 JSON 内容, 不创建文件, 测试使用
   no-auto-tls [...]                               同等于 add, 但禁止自动配置 TLS, 可用于 *TLS 相关协议
其他:
   bbr                                             启用 BBR, 如果支持
   bin [...]                                       运行 sing-box 命令, 例如: sing-box bin help
   [...] [...]                                     兼容绝大多数的 sing-box 命令, 例如: sing-box generate uuid
   h, help                                         显示此帮助界面

谨慎使用 del, ddel, 此选项会直接删除配置; 无需确认
反馈问题) https://github.com/G1oow/Singbox/issues
本分支文档) https://github.com/G1oow/Singbox#readme
```
