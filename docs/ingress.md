# IPv4 / IPv6 入口策略

入口决定客户端如何连接 VPS，出口决定 VPS 如何连接目标网站。两者独立：

```text
IPv4 客户端 ── IPv4 入口 ──┐
                          ├── 默认 direct 出口 ── 目标网站
IPv6 客户端 ── IPv6 入口 ──┘
```

## 添加配置时选择入口

菜单：`sing-box` → **添加配置** → 选择协议 → **IPv4入口 / IPv6入口 / 双栈入口**。
选择 IPv6 时，可直接输入已分配的 IPv6 地址，或按回车自动检测；然后继续填写端口和凭证。
`sing-box add` 不带协议时也会进入同样的交互流程。

也可用一条命令创建，不必先添加再切换：

```bash
sing-box add reality --ingress ipv6
sing-box add socks 30001 user1 password1 --ingress ipv4
sing-box add socks 30002 user2 password2 --ingress ipv6
sing-box add socks 30003 user3 password3 --ingress dual
sing-box add socks 30004 user4 password4 --ingress ipv6 --listen 2001:db8::2
```

请替换示例密码和 IPv6 地址。入口选项可放在协议参数之前或之后，也接受 `--ingress=ipv6`。
`--listen` 需配合 `--ingress ipv4` 或 `ipv6` 使用；IPv4 省略时监听 `0.0.0.0`，IPv6 省略时自动检测。
指定 IPv6 时不会先探测 IPv4，IPv6-only VPS 也能创建节点；完成后立即显示对应的 IPv6 链接。
未传入口选项的旧式命令继续使用双栈，默认首次安装也维持双栈，不额外插入交互。
AnyTLS 域名证书节点会按 IPv6 检查 AAAA 记录，兼容压缩、展开和大小写不同的 IPv6 写法。
IPv6-only VPS 的目标网站及 REALITY 握手目标仍需具备可用 IPv6；入口选择不会额外提供 IPv4 出口。

## 节点命名规则

生成的节点名（配置文件名与入站 tag）统一为 `协议-IPv6/v4-机器ID`：

- 地址族取节点的入口策略：IPv4 入口为 `v4`，IPv6 入口为 `v6`，双栈为 `dual`；
  反代型 `*-TLS` 协议的公网入口由 Caddy 管理，记为 `dual`。
- 机器 ID 默认取主机名短名（第一个 `.` 之前的部分）；可用环境变量自定义：
  `SB_MACHINE_ID=tokyo01 sb add socks ...` 会生成 `Socks-v4-tokyo01.json` 这类名称。
- 同机同协议同地址族重名时，自动追加端口区分，例如 `Socks-v6-vm01-30002.json`；基础名空出后回落到基础名。
- 切换入口（`ingress ipv4|ipv6|dual`）时同步重命名：地址族段始终与实际监听一致，
  文件与入站 tag 一并更新；重命名同样先校验、原子替换，失败自动恢复，备份为 `原文件名.network.bak`。
- 修改（`change`）旧命名的节点时自动迁移到新命名，不覆盖其他节点；旧命名文件切换入口时保持原名，待下次修改时迁移。

新建直连入口会先校验主配置及全部节点，再原子创建配置；重名时拒绝覆盖。
若重启失败，只撤销本次新节点并恢复原服务，不清除其他节点或出口策略。
反代型 `*-TLS` 协议不接受入口选项，其公网 IPv4 / IPv6 由 Caddy 或外部反代管理，脚本会明确提示。

离线生成配置也支持入口参数；IPv6 必须提供显式地址，不进行本机地址分配检查或网络探测：

```bash
sing-box gen socks 30002 user2 password2 --ingress ipv6 --listen 2001:db8::2
```

## 切换已有节点的入口

```bash
sing-box ingress status                         # 列出各节点的监听策略
sing-box ingress ipv4 Socks-v4-vm01.json          # 仅 IPv4，监听 0.0.0.0
sing-box ingress ipv6 Socks-v6-vm01.json          # 自动获取本机公网 IPv6 并绑定
sing-box ingress ipv6 Socks-v6-vm01.json 2001:db8::2 # 或显式指定实际分配的 IPv6
sing-box ingress dual Socks-v4-vm01.json          # 恢复双栈，监听 ::
sing-box ingress                                # 交互选择节点和策略
```

示例 IPv6 `2001:db8::2` 为文档地址，使用时必须换成 VPS 实际地址。
菜单入口：`sing-box` → **其他** → **设置入口策略**。
修改某个节点不会覆盖其他节点的入口设置，也不会改变其端口、密码、UUID、TLS 或路由。
符合新命名规则的节点会在切换入口时同步重命名（文件与入站 tag 的地址族段随之更新）；旧命名文件保持原名。

