# CF CDN 节点

运行 `sb cdn` 打开引导式配置，新增一个走 Cloudflare 普通 CDN 的 WebSocket 节点：

```text
客户端 ── TLS / WebSocket :443 ── CF 边缘
                                  │ HTTPS 回源 :443
                                  ▼
                                Caddy
                                  │ WebSocket / 127.0.0.1:随机端口
                                  ▼
                               sing-box
```

支持 **VLESS、VMess、Trojan + WebSocket + TLS**，默认 VLESS。不会把原来的
REALITY、TUIC、Hysteria2、AnyTLS、Shadowsocks 或裸 TCP 节点直接套进 CDN，
不会把这些协议直接转换成 CDN 节点。客户端需要导入新链接。
向导最后可以选择并确认删除旧 CDN，不保留兼容路由；其他域名、独立 REALITY 等节点不受影响。

> **服务条款风险：**[Cloudflare 自助服务协议 §2.2.1(j)](https://www.cloudflare.com/terms/)
> 限制使用其服务提供 VPN 或类似代理服务。技术验证成功不代表该用途获准，
> 优选 IP 不能消除服务被限制的风险。请先确认适用合同和服务许可。

## 准备

1. 域名托管在 Cloudflare，使用一个没有被其他网站或节点占用的专用子域名。
2. 在 CF DNS 添加 A 或 AAAA，值指向 VPS 的公网地址，开启 **Proxied（橙云）**。
   同时存在 A 和 AAAA 时，两者必须都能到达本机。脚本兼容灰云状态，但不会将其报告为 CDN 成功。
3. CF SSL/TLS 设为 **Full (strict)**，确认边缘证书已生效、WebSockets 已启用。
   不使用 Flexible，也不需要客户端跳过证书验证。
4. VPS 防火墙和云安全组放行 **TCP 80、443**。端口由 Caddy 使用；
   已有 Nginx、Apache、其他服务占用时，脚本会拒绝新装，不会停止这些服务或改用随机公网端口。
   已有脚本管理的 Caddy 可以共用 80/443，不覆盖已有站点。
5. `/.well-known/acme-challenge/*` 必须可以通过 HTTP 到达 Caddy：
   不得被 CF 的 Always Use HTTPS、Redirect Rules、WAF、Bot Challenge、Access
   或缓存规则阻断/改写。初次申请尚无源站证书，HTTP 被强制跳转至 HTTPS 时可能产生 526。
   保持该路径在续期时也可访问。若临时灰云签发证书，之后仍需确保橙云下续期挑战畅通。
6. 服务器需已安装本脚本、`curl`、`jq`、`wget`，并使用 systemd 或 OpenRC。
   本功能不自动安装额外系统依赖，不需要 Cloudflare API Token。

**仅提供域名不能授权脚本修改 CF 账户。** DNS、橙云、SSL 模式和防火墙仍由用户设置；
脚本只生成本地配置、申请证书并检测链路。域名没有公网解析时会提前中止。

## 使用

```bash
sb cdn
```

也可在 `sb` 主菜单选择 **CF CDN 引导配置**。向导只有五步：

1. **域名准备**：可直接粘贴 `https://node.example.com/`。提示橙云、Full (strict)、
   防火墙和 ACME 路径要求，预检域名的 CF 边缘 TLS。失败时可以重试或换域名。
2. **协议与入口**：选择 VLESS（默认）、VMess 或 Trojan；粘贴优选 IP，或填写
   `@/root/tcp-result.csv`，最多读取十个去重候选。没有 IP 时可回车先使用域名。
   **不询问邮箱**，随机 ACME 联系地址由脚本生成。
3. **配置节点**：展示影响范围，输入 `yes` 后安装/复用 Caddy、申请证书并创建节点。
   重复输入已有域名会复用现有节点，不重置凭据或重复签发。
4. **验证和导出**：检查源站与 CF WebSocket，可选运行本机实际代理及 1 MiB 下载测试。
   导出时仅改变连接地址，SNI、Host、UUID/密码和路径保持不变。
5. **清理旧 CDN**：在用户确认客户端已经可用后，选择旧域名并再次确认删除。
   不默认删除其他节点；本机代理测试失败时不进入清理。

**服务器看不到你电脑的下载目录。** CSV 需先上传到当前 VPS，或直接粘贴候选 IP。
CFST 测速应在实际客户端网络进行，排除原 SG/TUN 等代理影响；在 VPS 上检查通过不等于
大陆客户端能访问。`--noproxy` 也不能绕过 TUN。

链接显示在终端，并保存至 `/etc/sing-box/cdn-links/<domain>.txt`（目录 700、文件 600）。
**文件包含访问凭据，不要公开上传。** 复制链接到支持该协议的客户端，再测试访问与下载。

### 快速命令

```bash
sb cdn node.example.com
sb cdn node.example.com vmess
sb cdn node.example.com trojan --yes

sb cdn check node.example.com
sb cdn check node.example.com 104.16.0.1
sb cdn check node.example.com --csv /root/tcp-result.csv

sb cdn status node.example.com 104.16.0.1
sb cdn test node.example.com 104.16.0.1
sb cdn export node.example.com 104.16.0.1 104.16.0.2
sb cdn export node.example.com --csv /root/tcp-result.csv
sb cdn remove old.example.com
```

上述 IP 仅为语法示例，不是推荐或已验证的优选 IP。`export` 只向标准输出生成链接，
不触网、不修改 DNS/节点；单独执行它不会自动保存文件。VMess、VLESS、Trojan 和 IPv6 均支持。

快速创建和删除默认要求输入 `yes`；自动化调用可显式使用 `--yes`。
这代表已确认显示的影响范围，不会跳过配置和证书校验。旧版快速命令的邮箱位置参数
仍保留兼容，但向导始终自动生成联系地址，不出现邮箱选择步骤。

脚本会自动生成 UUID/密码、随机 WebSocket 路径和本机端口，安装或复用 Caddy，
用 Let's Encrypt HTTP-01 申请证书，并由 Caddy 持续自动续期。禁用 TLS-ALPN-01，
因为 CF 边缘不会将该挑战直通源站。无需 acme.sh、DNS 插件或手工复制证书。

向导自动生成 `acme-<随机值>@<用户域名>` 作为 ACME 联系地址。
**这不是创建邮箱账户，通常不能收信**。
不会生成第三方域名下的虚假邮箱。公开证书会使域名进入证书透明度日志。

## 验证

```bash
sb cdn status node.example.com
sb info VLESS-WS-TLS-node.example.com.json
sb url VLESS-WS-TLS-node.example.com.json
sb qr VLESS-WS-TLS-node.example.com.json
```

创建后最多等待约两分钟，然后输出节点信息并检测：

| 状态 | 含义 |
| --- | --- |
| 配置已应用 | 通过 sing-box/Caddy 校验并重启，**不代表证书或 CDN 已就绪** |
| 源站就绪 | 直接连接本机 Caddy，验证域名证书和 WebSocket 101 握手摘要 |
| CDN 链路验证通过 | 通过域名访问，HTTPS 验证成功且收到 CF-Ray、WebSocket 101 和正确握手摘要 |
| 待就绪，退出码 `2` | 保留配置供 Caddy 继续签发/续期；修正 CF/DNS/防火墙后再次运行 `status` |
| 操作失败，退出码 `1` | 输入、前置检查、配置校验或服务启动失败 |

`check` 只使用 GET `/cdn-cgi/trace` 检查边缘，不需要源站已经配置。因此预检通过、
首页返回 525/526 可能同时出现：前者是客户端到 CF 已通，后者是回源尚未就绪。
连接/TLS 超时时，不能仅凭 `verify=0` 断言证书已通过，也不能直接推断 TCP 不通或域名被屏蔽。

探测不使用环境 HTTP 代理、不跟随跳转、不关闭 TLS 校验。灰云、普通网页 200、
WAF 拦截页、无效证书不会被误认为 CDN 成功。配置成功后不重复申请或覆盖同域名节点。

**`status` 的握手验证不测试代理凭据、目标站访问或带宽。**
`test` 会启动临时的本机 SOCKS 客户端，经所选 CDN 入口访问测试站，再尝试下载 1 MiB；
显示出口 IP、耗时和速度，完成/失败后结束客户端并清理临时配置。
认证/转发失败或下载超时返回 `2`，不把部分下载当作成功。

`test` 使用本机已有的 sing-box 内核，不安装新依赖、不改系统代理、TUN 或路由。
**在 VPS 上运行只是 VPS 侧样本，不代表你的客户端网络，也不保证长期提速。**
导入链接后仍需要客户端实际验证。
无 API Token 时脚本不能读取你的 CF SSL 模式，仍需自行确认 Full (strict)。

## 失败恢复与管理边界

- 配置事务共用现有网络锁；不会修改默认出口策略和其他节点。
- 配置校验或服务启动失败时，撤销本次新增的节点/站点，尝试恢复旧服务。
  新下载的 Caddy、服务文件及其 ACME 存储保留，不执行卸载；
  本次新装失败会关闭 Caddy 自启，避免缺少配置时反复启动。
- 证书仍在申请或边缘未就绪时不反复删除重建，避免消耗 ACME 限额。
  可查看 `journalctl -u caddy -u sing-box`，OpenRC 使用对应服务日志。
- 现有 `info/url/qr` 命令仍可使用。删除 CDN 推荐 `sb cdn remove <domain>`：
  只清理此脚本管理的指定 CDN 入站、Caddy 站点和向导导出文件。
  删除成功后不保留兼容路由或节点副本；删除校验/服务启动失败会恢复当前操作涉及的文件。
  不新增常驻回滚任务，不自动删除已有历史备份或 CF DNS 记录。
  CDN 节点暂不进入旧版 `change/fix`，避免丢失证书策略或未经校验覆盖反代。
  如需更换协议或域名，使用向导创建新节点、客户端验证后再选择清理旧 CDN。
- 不自动接管 Nginx、第三方站点或其他版本脚本的 CDN 元数据；80/443 被非 Caddy 服务占用时，
  应先人工安排迁移，而不是让向导猜测哪些配置可以删除。
- CF 网络设置变更可能影响同一区域内的其他网站。脚本不修改这些设置，也不会
  自动关闭 WAF、放宽防火墙或读取 CF Token。

## 不保证提速或隐藏全部源站信息

WebSocket 代理流量不是静态文件缓存。CF 提供边缘接入，但实际速度受运营商、
回源路由和 CF 策略影响，可能变快也可能变慢；长连接也可能被边缘重启或空闲超时中断，
客户端需支持重连。请遵循 Cloudflare 服务条款及所在套餐限制。

本机 sing-box 入站仅绑定 `127.0.0.1`，但 Caddy 80/443 仍可公开访问。
已有直连节点、历史 DNS 和其他服务也可能暴露源站 IP。本功能不宣称完成了源站隐藏，
不自动增加 CF IP 白名单；限制回源来源前需自行评估 ACME 验证和其他服务的可用性。

## 官方依据

- [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)
- [Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
- [Caddy TLS / ACME issuer](https://caddyserver.com/docs/caddyfile/directives/tls)
- [sing-box WebSocket transport](https://sing-box.sagernet.org/configuration/shared/v2ray-transport/)

## 开发验证

```bash
bash tests/cdn.sh
# 使用真实内核校验；服务和联网探测仍为隔离模拟
SING_BOX_BIN=/path/to/sing-box CADDY_BIN=/path/to/caddy bash tests/cdn.sh
```

CDN 测试接入现有 `tests/egress.sh` 测试链，覆盖完整菜单、三种协议、自动邮箱、
CSV/IPv6 导出、预检误判、客户端生成、实际代理失败分支和旧节点清理；
不改动 CI/CD 或构建配置。
测试使用模拟网络，不向 CA 发起签发请求；真实签发、续期和 CF 链路仍需使用自有域名验收。
