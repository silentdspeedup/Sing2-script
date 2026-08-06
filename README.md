# Sing2-script

Sing2 的一键安装与管理脚本。（Sing2 本体仓库为私有，二进制经下文的分发端点获取。）

Sing2 是把 XrayR 的多租户计费后端搬到 **sing-box fork 单核** 上的实现：面板对接仍是
SSpanel（mod_mu 系，传统版与 custom_config 版都支持），协议由 sing-box 承载。

> ⚠️ **当前状态**：Sing2 尚未经过生产验证。跨核互通（真实 Xray 客户端 → Sing2 的
> VLESS+REALITY）等实机门禁仍未完成，**上线前请先在测试节点验证**，并与既有 XrayR
> 节点并行双跑对账一段时间。

## 一键安装

**本脚本是公开的，二进制不是。** 脚本层（`install.sh`、`Sing2.sh`、`Sing2.service`）无需
任何凭据即可获取；Sing2 二进制托管在需要密钥的分发端点上，首次安装用 `DIST_KEY=` 传入
（见「[分发密钥](#分发密钥)」）：

```bash
DIST_KEY=你的密钥 bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh)
```

密钥会以 600 权限落到 `/etc/Sing2/dist_key`，之后 `sing2 update` 自动读取，不必再输。

安装指定版本（`v` 前缀可省）：

```bash
DIST_KEY=你的密钥 bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh) v1.0.0
```

已装同一版本时安装脚本会直接报"无需更新"并退出（退出码 10），只刷新管理脚本，
不动二进制和配置。要强制重装加 `--force`。

### 支持的架构

只发布 Linux 侧的这几个（`uname -m` 自动识别，装错架构会在下载前就停下）：

`linux-64`、`linux-32`、`linux-arm64-v8a`、`linux-arm32-v7a`、`linux-arm32-v6`、
`linux-arm32-v5`、`linux-s390x`、`linux-riscv64`、`linux-ppc64le`

### 分发密钥

二进制走一个带鉴权的分发端点（Cloudflare R2 + Worker 网关），下载时以
`X-Sing2-Key` 请求头校验。密钥**只能下载已发布的二进制**——不涉及源码、不涉及写权限。

| 场景 | 做法 |
|---|---|
| 首次安装 | `DIST_KEY=… bash <(curl -Ls …/install.sh)` |
| 已装节点写入/轮换 | `sing2 key`（输入不回显，不进 shell history） |
| 手工写入 | `printf '%s' '密钥' > /etc/Sing2/dist_key && chmod 600 /etc/Sing2/dist_key` |

没有密钥时 `sing2 update` 会在**下载之前**停下并提示，不会动到现有安装。密钥错误与
版本不存在在端点侧返回的是同一个 404，无法从响应上区分——报错信息里也这么写了。

网关实现见 [`cloudflare/worker.js`](cloudflare/worker.js)。

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
sing2 log          合并查看全部运行日志（等同于 sing2 log all）
sing2 log runtime  只看 Sing2/panel 和核心运行信息，排除逐连接错误
sing2 log access   只看用户连接记录
sing2 log failures 只看连接失败、DNS 错误和超时
sing2 config       编辑配置文件
sing2 generate     生成配置文件（向导）
sing2 x25519       生成 REALITY 密钥对
sing2 update       更新到最新版（已是最新则提示"无需更新"，不重装）
sing2 update x.x.x 更新到指定版本
sing2 update -f    强制重装当前版本（修复被改坏的安装）
sing2 key          写入/轮换分发密钥
sing2 install      安装
sing2 uninstall    卸载
sing2 version      查看版本
```

## 目录布局

| 路径 | 内容 |
|---|---|
| `/usr/local/Sing2/sing2` | 二进制 |
| `/etc/Sing2/config.yml` | 配置文件（升级不覆盖，权限 600） |
| `/etc/Sing2/dist_key` | 分发密钥（权限 600，见「分发密钥」） |
| `/etc/systemd/system/Sing2.service` | systemd 单元 |
| `/usr/bin/sing2` | 本管理脚本 |
| `/etc/Sing2/error.log` | 运行日志（sing-box 侧） |
| `/etc/Sing2/access.log` | 逐连接访问日志 |
| `/etc/logrotate.d/Sing2` | 日志轮转配置 |
| `/etc/systemd/system/Sing2-logrotate.timer` | 仅当系统本身没有轮转驱动时才自建（见「轮转」） |

卸载**不会**删除 `/etc/Sing2`（里面有配置和证书）。要彻底清除自行 `rm -rf /etc/Sing2`。

## 配置

本仓库 [`config/config.yml`](config/config.yml) 是带注释的完整示例，字段说明就在注释里。
（完整字段规范在 Sing2 仓库的 `doc/09-config-and-migration.md`，该仓库为私有。）

几个容易踩的点：

- **`PanelType` 必须逐节点写对，取值只有 `SSpanel` 和 `Phoenix`。** 它是选择解析方言的
  唯一依据：`SSpanel` 走传统 6 段式 `server` 串，`Phoenix` 走 `custom_config`。
  **自 Sing2 v0.1.0 起不再按响应形状自动分派**——旧的嗅探行为会让解析路径在运行时变来
  变去。写错不会静默降级：两个解析器互相拒收对方的载荷，节点直接起不来（报
  `no server info in response` 或 `custom_config is empty`）并每 30s 重试。安装向导会问
  你面板类型；手改配置时别漏了这一项。
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

## 日志

出厂配置默认开两个日志，路径**固定**：

| 文件 | 内容 |
|---|---|
| `/etc/Sing2/error.log` | 运行日志（sing-box 侧） |
| `/etc/Sing2/access.log` | 逐连接访问日志，XrayR 行格式 |

⚠ **配了 `ErrorPath` 之后日志就分成两半**：sing-box 侧全部写进那个文件、不再进 journald，
而 Sing2 自己的 `[panel]` 行走 stdout、仍在 journald。日志命令会根据视图同时处理两边：

| 命令 | 内容 |
|---|---|
| `sing2 log` / `sing2 log all` | 原有兼容视图：panel/journald 与完整 `error.log` |
| `sing2 log runtime` | Sing2/panel 与核心运行信息，排除带 `connection:` 的逐连接错误 |
| `sing2 log access` | 只跟随 `Log.AccessPath`，用于查看用户、入站、目标地址等连接记录 |
| `sing2 log failures` | 只保留带 `connection:` 的失败记录，例如 DNS、连接超时和拒绝 |

四种视图都会先显示最近记录（每个日志源最多 50 条），再实时跟随；`tail -F` 兼容 logrotate 的
`copytruncate`，轮转后无需重新运行命令。没有配置对应路径或日志尚未生成时，脚本会明确提示。

手动查看原始日志仍可使用：

```bash
journalctl -u Sing2 -f          # [panel] 层
tail -F /etc/Sing2/error.log    # sing-box 运行与连接失败
tail -F /etc/Sing2/access.log   # 用户连接记录
```

不想让运行日志分流，就把 `ErrorPath` 留空，sing-box 运行日志会回到 journald。

### 轮转

安装脚本自动装 `logrotate` 并写入 `/etc/logrotate.d/Sing2`：**每天轮转、gzip 压缩、就地存放、
保留 7 份**。文件名带日期（`access.log-20260726.gz`），比序号直观，也不会因为每次轮转而整体平移。

写完会用 `logrotate -d` 自检语法——一份写坏的配置会让**系统上所有**轮转任务一起失败，不能只写
不验。自检不过就删掉并打印原因。

路径取自 `config.yml` 里**实际配置**的 `Log.AccessPath` / `Log.ErrorPath`，没配就用出厂路径
（`/etc/Sing2/` 下）。改了日志路径之后跑一次 `sing2 update`，轮转配置会跟着更新——不跑的话
它还盯着旧路径，而真正在涨的那个文件没人管。

#### 它不在 crontab 里

`crontab -l` 是空的**不代表没配**。logrotate 不是常驻进程，也不装用户 crontab，它由系统的
调度器每天叫一次，两种之一：

```bash
systemctl status logrotate.timer     # 较新的发行版（Debian 11+ / Ubuntu 21.10+ / RHEL 9+）
ls -l /etc/cron.daily/logrotate      # 较老的发行版，由 crond/cron 每天扫一次
```

安装脚本会挑出这台机器实际用的那条链路，**并在它装了却没启用时启用它**，然后在安装结束时
点名是谁触发的。两条都不可用时（最小化镜像、容器、被加固脚本 mask 掉的机器）它不会报喜，
而是自建一个只管这份配置的 `Sing2-logrotate.timer`——卸载时一并删除。

> 有个反直觉的地方：Debian/Ubuntu 的 `/etc/cron.daily/logrotate` 开头就是「如果 systemd 是
> init 就 `exit 0`」，把活交给 timer。所以在 timer 被 disable/mask 的机器上，这个文件**在，
> 但故意什么都不做**。光看文件存不存在会得出错误结论，脚本因此要读一下它会不会让位。

最省事的确认方式是 `sing2 status`，它会显示驱动和 `access.log` 上次轮转的时间。手动查：

```bash
grep Sing2 /var/lib/logrotate/status   # 记录每个日志上次轮转的日期
ls /etc/Sing2/*.gz                     # 轮转产物
```

注意 `logrotate -d` 是**干跑**，不写状态文件。所以它对没见过的日志会打 `Creating new state`
并把「上次轮转」记成当天零点，随后说「不到一天，不需要轮转」——这是干跑的正常输出，不代表
今天已经轮转过。

#### 找不到 `.gz`？先看日志有没有落盘

`sing2 generate` 生成的配置默认把 `Log.AccessPath` 与 `Log.ErrorPath` **都注释掉**，日志全部
进 journald，磁盘上根本没有这两个文件——轮转配置里的 `missingok` 让 logrotate 对此一声不吭。
症状（`/etc/Sing2` 下找不到任何 `.gz`）和「轮转真的坏了」完全一样。安装时如果检测到这种情况
会明确提示。要落盘就把这两行的注释去掉，路径改动后重跑 `sing2 update` 让轮转配置跟上。

#### 为什么是 copytruncate

Sing2 全程持有日志文件描述符。logrotate 默认的 `create` 模式会先 rename 旧文件再建新文件，
而 Sing2 仍在写那个已被改名的 inode——轮转之后新文件会永远是空的。`copytruncate` 是复制后
就地截断，唯一代价是复制与截断之间有个极窄的窗口可能丢几行，对访问日志可以接受。

（也因此**没有加 `delaycompress`**：那是给 `create` 模式用的，`copytruncate` 下副本在压缩前
已经完整，加了只是白白多留一个未压缩文件。）

#### 访问日志涨得快的节点

系统的 logrotate 通常每天只跑一次（`cron.daily` 或 `logrotate.timer`），所以配置里的
`maxsize 512M` 在默认节奏下不会让它在日内提前轮转。用户量大的节点可以让它跑得更勤。

⚠ **改成日内多次之前，必须先改 `dateformat`**，否则从当天第二次起会静默失效：文件名带的是
`dateext` + `dateformat -%Y%m%d`，日内第二次轮转的目标文件 `access.log-20260729.gz` 已经存在，
logrotate 会打一句 `destination ... already exists, skipping rotation` 然后**跳过**。也就是说，
恰恰在这条建议要解决的场景下（一天涨过两次 512M），它从第二次起就不干活了。

把 `/etc/logrotate.d/Sing2` 里的这一行加上小时：

```
    dateformat -%Y%m%d%H
```

然后让它跑得更勤，二选一。用 systemd timer 的机器（`systemctl status logrotate.timer` 有输出）：

```bash
mkdir -p /etc/systemd/system/logrotate.timer.d
printf '[Timer]\nOnCalendar=\nOnCalendar=hourly\n' > /etc/systemd/system/logrotate.timer.d/hourly.conf
systemctl daemon-reload && systemctl restart logrotate.timer
```

（`OnCalendar=` 空行是必须的——它先清掉原有的每日设置，否则两条会叠加。这会让**系统上所有**
轮转配置都改成每小时检查一次；其余配置基本都是 `daily`，检查再勤也一天只轮一次，是安全的。）

用 cron 的机器：

```bash
echo '0 * * * * root /usr/sbin/logrotate /etc/logrotate.d/Sing2' > /etc/cron.d/Sing2-logrotate
```

（这条要求 cron 装了且在跑；timer-only 的机器上写了也没人执行。）

两种做法都是每小时检查一次，超过 512M 就轮转，同时保持「每天至少一次」的下限。

卸载 Sing2 时这份 logrotate 配置会一并删除，自建的 `Sing2-logrotate.timer`（如果装过）也会
一起停用并移除。手动加的 `/etc/cron.d/Sing2-logrotate` 或 timer override 不在此列，得自己清。

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