IPv6-only 绑定具体 IPv6 地址，**不是把 `::` 当成仅 IPv6**。
Linux 上会检查该地址是否分配给本机；自动检测不适用于公网 IPv6 与本机地址不同的 NAT6 场景。
IPv4 可提供第三个参数绑定具体本机 IPv4；省略时监听所有 IPv4 地址。

## IPv4、IPv6 节点共存，共用出口

### 方式一：同一双栈节点，导出两个链接

```bash
sing-box ingress dual Socks-dual-vm01.json
sing-box url Socks-dual-vm01.json ipv4
sing-box url Socks-dual-vm01.json ipv6
sing-box egress ipv6
```

将两个链接导入客户端，即可分别通过 IPv4 和 IPv6 连接同一个节点。
二者使用相同端口和凭证、相同入站标签、相同路由和默认出口。
也支持 `sing-box qr Socks-dual-vm01.json ipv4` / `ipv6`。
`egress ipv6` 表示出口 IPv6 优先、IPv4 回退，不要求客户端从 IPv6 入口连接。

### 方式二：两个独立配置

直接创建两个使用不同入口的节点，然后设置一次共用出口：

```bash
sing-box add socks 30001 user1 password1 --ingress ipv4
sing-box add socks 30002 user2 password2 --ingress ipv6
sing-box egress ipv4
```

此时两个入口同时存在，默认都使用 IPv4 优先出口。
建议独立配置使用不同端口；同一端口的共存还取决于实际绑定地址和协议，不自动重分配端口。
修改端口、密码或 UUID 等参数时，脚本会保留已经选择的入口监听地址。
直连节点的这些修改同样先校验完整配置，并使用与入口切换相同的事务锁：
校验失败不落盘，重启失败恢复原节点；修改端口或协议导致文件名变化时，不覆盖同名节点。
修改前的旧文件备份为 `原文件名.network.bak`。Caddy 反代域名、路径和站点配置的联动修改仍沿用原流程，
不属于这次直连节点事务保护的范围。

命令参数中的空格或通配符需使用引号包裹。Socks 用户名、密码和 Shadowsocks 密码在配置读写及 Base64 分享链接中保留原值：

```bash
sb change Socks-v6-vm01.json passwd 'my long password'
```

## 分享链接和限制

- 不指定地址族时，IPv4-only 节点导出 IPv4 链接，IPv6-only 节点使用所绑定的 IPv6。
- 双栈默认延续 IPv4 优先获取地址的行为，可用 `url ... ipv6` 显式获取 IPv6 链接。
- 不能为仅 IPv4 节点生成 IPv6 链接，反之亦然；地址获取失败时不会假装回退成另一地址族。
- IPv6 URI 使用 `[IPv6]:port`；VMess 的 JSON `add` 字段使用不带方括号的 IPv6。
- AnyTLS 域名证书节点切换 IP 入口后保留域名 SNI，避免把证书域名当作连接 IP。
- **Caddy 反代节点不支持此命令**：其公网入口由 Caddy 管理，修改 `127.0.0.1` 后端监听会绕过原本的接入边界。
- 不修改防火墙、安全组、系统 IPv6 开关、网卡地址、系统路由或自定义分流规则。
- 已有自定义路由仍然生效；只有使用默认 `direct` 出口的流量才共享 `egress` 设置。
- IPv6 节点需要 VPS 和客户端都有可用 IPv6 网络，并放行相应端口。仅有 IPv4 的客户端不能直连 IPv6 地址。

## 安全应用

修改前检查主配置和全部节点配置，目标节点只加载一次；失败不覆盖原文件。
修改前的节点配置保存在同目录的 `*.json.network.bak`，其中包含密码等敏感信息，请勿公开。
应用时重启 sing-box，现有连接可能中断；重启失败则恢复原配置并尝试恢复服务。
入口、DNS、出口修改使用同一个事务锁，避免同时重启和覆盖。
入口切换不重建主配置，因此不会清除既有出口策略。

## 验证

`bash tests/egress.sh` 会同时运行出口、入口和添加配置回归测试。
可使用 `SING_BOX_BIN=/path/to/sing-box bash tests/ingress.sh` 调用真实内核；
本机有 Node.js 时，还会建立隔离的 loopback SOCKS、HTTP 和 DNS 服务，验证：

- 两个 IPv4 / IPv6 入口同端口共存，并分别共用 IPv4、IPv6 优先出口。
- 单个 `::` 双栈入口可同时接受 IPv4、IPv6 连接。

测试不修改系统配置，结束后关闭测试进程；临时配置保留供排查。
这不替代真实 VPS 的公网路由、防火墙和客户端连通性检查。

参考：[sing-box Listen Fields](https://sing-box.sagernet.org/configuration/shared/listen/)。
