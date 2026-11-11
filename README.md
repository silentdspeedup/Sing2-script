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

| 架构 | `uname -m` | 产物 |
|---|---|---|
| 64 位 x86 | `x86_64` / `x64` / `amd64` | `linux-64` |
| 64 位 ARM | `aarch64` / `arm64` | `linux-arm64-v8a` |

只发布这两个架构。32 位 x86、ARM32、RISC-V、s390x、ppc64le 及 MIPS 均不提供产物，
在这些机器上脚本会立即报「不支持的 CPU 架构」并退出，不会改动系统上的任何东西。

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
sing2 memlimit     查看内存软上限（默认不设）
sing2 memlimit 值  设置内存软上限，如 1500MiB；off 取消
sing2 install      安装
sing2 uninstall    卸载
sing2 version      查看版本
```

## 目录布局

| 路径 | 内容 |
|---|---|
| `/usr/local/Sing2/sing2` | 二进制 |
| `/etc/Sing2/config.yml` | 配置文件（升级不覆盖，权限 600） |
| `/etc/Sing2/config.yml.example` | 当前版本的配置模板，**每次安装/升级刷新**，仅供对照 |
| `/etc/Sing2/dist_base` | 分发端点（权限 600） |
| `/etc/Sing2/dist_key` | 分发密钥（权限 600） |
| `/etc/systemd/system/Sing2.service` | systemd 单元 |
| `/etc/systemd/system/Sing2.service.d/memlimit.conf` | 内存软上限，**只在设置过时存在**（见「内存软上限」） |
| `/usr/bin/sing2` | 本管理脚本 |
| `/etc/Sing2/error.log` | 运行日志 |
| `/etc/Sing2/access.log` | 逐连接访问日志 |
| `/etc/logrotate.d/Sing2` | 日志轮转配置 |
| `/etc/systemd/system/Sing2-logrotate.timer` | 仅当系统本身没有轮转驱动时才自建 |

卸载**不会**删除 `/etc/Sing2`（里面有配置、证书和分发凭据）。要彻底清除自行
`rm -rf /etc/Sing2`。内存软上限的 `memlimit.conf` 会随卸载删除（里面有你自己加的其它设置时除外，
见「内存软上限」）。

## 配置

带完整注释、逐字段说明的模板是 `/etc/Sing2/config.yml.example`，**每次安装和升级都会刷新**到当前版本。

想知道新版加了什么、哪条注释变了：

```bash
diff /etc/Sing2/config.yml /etc/Sing2/config.yml.example
```

> 为什么不直接看 `/etc/Sing2/config.yml`：那份是你自己的配置，升级**刻意不覆盖**它（否则面板地址、
> ApiKey 会被抹掉），所以它的注释停留在你当初安装的那个版本；而 `sing2 generate` 向导会把它整份
> 重新生成，那份**不带注释**。`.example` 是那份始终最新、且可以随便看随便改的参考。

```bash
sing2 config      # 编辑（保存后自动重启）
sing2 generate    # 向导生成
```

配置项的含义与取值范围以该文件的注释为准，本仓库不再重复一份。

## 内存软上限（GOMEMLIMIT）

**默认不设**，安装和升级也不会替你设。只有内存峰值成了问题时才需要它。

```bash
sing2 memlimit            # 查看当前值，未设置时显示「未设置」
sing2 memlimit 1500MiB    # 设置
sing2 memlimit off        # 取消
```

改完会问是否重启——**重启之后才生效**，脚本不会自己重启；设置时有提醒（见下）的话，这一问
默认答「否」。菜单里是最后一项，`sing2` 菜单的状态区也会显示当前值，写了还没重启时会标「重启后生效」。

`sing2 memlimit <值>` / `sing2 memlimit off` 的退出码：0 改好了，或本来就是这样；1 取值被拒，写入、
删除失败，或 `memlimit.conf` 里有不是本脚本写的内容（都是什么都没改）；4 systemd 没读到这次的改动（`systemctl daemon-reload` 失败，或重读之后仍然
没有这个值）——这时重启也用不上它，按提示修好后同一条命令再跑一次；多给了取值是 2。

安装或升级时也可以顺带设置：

```bash
bash <(curl -Ls .../install.sh) --memlimit 1500MiB
bash <(curl -Ls .../install.sh) --memlimit off       # 取消
```

不带 `--memlimit` 时安装脚本不改这个文件的内容：全新安装不写，升级保留已有的设置。升级本来就
会重启 Sing2，新值随之生效；已是最新版、只改这一项时不重启，会提示你执行 `sing2 restart`。
这条路的退出码照旧是 10；写入或删除失败、`systemctl daemon-reload` 失败、重读之后 systemd
里根本没有这个值，或者 `memlimit.conf` 里有不是本脚本写的内容时是 1。值被你自己的另一个 drop-in
盖过时仍是 10，脚本会说出来。

升级和重装之前（带不带 `--memlimit` 都一样），安装脚本会先让 systemd 重新读取配置（`systemctl daemon-reload`：
正在运行的 Sing2 不受影响，但之后的重启用的都是磁盘上的设置），再确认 systemd 启动 Sing2 时会给的
GOMEMLIMIT Go 认得——只要是用 `Environment=` 设的，不管写在 `memlimit.conf` 还是你自己的其它 drop-in 里
（`EnvironmentFile=` 指向的文件里设的查不到，查看时也认不出它的来源）；`--memlimit` 马上要替换掉的
`memlimit.conf` 里的旧值不查。手改出来、Go 不认的写法会让升级后的 Sing2 起不来，这时安装脚本在下载和停服之前
就以 1 退出，正在运行的 Sing2 不受影响——但 Sing2 已经在跑时，systemd 手里通常就是这个值，下一次重启（含崩溃后
的自动拉起、重启机器）就会起不来，要尽快改好：值在 `memlimit.conf` 里就先用 `sing2 memlimit <值>` 重写（还没装
好、没有 `sing2` 命令时用 `--memlimit <值>`；文件里有你自己加的设置时，自己改好那一行），在别处就用
`systemctl cat Sing2` 找到设它的那一行改好，再升级。红字会说明是哪种情况；它说 `systemctl daemon-reload` 失败时，
先让它成功再升级。systemd 里还没有 Sing2 这个服务时（全新安装、卸载后重装），只检查 `memlimit.conf`，你自己的
其它 drop-in 查不到。

取值前要知道的：

- 这是 Go 运行时的**软**上限，不是硬上限。Go 运行时管理的内存（主要是堆）接近它时，Go 会更勤地
  回收，**用 CPU 换内存**；已经在用的内存它压不下来，超过了进程也不会因此被杀。进程的 RSS 比这个
  值略高是正常的（二进制本身等不计入）。
- 2 GB 内存的机器上 `1400MiB`～`1500MiB` 是合理的值。
- **不要低于节点平稳运行时真正需要的内存**——参照的是它跑稳之后、回收后的低点，不是峰值。低于
  那个量，回收会一直跑、CPU 升高，内存照样降不下来。设置时如果低于 Sing2 当前的占用（RSS），脚本
  会提醒；RSS 里还含着没回收的垃圾，低于它不一定有问题——重启后观察几分钟 CPU 与内存再定。
- 只认 Go 的写法：正整数加可选单位 `B` / `KiB` / `MiB` / `GiB` / `TiB`，**区分大小写**，
  不写单位就是字节：`1500` 是 1500 字节，不是 1500 MiB（脚本会明说，显示时也会标出来）。
  不支持小数（`1.5GiB` 请写 `1536MiB`），`M`、`G`、`MB`、`GB` 都不认。
  写错的值会被拒绝、什么都不改——Go 遇到写错的值会直接起不来，所以脚本先拦住。
- 低于 `256MiB`、或高于本机内存总量时会提醒，但照样写入。

设置写在 systemd 的 drop-in 里，**不改 `Sing2.service` 本身**，所以升级重写 unit 时不会丢：

```
# /etc/systemd/system/Sing2.service.d/memlimit.conf
[Service]
Environment=GOMEMLIMIT=1500MiB
```

改值、取消都用 `sing2 memlimit`：它先校验写法再写入。**不要手改这个文件**——Go 不认的写法
（比如 `1500M`）会让 Sing2 一启动就退出、反复重启；真手改过，重启之前先跑一次 `sing2 memlimit`
看一眼，写法不对它会标红，`sing2 memlimit <值>` 会把文件整份重写。**也不要从别处 `mv` 一个文件
进来**：SELinux 上它会带着原来的标签，systemd 读不了，会把整个 `Sing2.service` 当成坏的（真遇上了，
`sing2` 的命令与安装脚本会把这个文件的标签改回来）。确认是否用上了：`systemctl show -p Environment Sing2` 看
systemd 会给什么，`sing2 memlimit` 还会对照运行中的进程。同一目录下你自己放的其它 drop-in 文件
一概不碰；卸载时只删 `memlimit.conf`，目录空了才连目录一起删。

`memlimit.conf` 里只该有 `[Service]` 和一行 `Environment=GOMEMLIMIT=<值>`（注释、空行不算）。你在里面
加了别的设置（比如 `MemoryMax=`，或者同一行再设一个变量），脚本就不改也不删这个文件：设置、取消会被
拒绝（退出码 1），卸载时它连同目录一起留下，查看时显示「memlimit.conf 里有不是本脚本写的内容」。把那些
设置挪到另一个 drop-in（例如 `systemctl edit Sing2` 写的 `override.conf`），再设置或取消即可。

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
