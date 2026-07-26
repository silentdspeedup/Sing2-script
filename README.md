# Sing2-script

[Sing2](https://github.com/silentdspeedup/Sing2) 的一键安装与管理脚本。

Sing2 是把 XrayR 的多租户计费后端搬到 **sing-box fork 单核** 上的实现：面板对接仍是
SSpanel（mod_mu 系，传统版与 custom_config 版都支持），协议由 sing-box 承载。

> ⚠️ **当前状态**：Sing2 尚未经过生产验证。跨核互通（真实 Xray 客户端 → Sing2 的
> VLESS+REALITY）等实机门禁仍未完成，**上线前请先在测试节点验证**，并与既有 XrayR
> 节点并行双跑对账一段时间。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh)
```

安装指定版本（`v` 前缀可省）：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh) v1.0.0
```

已装同一版本时安装脚本会直接报"无需更新"并退出（退出码 10），只刷新管理脚本，
不动二进制和配置。要强制重装加 `--force`。

## 使用

安装后 `sing2` 与 `Sing2` 都可用（大小写不敏感）：

```
sing2              显示管理菜单
sing2 start        启动
sing2 stop         停止
sing2 restart      重启
sing2 status       查看状态
sing2 enable       设置开机自启
sing2 disable      取消开机自启
sing2 log          查看日志（journalctl -f）
sing2 config       编辑配置文件
sing2 generate     生成配置文件（向导）
sing2 x25519       生成 REALITY 密钥对
sing2 update       更新到最新版（已是最新则提示"无需更新"，不重装）
sing2 update x.x.x 更新到指定版本
sing2 update -f    强制重装当前版本（修复被改坏的安装）
sing2 install      安装
sing2 uninstall    卸载
sing2 version      查看版本
```

## 目录布局

| 路径 | 内容 |
|---|---|
| `/usr/local/Sing2/sing2` | 二进制 |
| `/etc/Sing2/config.yml` | 配置文件（升级不覆盖，权限 600） |
| `/etc/systemd/system/Sing2.service` | systemd 单元 |
| `/usr/bin/sing2` | 本管理脚本 |
| `/etc/logrotate.d/Sing2` | 日志轮转配置（见下节） |

卸载**不会**删除 `/etc/Sing2`（里面有配置和证书）。要彻底清除自行 `rm -rf /etc/Sing2`。

## 配置

