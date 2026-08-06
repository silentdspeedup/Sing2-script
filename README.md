# Sing2-script

Sing2 的一键安装与管理脚本。

> ⚠️ **当前状态**：Sing2 尚未经过生产验证，上线前请先在测试节点验证，并与既有节点并行
> 双跑对账一段时间。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh)
```

二进制不在本仓库里，需要**分发端点地址**与**密钥**。没有的话脚本会在装包之前提示输入，
输入会立即拿去验证，错了可以重来。验证通过后以 600 权限落到 `/etc/Sing2/`，此后
`sing2 update` 自动读取，**不必再输**。

安装指定版本（`v` 前缀可省）：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh) v1.0.0
```

已装同一版本时会直接报"无需更新"并退出（退出码 10），只刷新管理脚本，不动二进制和配置。
要强制重装加 `--force`。

### 免交互安装

批量部署时用环境变量或参数，跳过提示：

```bash
DIST_BASE=https://端点地址 DIST_KEY=密钥 bash <(curl -Ls .../install.sh)
# 或
bash <(curl -Ls .../install.sh) --dist-base https://端点地址 --dist-key 密钥
```

**非交互环境（CI、cron、systemd）不会提示**，缺值时直接报错退出——那种地方卡在等待输入
上是静默挂起，比一条错误难查得多。

### 支持的架构

`uname -m` 自动识别，不支持的架构会在下载前就停下：

`linux-64`、`linux-32`、`linux-arm64-v8a`、`linux-arm32-v7a`、`linux-arm32-v6`、
`linux-arm32-v5`、`linux-s390x`、`linux-riscv64`、`linux-ppc64le`

### 分发端点与密钥

| 场景 | 做法 |
|---|---|
| 首次安装 / 升级时缺值 | **什么都不用做**，脚本会提示输入 |
| 免交互 | `DIST_BASE=… DIST_KEY=… bash <(…)` 或 `--dist-base` / `--dist-key` |
| 已装节点写入或轮换 | `sing2 key`（密钥不回显，不进 shell history） |
| 手工写入 | 见下方「目录布局」的两个文件，权限 600 |

