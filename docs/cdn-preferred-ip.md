# CF 优选 IP：教程核对与客户端操作

核对日期：2026-10-07。本文解释已有 **VLESS + WebSocket + TLS + CF CDN**
节点如何选择连接地址，不修改服务器、DNS、系统代理或现有节点。

## 先说明服务条款风险

Cloudflare 自助服务协议 §2.2.1(j) 明确限制使用其服务提供 VPN 或类似代理服务。
CloudflareSpeedTest 作者 README 也提示了代理套 CDN 的风险。
技术测试通过不代表该用途得到 Cloudflare 许可；优选 IP 不会改变这一点，
也不能保证账号、域名或流量不会被限制。需要长期服务时，应先确认适用合同及服务许可。

来源：[Cloudflare 协议](https://www.cloudflare.com/terms/)、
[CFST 作者 README](https://github.com/XIU2/CloudflareSpeedTest)。

## 一、哪些教程内容可以采用

本次对照了作者文档、两篇中文教程、作者讨论帖，以及客户端和 CF 官方文档。
搜索页面的摘要未代替原文；NodeSeek 页面返回 403、BiuPing 原文读取超时，
未把这两篇当作已核实依据。

| 来源 | 可采用的内容 | 不照搬的内容 |
| --- | --- | --- |
| [XIU2/CloudflareSpeedTest README](https://github.com/XIU2/CloudflareSpeedTest) | 默认 TCPing、测速参数、代理污染、结果文件与故障排查 | 默认公共下载地址不保证可用 |
| [Daimon：优选 IP / 优选域名](https://blog.daimona.cn/posts/cloudflare-best-ip/)（2026-02-03） | 分清 CF 官方 IP、第三方反代、优选域名；连接地址与 SNI/Host 分离 | “任意 CF 官方 IP 都能用”“IP 段固定对应国家”“一定跑满带宽”等说法不作为保证；程序名需以当前版本为准 |
| [E 路领航：优选 IP 指南](https://blog.oool.cc/archives/cloudflare-best-ip-selection-guide-2026)（页面标注 2026-01） | 要同时考虑失败率、延迟与实际下载，而不是只看 Ping | 其程序名、`-ipv6` 参数与当前 XIU2 帮助不一致；按运营商推荐固定非标准端口缺少可复核依据，不用于当前部署 |
| [作者讨论 #490：下载测速地址](https://github.com/XIU2/CloudflareSpeedTest/discussions/490) | 测速站失效、限速或文件不合适会影响测速结果 | 别人的测速文件正常，不代表自己的域名和节点正常 |
| [讨论 #382](https://github.com/XIU2/CloudflareSpeedTest/discussions/382)、[#383](https://github.com/XIU2/CloudflareSpeedTest/discussions/383) | 用户报告的地区、运营商和时段差异，提示必须本地实测 | 讨论中的猜测不能直接推出“全国不可用”；不采用流量攻击、关闭 TLS 等建议 |
| [Mihomo VLESS](https://wiki.metacubex.one/config/proxies/vless/)、[传输层配置](https://wiki.metacubex.one/config/proxies/transport/) | `server`、`servername`、`network: ws`、`ws-opts.path/headers` | 官方示例展示的是字段全集，不要把示例中的 REALITY、Vision、跳过验证等全部复制进 WS 节点 |
| [sing-box VLESS](https://sing-box.sagernet.org/configuration/outbound/vless/)、[V2Ray transport](https://sing-box.sagernet.org/configuration/shared/v2ray-transport/) | 服务器地址、TLS 配置与 WS transport 是独立字段 | 不把裸 TCP/REALITY 节点当作普通 CF WebSocket 节点 |

## 二、推荐方案

```text
大陆实际使用网络
    → 实测可用的 CF IP:443
    → Host/SNI 所指的、已开启代理的自有域名
    → Caddy → 本机 sing-box 入站
```

只替换客户端的 **连接地址**。保留：

- 服务器原配置、证书、UUID、WebSocket 路径。
- 原 CF 回源域名的 A/AAAA 记录内容和橙云状态。
- 客户端的原域名 SNI、WebSocket Host 和证书验证。

CF 橙云返回边缘地址，灰云返回源站地址。优选 IP 是选择客户端连接入口，
不是把源站 DNS 记录改成 CF IP。参见 [CF 代理状态](https://developers.cloudflare.com/dns/proxy-status/)。

不采用不明来源的反代 IP/端口或公共优选域名作为默认方案。
它们可能由第三方维护，并非 CF 官方服务承诺，地址、端口和可用性均可能变化。

## 三、Windows 操作步骤

以下用 `node.example.com` 代表原节点域名，请替换成自己的域名。
命令需在 CFST 解压目录中执行，本文只提供步骤，没有执行测速或安装程序。

### 1. 下载官方工具

核对时最新稳定版是 [CFST v2.3.5](https://github.com/XIU2/CloudflareSpeedTest/releases/tag/v2.3.5)，
普通 Windows x64 使用 `cfst_windows_amd64.zip`，解压后的程序是 `cfst.exe`。
保留压缩包附带的 IP 数据文件。未来更新以作者 Release 为准，不使用博客中的镜像或未知打包程序。

该版本 Windows x64 资产的 GitHub SHA256：

```text
67d06a0c68b7fd6998d5e6abea1dbf850cac2c19c5d8c5980aa32fc7aba1ff5f
```

此值来自 Release API，本次没有下载或执行该资产。

### 2. 使用真正要优化的网络

- 测大陆宽带，就在该宽带的电脑上测；不要在 VPS 或 SG 出口上替代测速。
- 下载工具时可以用现有代理；开始优选前，让测试进程绕过 SG TUN、系统代理和路由器代理，
  或在确认不影响其他工作后自行暂时关闭它们。
- `curl --noproxy "*"` 只排除应用层代理，**不会绕过 TUN**。
- 如果 TCP 耗时大量为 `0.x ms`，先检查是否被本机 TUN 接管。不能用设置延迟下限来“修好”污染的测量。
- 后续测试新节点时，仍不要让它经由 SG 节点形成链式代理。

依据：CFST README 的代理提示；本项目此前也观察到 TUN 开启后 TCP 握手耗时远低于 TLS 实际耗时。

### 3. 先用 TCP 443 筛候选，不跑大流量下载

```powershell
.\cfst.exe -n 20 -t 4 -tp 443 -tl 300 -tlr 0.25 -dd -p 10 -o tcp-result.csv
```

- 默认就是 **TCPing**，不是 ICMP Ping。
- `-n 20`：保守并发，避免照搬 500/1000 线程或扫描全部地址的参数。
- `-t 4`：每个候选测试四次。
- `-tl 300`、`-tlr 0.25`：初筛门槛，不是对网络的保证；无结果时应检查网络和门槛，不承诺换 IP 必定有效。
- `-dd`：不下载测速文件，所以下载速度为零是预期行为。
- `-p 10` 只控制显示数量，完整结果看 `tcp-result.csv`。

结果按初筛质量排序，但 TCP 通不等于 TLS 或代理可用。
不要把所有公布的 CF 地址都视为可用边缘入口，作者 README 明确讨论了回源地址、
企业专用地址等造成“TCP 通但 HTTP 不通”的情况。

### 4. 再用自己的域名验证候选

先把结果前十个地址写入候选文件：

```powershell
Import-Csv .\tcp-result.csv |
  Select-Object -First 10 -ExpandProperty "IP 地址" |
  Set-Content -Encoding ascii .\candidates.txt
```

按本次核对的工具参数，可以用自己的域名做第二轮 HTTPing：

```powershell
.\cfst.exe -f candidates.txt -n 5 -t 4 -tp 443 -httping -httping-code 200 -url "https://node.example.com/cdn-cgi/trace" -dd -p 10 -o https-result.csv
```

这一步仍使用 TCP/HTTPS，不是 ICMP。`/cdn-cgi/trace` 测的是 CF 边缘，
不能代替 WebSocket 入站和代理认证测试。还应对选中的地址检查证书：

```powershell
$preferredIp = "填入候选IP"
curl.exe -q --noproxy "*" --http1.1 --connect-timeout 8 --max-time 15 `
  --resolve "node.example.com:443:$preferredIp" `
  "https://node.example.com/cdn-cgi/trace"
```

不要添加 `-k`。如果 TLS 失败、超时或域名不匹配，就淘汰该候选，不通过关闭证书验证来“修复”。
测试得到的 `colo` 是这一次请求的边缘位置，不是这个 Anycast IP 永久所属的国家。

### 5. 复制原节点，再改客户端地址

优先复制现有可用节点，不覆盖唯一的原节点。

| 字段 | 值 |
| --- | --- |
| 连接地址 / server | 本机实测可用的 CF IP |
| 端口 | 443 |
| 协议 | VLESS |
| 传输 | WebSocket / ws |
| TLS | 开启 |
| SNI / servername | 原节点域名 |
| WebSocket Host / 伪装域名 | 原节点域名 |
| UUID | 原节点 UUID，不重新生成 |
| WebSocket 路径 | 原节点完整路径，不修改 |
| Flow / 流控 | 留空，不设置 `xtls-rprx-vision` |
| 跳过证书验证 | 关闭，即 false |

v2rayN 使用上述字段；具体 UI 名称可能随版本变化。

Mihomo / Clash Meta 字段示例（占位符必须替换，不是完整订阅文件）：

```yaml
proxies:
  - name: CF-preferred
    type: vless
    server: "填入候选IP"
    port: 443
    uuid: "保留原UUID"
    tls: true
    servername: node.example.com
    skip-cert-verify: false
    network: ws
    ws-opts:
      path: "/保留原完整路径"
      headers:
        Host: node.example.com
```

sing-box 则修改出站 `server`，保留 `server_port: 443`、
`tls.enabled: true`、`tls.server_name`、`transport.type: "ws"`、
`transport.path` 和 `transport.headers.host`。不要修改服务器的入站监听地址。

### 6. 实际代理验收

为前三个可用候选分别复制节点，逐一测试：

1. 确认没有套着原 SG 节点；查看客户端连接日志或路由。
2. 进行实际 HTTPS 访问，确认出口是预期 VPS，不只是测出一个 TCP 延迟。
3. 做少量下载、持续访问及断线重连；重复测试不同目标。
4. 在平时实际使用的时段再次测试，优先选择多轮无失败的候选，保留原节点用于回退。

不能把访问 CF 测速站的速度直接当成“客户端 → CF → VPS → 目标网站”的速度。
优选改变的是连接入口；最终效果还受到 Anycast 路由、回源、VPS 出口、目标站点及服务策略影响。
本次研究没有产出经大陆直连验证的“最佳 IP”，也没有对某个 IP 作长期可用承诺。

## 四、为什么有教程让“优选域名”开灰云

那通常是另外创建一个**只提供地址解析的入口域名**：

```text
node.example.com   → VPS 公网 IP    橙云：实际被访问、回源的业务域名
entry.example.com  → 优选 CF IP     灰云：只给客户端查找连接地址
```

客户端连接地址可以用 `entry.example.com`，但 SNI 和 Host 必须还是 `node.example.com`。
这不是关闭原业务域名的橙云。也不要把原业务域名的源站 A 记录改成优选 CF IP。

初次使用直接填一个实测 IP 更容易排错；确认有效后再考虑自有入口域名，
不必一开始引入第三方域名、自动 DNS 更新、Token 或定时任务。

## 五、当前部署的边界

脚本现已提供 `sb cdn` 引导，以及：

```bash
sb cdn check node.example.com --csv /root/tcp-result.csv
sb cdn status node.example.com 104.16.0.1
sb cdn test node.example.com 104.16.0.1
sb cdn export node.example.com 104.16.0.1
```

IP 为语法示例，不代表已优选。引导保留协议选择，随机邮箱自动生成；支持导入最多十个
CSV 候选、导出正确的 SNI/Host 链接，并在客户端确认新节点可用后选择清理旧 CDN。
CSV 必须位于运行脚本的机器上。`check/status/test` 都反映当前机器的线路；
若在 VPS 执行，仍不能代替本文的大陆客户端测试。

也可以手工复制客户端节点并替换连接地址，不需要修改服务器或重新申请证书。
本文没有自动关闭 TUN、安装工具、扫描地址、修改 DNS、导出真实凭据或部署任何变更。
