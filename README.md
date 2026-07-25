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

安装指定版本：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh) v1.0.0
```

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
sing2 update       更新到最新版
sing2 update x.x.x 更新到指定版本
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
  三块（见下节）。唯一仍未实现的是 `ConnectionConfig`。

## 与 XrayR 的差异

| | XrayR | Sing2 |
|---|---|---|
| 代理核 | xray-core | sing-box fork（shtorm-7/sing-box-extended） |
| 配置路径 | `/etc/XrayR/config.yml` | `/etc/Sing2/config.yml` |
| 面板 | SSpanel / V2board / PMpanel / Proxypanel | 仅 SSpanel（mod_mu 系，两代都支持） |
| 并发连接数上限 | 无 | 有（`ConnLimitConfig`） |
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

还未实现的只剩 `ConnectionConfig`（`Handshake`/`ConnIdle`/`BufferSize` 等连接调优），
写进配置会被静默忽略。

## 许可证

GPL-3.0-or-later，与 Sing2 本体一致。