端点对「密钥错误」与「路径不存在」返回的是同一个响应，无法从中区分——所以脚本报错时会
把两种可能都列出来。

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
sing2 log runtime  只看运行信息，排除逐连接错误
sing2 log access   只看用户连接记录
sing2 log failures 只看连接失败、DNS 错误和超时
sing2 config       编辑配置文件
sing2 generate     生成配置文件（向导）
sing2 x25519       生成 REALITY 密钥对
sing2 update       更新到最新版（已是最新则提示"无需更新"，不重装）
sing2 update x.x.x 更新到指定版本
sing2 update -f    强制重装当前版本（修复被改坏的安装）
sing2 key          写入/轮换分发端点与密钥
sing2 install      安装
sing2 uninstall    卸载
sing2 version      查看版本
```

## 目录布局

| 路径 | 内容 |
|---|---|
| `/usr/local/Sing2/sing2` | 二进制 |
| `/etc/Sing2/config.yml` | 配置文件（升级不覆盖，权限 600） |
| `/etc/Sing2/dist_base` | 分发端点（权限 600） |
| `/etc/Sing2/dist_key` | 分发密钥（权限 600） |
| `/etc/systemd/system/Sing2.service` | systemd 单元 |
| `/usr/bin/sing2` | 本管理脚本 |
| `/etc/Sing2/error.log` | 运行日志 |
| `/etc/Sing2/access.log` | 逐连接访问日志 |
| `/etc/logrotate.d/Sing2` | 日志轮转配置 |
| `/etc/systemd/system/Sing2-logrotate.timer` | 仅当系统本身没有轮转驱动时才自建 |

卸载**不会**删除 `/etc/Sing2`（里面有配置、证书和分发凭据）。要彻底清除自行
`rm -rf /etc/Sing2`。

## 配置

安装后 `/etc/Sing2/config.yml` 本身就是带完整注释的示例，逐字段说明都写在注释里。

```bash
sing2 config      # 编辑（保存后自动重启）
sing2 generate    # 向导生成
```

配置项的含义与取值范围以该文件的注释为准，本仓库不再重复一份。

## 日志

出厂配置默认开两个日志：

| 文件 | 内容 |
|---|---|
| `/etc/Sing2/error.log` | 运行日志 |
| `/etc/Sing2/access.log` | 逐连接访问日志 |

⚠ **配了 `ErrorPath` 之后日志就分成两半**：核心侧全部写进那个文件、不再进 journald，
而 `[panel]` 行走 stdout、仍在 journald。日志命令会同时处理两边：

| 命令 | 内容 |
|---|---|
| `sing2 log` / `sing2 log all` | 兼容视图：journald 与完整 `error.log` |
| `sing2 log runtime` | 运行信息，排除带 `connection:` 的逐连接错误 |
| `sing2 log access` | 只跟随 `Log.AccessPath`，查看用户、入站、目标地址 |
| `sing2 log failures` | 只保留带 `connection:` 的失败记录（DNS、超时、拒绝） |

四种视图都先显示最近记录（每个日志源最多 50 条），再实时跟随；`tail -F` 兼容轮转，
轮转后无需重新运行命令。没有配置对应路径或日志尚未生成时会明确提示。

手动查看原始日志：

```bash
journalctl -u Sing2 -f          # [panel] 层
tail -F /etc/Sing2/error.log
tail -F /etc/Sing2/access.log
```

不想让日志分流，就把 `ErrorPath` 留空，运行日志会回到 journald。

### 轮转

安装脚本自动装 `logrotate` 并写入 `/etc/logrotate.d/Sing2`：**每天轮转、gzip 压缩、就地存放、
保留 7 份**，文件名带日期（`access.log-20260726.gz`）。

路径取自 `config.yml` 里**实际配置**的 `Log.AccessPath` / `Log.ErrorPath`，没配就用出厂路径。
改了日志路径之后跑一次 `sing2 update`，轮转配置会跟着更新——不跑的话它还盯着旧路径，
而真正在涨的那个文件没人管。

最省事的确认方式是 `sing2 status`，它会显示由谁触发轮转、以及上次轮转的时间。

#### `crontab -l` 是空的，不代表没配

logrotate 不是常驻进程，也不装用户 crontab，它由系统调度器每天叫一次，两种之一：

```bash
systemctl status logrotate.timer     # 较新的发行版
ls -l /etc/cron.daily/logrotate      # 较老的发行版
```

安装脚本会挑出这台机器实际用的那条链路，并在它装了却没启用时启用它。两条都不可用时
（最小化镜像、容器、被加固脚本 mask 掉的机器）会自建一个只管这份配置的
`Sing2-logrotate.timer`，卸载时一并删除。

> Debian/Ubuntu 的 `/etc/cron.daily/logrotate` 开头就是「如果 systemd 是 init 就 `exit 0`」。
> 所以在 timer 被 disable/mask 的机器上，这个文件**在，但故意什么都不做**——光看文件存不存在
> 会得出错误结论。

#### 找不到 `.gz`？

`sing2 generate` 生成的配置默认把 `Log.AccessPath` 与 `Log.ErrorPath` **都注释掉**，日志全部
进 journald，磁盘上根本没有这两个文件——轮转配置里的 `missingok` 让 logrotate 对此一声不吭，
症状和「轮转真的坏了」完全一样。安装时检测到这种情况会明确提示。要落盘就把这两行的注释
去掉，路径改动后重跑 `sing2 update`。

#### 访问日志涨得快的节点

系统的 logrotate 通常每天只跑一次，所以配置里的 `maxsize 512M` 在默认节奏下不会让它在日内
提前轮转。用户量大的节点可以让它跑得更勤。

⚠ **改成日内多次之前，必须先改 `dateformat`**，否则从当天第二次起会静默失效：文件名带的是
`dateext` + `dateformat -%Y%m%d`，日内第二次轮转的目标文件已经存在，logrotate 会打一句
`destination ... already exists, skipping rotation` 然后**跳过**——恰恰在这条建议要解决的场景下
不干活。

把 `/etc/logrotate.d/Sing2` 里那一行加上小时：

```
    dateformat -%Y%m%d%H
```

然后让它跑得更勤，二选一。用 systemd timer 的机器：

```bash
mkdir -p /etc/systemd/system/logrotate.timer.d
printf '[Timer]\nOnCalendar=\nOnCalendar=hourly\n' > /etc/systemd/system/logrotate.timer.d/hourly.conf
systemctl daemon-reload && systemctl restart logrotate.timer
```

（`OnCalendar=` 空行是必须的——先清掉原有的每日设置，否则两条会叠加。这会让**系统上所有**
轮转配置都改成每小时检查一次；其余配置基本都是 `daily`，检查再勤也一天只轮一次，是安全的。）

用 cron 的机器：

```bash
echo '0 * * * * root /usr/sbin/logrotate /etc/logrotate.d/Sing2' > /etc/cron.d/Sing2-logrotate
```

（要求 cron 装了且在跑；timer-only 的机器上写了也没人执行。）

卸载时这份 logrotate 配置会一并删除，自建的 `Sing2-logrotate.timer`（如果装过）也会一起停用
并移除。手动加的 `/etc/cron.d/Sing2-logrotate` 或 timer override 不在此列，得自己清。

## 许可证

GPL-3.0-or-later。