字段规范见 Sing2 仓库的 [`doc/09-config-and-migration.md`](https://github.com/silentdspeedup/Sing2/blob/master/doc/09-config-and-migration.md)。
本仓库 [`config/config.yml`](config/config.yml) 是带注释的完整示例。

几个容易踩的点：

- **`PanelType` 只能是 `SSpanel`。** 传统 SSpanel（< 2021.11）与 Phoenix 这类
  custom_config 面板都属这一类，Sing2 按面板响应的形状自动分派，无需在配置里区分。
- **VMess 还是 VLESS 由面板决定。** `ApiConfig.EnableVless` 只是兜底；面板 server 串里的
  `enable_vless` 优先。因此同一份配置能同时服务 VMess-TCP / VMess-WS-TLS /
  VLESS-Vision-REALITY 三种节点。
- **REALITY 私钥必须留在节点本地**（`ControllerConfig.REALITYConfigs.PrivateKey`），
  用 `sing2 x25519` 生成，面板只填公钥。原因：面板的 `server` 串同时用于渲染用户订阅，
  私钥写进面板等于发给每一个客户端。
- **Mieru / TrustTunnel 的用户名是 `u{uid}`。** 这是节点端与面板之间的硬约定，面板订阅
  渲染的 `username` 必须一致，否则这两个协议会鉴权失败（而且表现是"客户端连不上"，
  两侧都不报错）。
- **自定义 DNS / 出站 / 分流**用顶层 `DnsConfig` / `OutboundConfig` / `RouteConfig`
  三块（见下节）。
- **连接调优**用顶层 `ConnectionConfig`（`UDPTimeout` / `TCPKeepAlive` /
  `TCPKeepAliveInterval` / `DisableTCPKeepAlive`，单位整数秒）。注意它**不是**
  XrayR 那五个字段的移植：`Handshake` / `ConnIdle` / `UplinkOnly` / `DownlinkOnly` /
  `BufferSize` 是 xray policy 的设置，sing-box 没有 policy 这一层，写进去不生效，
  但启动时会逐条告警说明替代方案，不会静默吞掉。

## 日志轮转

安装脚本会自动装好 `logrotate` 并写入 `/etc/logrotate.d/Sing2`：**每天轮转、gzip 压缩、
就地存放、保留 7 份**。文件名带日期（`access.log-20260726.gz`），比序号直观，也不会
因为每次轮转而整体平移。

轮转的路径**从 `config.yml` 里读实际配置的 `AccessPath` / `ErrorPath`**，没配置就用默认的
`/etc/Sing2/access.log`、`/etc/Sing2/error.log`。所以把日志挪到 `/var/log/` 之后重装一次
（或 `sing2 update`）就会跟着走。

写完会用 `logrotate -d` 自检一遍语法——一份写坏的配置会让**系统上所有**轮转任务一起失败，
不能只写不验。自检不过就删掉并打印原因。

### 为什么是 copytruncate

Sing2 全程持有日志文件描述符。logrotate 默认的 `create` 模式会先 rename 旧文件再建新文件，
而 Sing2 仍在写那个已被改名的 inode——轮转之后新文件会永远是空的。`copytruncate` 是复制后
就地截断，唯一代价是复制与截断之间有个极窄的窗口可能丢几行，对访问日志可以接受。

（也因此**没有加 `delaycompress`**：那是给 `create` 模式用的，`copytruncate` 下副本在压缩前
已经完整，加了只是白白多留一个未压缩文件。）

### 访问日志涨得快的节点

系统的 logrotate 通常每天只跑一次（`cron.daily` 或 `logrotate.timer`），所以配置里的
`maxsize 512M` 在默认节奏下不会让它在日内提前轮转。用户量大的节点可以让它跑得更勤：

```bash
echo '0 * * * * root /usr/sbin/logrotate /etc/logrotate.d/Sing2' > /etc/cron.d/Sing2-logrotate
```

改成每小时检查一次，超过 512M 就轮转，同时保持「每天至少一次」的下限。

卸载 Sing2 时这份配置会一并删除。

## 与 XrayR 的差异

| | XrayR | Sing2 |
|---|---|---|
| 代理核 | xray-core | sing-box fork（shtorm-7/sing-box-extended） |
| 配置路径 | `/etc/XrayR/config.yml` | `/etc/Sing2/config.yml` |
| 面板 | SSpanel / V2board / PMpanel / Proxypanel | 仅 SSpanel（mod_mu 系，两代都支持） |
| 并发连接数上限 | 无 | 有（`ConnLimitConfig`） |
| 跨节点设备限 | 面板 `alive_ip` 或 Redis 二选一 | 只走面板 `alive_ip`（Redis 通路已移除） |
| 访问日志上报 | 定制版有 | 有（`AccessLog`） |
| 用户增删 | 动态 | 动态，且**已建立连接不中断**（全 9 协议） |

### XrayR 的附属配置文件，Sing2 的对应方式

Sing2 不使用这些**文件**（它们是 xray 格式），对应能力改为**直接内联写在 config.yml 里**：

| XrayR 文件 | Sing2 对应 | 说明 |
|---|---|---|
| `dns.json` | `DnsConfig:` | sing-box `dns{}` 直接透传 |
| `route.json` | `RouteConfig:` | sing-box `route{}` 直接透传 |
| `custom_outbound.json` | `OutboundConfig:` | sing-box outbound 数组直接透传 |
| `custom_inbound.json` | ➖ 不适用 | 入站全部由面板下发 |
| `geoip.dat` / `geosite.dat` | `RouteConfig.rule_set` | sing-box 用自己的 `.srs` 格式，与 xray 的 `.dat` **不通用**；remote 自动下载或 local 指向本地文件 |
| `rulelist` | `ApiConfig.RuleListPath` | 本地审计正则，沿用 |

三块**都可省略**——省略时 DNS 用默认、只有一个 `direct` 出站、不分流（全部直出）。
完整可用示例见 [`config/config.yml`](config/config.yml) 末尾。

⚠ 两个必须知道的：

1. **未知键会导致整块被拒、节点起不来**。这三块是原生透传，键名要对照你所用
   sing-box 版本的官方文档；错误信息会点名是哪一块。
2. `ControllerConfig` 里的 `EnableDNS` / `DNSType` **仍然无效**（它们走的是"面板下发
   DNS"那条路径，目前没有数据源）。要自定义 DNS 请用顶层 `DnsConfig`。
3. `ConnectionConfig` 里 XrayR 的 `ConnIdle` **不要直接搬数值到 `UDPTimeout`**：
   xray 的 connIdle 默认 30 秒且同时管 TCP，而 sing-box 的 `udp_timeout` 默认约
   300 秒，照搬会让 UDP 会话在 30 秒被切断。

配置面到此已完整——顶层不再有被静默忽略的键。

## 许可证

GPL-3.0-or-later，与 Sing2 本体一致。
