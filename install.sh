#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sing2 一键安装脚本
#   bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh)
#   bash <(curl -Ls .../install.sh) v1.2.3     # 安装指定版本
#
# 二进制不在本仓库里，需要分发端点地址与密钥。没有的话脚本会提示输入，验证通过后
# 落盘，之后 `sing2 update` 自动读取。免交互可用 DIST_BASE= / DIST_KEY= 环境变量。
#
# 布局：
#   /usr/local/Sing2/sing2        二进制
#   /etc/Sing2/config.yml         配置（升级不覆盖）
#   /etc/Sing2/dist_base          分发端点（600）
#   /etc/Sing2/dist_key           分发密钥（600）
#   /usr/bin/sing2                管理脚本（sing2 / Sing2 大小写均可）

set -o pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

SCRIPT_REPO="silentdspeedup/Sing2-script"
INSTALL_DIR="/usr/local/Sing2"
CONF_DIR="/etc/Sing2"

DIST_BASE="${DIST_BASE:-}"
DIST_KEY="${DIST_KEY:-}"
DIST_BASE_FILE="${CONF_DIR}/dist_base"
DIST_KEY_FILE="${CONF_DIR}/dist_key"

cur_dir=$(pwd)

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须以 root 运行此脚本\n" && exit 1

# ---------- 临时目录清理 ----------
# 原先是 install_Sing2 内部 `local tmp` + `trap 'rm -rf "$tmp"' EXIT`。EXIT trap
# 在函数**返回之后**才触发，那时 local 已经销毁，trap 里的 $tmp 取的是全局作用域
# 的值。本脚本没有同名全局变量，所以实际表现只是临时目录泄漏；但只要外部环境
# 带进来一个 tmp=/某路径（脚本以 root 跑，且常以 `bash <(curl ...)` 方式继承调用
# 者的环境），这条 trap 就会递归删掉那个路径。
#
# 改法两条：变量提到全局（trap 触发时确实还在），清理走带校验的函数——只删
# mktemp 建出来的那一个，且必须落在系统临时目录下面。
tmp=""
cleanup_tmp() {
    [[ -n "$tmp" && -d "$tmp" ]] || return 0
    local base=${TMPDIR:-/tmp}
    base=${base%/}   # TMPDIR 带尾斜杠时 "$base"/* 会匹配不上
    case "$tmp" in
        "$base"/*|/tmp/*|/var/tmp/*) rm -rf -- "$tmp" ;;
        *) echo -e "${yellow}临时目录路径不在预期范围内，未删除：${tmp}${plain}" ;;
    esac
    tmp=""
}
trap cleanup_tmp EXIT

# ---------- 系统识别 ----------
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif grep -Eqi "debian" /etc/issue 2>/dev/null; then
    release="debian"
elif grep -Eqi "ubuntu" /etc/issue 2>/dev/null; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /etc/issue 2>/dev/null; then
    release="centos"
elif grep -Eqi "debian" /proc/version 2>/dev/null; then
    release="debian"
elif grep -Eqi "ubuntu" /proc/version 2>/dev/null; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /proc/version 2>/dev/null; then
    release="centos"
else
    echo -e "${red}未能识别系统版本${plain}\n" && exit 1
fi

if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

case "${release}" in
    centos) [[ ${os_version} -le 6 ]] && echo -e "${red}请使用 CentOS 7 或更高版本${plain}\n" && exit 1 ;;
    ubuntu) [[ ${os_version} -lt 16 ]] && echo -e "${red}请使用 Ubuntu 16 或更高版本${plain}\n" && exit 1 ;;
    debian) [[ ${os_version} -lt 8 ]] && echo -e "${red}请使用 Debian 8 或更高版本${plain}\n" && exit 1 ;;
esac

# ---------- 架构识别 ----------
# 取值必须与发布产物的文件名一致。
detect_arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64)   echo "linux-64" ;;
        aarch64 | arm64)        echo "linux-arm64-v8a" ;;
        armv7l | armv7)         echo "linux-arm32-v7a" ;;
        armv6l)                 echo "linux-arm32-v6" ;;
        armv5tel | armv5)       echo "linux-arm32-v5" ;;
        s390x)                  echo "linux-s390x" ;;
        riscv64)                echo "linux-riscv64" ;;
        ppc64le)                echo "linux-ppc64le" ;;
        i386 | i686)            echo "linux-32" ;;
        *)                      echo "" ;;
    esac
}

arch=$(detect_arch)
if [[ -z "$arch" ]]; then
    echo -e "${red}不支持的 CPU 架构：$(uname -m)${plain}"
    echo -e "支持的架构见 https://github.com/${SCRIPT_REPO}#支持的架构"
    exit 1
fi
echo -e "架构：${green}${arch}${plain}"

# ---------- 分发端点与密钥 ----------
# 优先级：环境变量/命令行 > 落盘文件 > 交互式提示。

load_dist_config() {
    [[ -z "$DIST_BASE" && -r "$DIST_BASE_FILE" ]] &&
        DIST_BASE=$(tr -d ' \t\r\n' < "$DIST_BASE_FILE")
    [[ -z "$DIST_KEY" && -r "$DIST_KEY_FILE" ]] &&
        DIST_KEY=$(tr -d ' \t\r\n' < "$DIST_KEY_FILE")
    return 0
}

# 结尾的斜杠必须去掉：fetch() 用 `"$url" == "${DIST_BASE}/"*` 判断该不该附加认证
# 头，多一个斜杠会让所有下载都匹配不上，于是不带密钥发出去、拿一个 404，而报错
# 信息完全看不出是这个原因。省略协议时补 https。
normalize_dist_base() {
    local v
    v=$(printf '%s' "$1" | tr -d ' \t\r\n')
    [[ -n "$v" ]] || return 1
    [[ "$v" == http://* || "$v" == https://* ]] || v="https://$v"
    v=${v%/}
    [[ "$v" == *"://"?* ]] || return 1
    printf '%s' "$v"
}

# 落盘供后续 `sing2 update` 使用。先建临时文件再改权限再搬运：umask 宽松的机器上
# 直接 `> file` 会先留下一个 644 的文件，哪怕随后 chmod 也已经有一个窗口。
write_secret_file() {
    local dest=$1 value=$2 tmpf
    [[ -n "$value" ]] || return 0
    mkdir -p "${CONF_DIR}"
    tmpf=$(mktemp "${dest}.XXXXXX") || return 1
    chmod 600 "$tmpf"
    printf '%s' "$value" > "$tmpf"
    mv -f "$tmpf" "$dest" || { rm -f "$tmpf"; return 1; }
    chmod 600 "$dest"
    return 0
}

save_dist_config() {
    write_secret_file "$DIST_BASE_FILE" "$DIST_BASE" || return 1
    write_secret_file "$DIST_KEY_FILE" "$DIST_KEY" || return 1
    return 0
}

have_downloader() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

# 拿 latest 当试金石：它是最小的对象，而端点对「密钥错」与「路径不存在」返回同一个
# 404，所以「取得到」就等价于「端点和密钥都对」。
verify_dist_config() {
    local vtmp rc=1
    vtmp=$(mktemp) || return 1
    fetch "${DIST_BASE}/latest" "$vtmp" && rc=0
    rm -f "$vtmp"
    return $rc
}

# 交互式读入端点与密钥。
#
# 为什么单独找 /dev/tty 而不是直接 read：推荐用法 `bash <(curl -Ls ...)` 下 stdin
# 仍是终端，直接 read 就行；但写成 `curl -Ls ... | bash` 时 stdin 是脚本自己的字节
# 流，read 会把脚本的下一行当成输入吃掉——表现为提示一闪而过、然后拿一行 shell
# 代码去当密钥。从 /dev/tty 读则两种形式都正确。
#
# 非交互环境（无 tty，比如 CI 或 cron）不提示，直接返回 1 让调用方报错退出。在那种
# 地方卡在 read 上会变成静默挂起，比一条错误难查得多。
prompt_dist_config() {
    local tty=/dev/tty
    [[ -r "$tty" && -w "$tty" ]] || tty=""
    [[ -n "$tty" || -t 0 ]] || return 1

    echo -e "${yellow}需要分发端点与密钥才能下载 Sing2。${plain}"
    echo -e "输入一次即可——验证通过后写入 ${green}${CONF_DIR}${plain}（600），"
    echo -e "此后 ${green}sing2 update${plain} 自动读取，不再需要输入。"

    local attempt base key
    for attempt in 1 2 3; do
        # 端点回显：它不是密码，看得见才能发现打错。已有值时回车即沿用。
        if [[ -n "$DIST_BASE" ]]; then
            _prompt "$tty" "分发端点 [${DIST_BASE}]: "
        else
            _prompt "$tty" "分发端点（形如 https://example.com）: "
        fi
        _read_line "$tty" base
        if [[ -n "$base" ]]; then
            base=$(normalize_dist_base "$base") || base=""
            if [[ -z "$base" ]]; then
                echo -e "${yellow}端点格式不对${plain}（第 ${attempt}/3 次）"
                continue
            fi
            DIST_BASE="$base"
        fi
        if [[ -z "$DIST_BASE" ]]; then
            echo -e "${yellow}端点不能为空${plain}（第 ${attempt}/3 次）"
            continue
        fi

        _prompt "$tty" "分发密钥（不回显）: "
        _read_line "$tty" key silent
        if [[ -z "$key" ]]; then
            echo -e "${yellow}没有读到密钥${plain}（第 ${attempt}/3 次）"
            continue
        fi
        DIST_KEY="$key"

        # install_base 之前 curl/wget 可能都还没装，那就没法验证。此时先收下，让
        # 后面正常的下载路径去暴露问题——否则会把「本机没有下载工具」误诊成
        # 「端点或密钥错了」。
        if ! have_downloader; then
            save_dist_config && echo -e "${green}已保存${plain}（尚未验证：本机还没有 curl/wget）"
            return 0
        fi

        if verify_dist_config; then
            echo -e "${green}端点与密钥有效${plain}"
            save_dist_config ||
                echo -e "${yellow}写入 ${CONF_DIR} 失败${plain}，下次更新需要重新输入"
            return 0
        fi

        # 验证失败时无法区分是端点错还是密钥错——端点对二者返回同一个 404。所以
        # 两个都重新问，端点带上刚才的值当默认，回车即沿用。
        DIST_KEY=""
        echo -e "${red}取不到内容${plain}（第 ${attempt}/3 次）——端点不可达、端点写错、或密钥不对"
    done
    return 1
}

# 提示与读入的两个小助手：把「有 tty 就走 tty、否则走 stdin」这件事收在一处，
# 免得每个分支都写两遍。
_prompt() {
    local tty=$1 text=$2
    if [[ -n "$tty" ]]; then printf '%s' "$text" > "$tty"; else printf '%s' "$text"; fi
}

_read_line() {
    local tty=$1 __var=$2 silent=${3:-} __v
    # IFS= 关掉 read 自带的首尾裁剪，读完显式裁——粘贴带进空格或回车太常见了。
    if [[ -n "$tty" ]]; then
        if [[ -n "$silent" ]]; then IFS= read -rs __v < "$tty"; printf '\n' > "$tty"
        else IFS= read -r __v < "$tty"; fi
    else
        if [[ -n "$silent" ]]; then IFS= read -rs __v; printf '\n'
        else IFS= read -r __v; fi
    fi
    printf -v "$__var" '%s' "$(printf '%s' "$__v" | tr -d ' \t\r\n')"
}

# 在发请求之前拦住，而不是让请求打过去拿一个语焉不详的 404。
require_dist_config() {
    [[ -n "$DIST_BASE" && -n "$DIST_KEY" ]] && return 0
    prompt_dist_config && return 0
    echo -e "${red}缺少分发端点或密钥${plain}"
    echo -e "  本次带上：${green}DIST_BASE=… DIST_KEY=… bash install.sh${plain}"
    echo -e "  或写入后长期生效：${green}sing2 key${plain}"
    exit 1
}

# fetch URL → 本地文件。
#
# 两个刻意的选择：
#   - 不用 `wget --show-progress`：该选项 wget 1.16 才有，CentOS 7 自带 1.14，
#     会直接 "unrecognized option" 退出。
#   - 一律先下到临时文件再搬运：`wget -O /path` 会在**开始下载前**就把目标文件
#     创建/清空，失败时留下一个 0 字节文件。对 /etc/systemd/system/Sing2.service
#     来说，这个空文件会让后续 `[ -f ]` 判断误以为"已安装"，而 systemd 说
#     "Unit not found" —— 正是最难排查的那种状态。
fetch() {
    local url=$1 dest=$2 tmpf
    # 只给分发端点带密钥。其余 URL（raw.githubusercontent.com）本就是公开的，
    # 把密钥发过去等于白白多一处泄露面。
    local -a curl_auth=() wget_auth=()
    if [[ -n "$DIST_KEY" && "$url" == "${DIST_BASE}/"* ]]; then
        curl_auth=(-H "X-Sing2-Key: ${DIST_KEY}")
        wget_auth=(--header="X-Sing2-Key: ${DIST_KEY}")
    fi
    # 临时文件建在**目标同目录**，不要用 /tmp。
    # mv 会把源文件的 SELinux 上下文一起搬过去；从 /tmp 搬进 /etc/systemd/system 的
    # 文件会带着 user_tmp_t 标签落地，PID 1 读不了，systemd 就把这个 unit 记成 bad
    # （表现正是「list-unit-files 里有、systemctl status 说 not found」）。
    # 建在同目录则由策略的 type_transition 给出正确标签。
    tmpf=$(mktemp "${dest}.XXXXXX" 2>/dev/null) || tmpf=$(mktemp) || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 "${curl_auth[@]}" -o "$tmpf" "$url" ||
            { rm -f "$tmpf"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate "${wget_auth[@]}" -O "$tmpf" "$url" ||
            { rm -f "$tmpf"; return 1; }
    else
        echo -e "${red}系统既没有 curl 也没有 wget${plain}"
        return 1
    fi
    [[ -s "$tmpf" ]] || { rm -f "$tmpf"; return 1; }   # 空文件视为失败
    mv -f "$tmpf" "$dest" || { rm -f "$tmpf"; return 1; }
    return 0
}

# unit_is_registered —— 以 systemd 自己的说法为准。
# 注意 `list-unit-files` 会把「文件在但解析不了」的 unit 报成状态 bad，那同样算
# 没装好，所以这里要求状态不是 bad。
unit_is_registered() {
    local line
    line=$(systemctl list-unit-files 2>/dev/null | grep '^Sing2\.service' | head -1)
    [[ -n "$line" ]] || return 1
    [[ "$line" != *bad* ]] || return 1
    return 0
}

# write_builtin_unit 是自愈兜底：把一份已知可用的 unit 直接写到位。
# 刻意全 ASCII —— unit 文件由 PID 1 解析，个别 systemd 构建对非 ASCII 内容不友好。
write_builtin_unit() {
    rm -f /etc/systemd/system/Sing2.service
    cat > /etc/systemd/system/Sing2.service <<'UNIT'
[Unit]
Description=Sing2 Service
Documentation=https://github.com/silentdspeedup/Sing2-script
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/Sing2/
ExecStart=/usr/local/Sing2/sing2 serve --config /etc/Sing2/config.yml
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
}

# relabel —— SELinux 环境下必须做。
# 从 /tmp 拷进 /etc/systemd/system 的文件可能带着 tmp 的安全上下文，PID 1 读不了，
# systemd 就把这个 unit 记成 bad（表现是 list-unit-files 里有、status 说 not found）。
# 非 SELinux 系统上这两条命令不存在或无害。
relabel_unit() {
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -F /etc/systemd/system/Sing2.service >/dev/null 2>&1
    elif command -v chcon >/dev/null 2>&1; then
        chcon -t systemd_unit_file_t /etc/systemd/system/Sing2.service >/dev/null 2>&1
    fi
}

# config_log_path 取出 config.yml 里某个日志路径键的当前值（与 Sing2.sh 同名函数同规则）。
# 只认**未被注释**的值：`ErrorPath: # /etc/Sing2/error.log` 这种形状算「没配置」，
# 因为 sing2 generate 生成的就是这个形状——日志全走 journald，磁盘上没有文件。
config_log_path() {
    local key=$1 line val conf="${CONF_DIR}/config.yml"
    [[ -f "$conf" ]] || return 1
    line=$(grep -E "^[[:space:]]*${key}:" "$conf" 2>/dev/null | grep -vE "^[[:space:]]*#" | tail -1)
    [[ -n "$line" ]] || return 1
    val=${line#*:}
    val=${val%%#*}
    val=$(printf '%s' "$val" | tr -d "\"' \t\r")
    [[ -n "$val" ]] || return 1
    echo "$val"
}

# ensure_logrotate_driver —— 找出「谁会来跑 logrotate」，能修就修，找不到就说实话。
#
# 这一步在 2026-07-29 之前是缺的，而缺的正是最要紧的那一半：install_logrotate 只用
# `logrotate -d` 验证配置**能被解析**，然后就打印「日志轮转已配置」。可 logrotate 本身
# 不是守护进程，它靠系统的调度器每天叫它一次；配置写得再对，没人叫它就永远不轮转，
# 而 access.log 在有量的节点上涨得很快。于是「装完看着一切正常，一个月后磁盘满了」。
#
# 两条驱动链路，按发行版分：
#   - logrotate.timer  —— Debian 11+ / Ubuntu 21.10+ / RHEL 9+ 等较新发行版
#   - /etc/cron.daily/logrotate —— 较老的发行版，由 crond/cron 每天扫一次
# 两者都可能「文件在、服务没启用」，最小化镜像和容器里尤其常见——包管理器把包装上了
# 不等于调度器在跑。
#
# 回显驱动名到 stdout，返回 0；一个都找不到返回 1。安装器已经要求 systemd（unit 靠它），
# 所以这里可以放心用 systemctl。
ensure_logrotate_driver() {
    # 1) 发行版自带的 systemd timer。优先用它——这是 Debian 11+ / Ubuntu 21.10+ /
    #    RHEL 8+ 的正规路径，也是我们最不该去抢的那条。
    if systemctl cat logrotate.timer >/dev/null 2>&1; then
        systemctl is-active logrotate.timer >/dev/null 2>&1 ||
            systemctl enable --now logrotate.timer >/dev/null 2>&1
        if systemctl is-active logrotate.timer >/dev/null 2>&1; then
            echo "logrotate.timer"
            return 0
        fi
    fi

    # 2) cron.daily。⚠ 文件在 ≠ 会执行：Debian/Ubuntu 的 /etc/cron.daily/logrotate
    #    开头就是「systemd 当 init 就 exit 0，交给 timer」。所以在 timer 被 disable/mask
    #    的 systemd 机器上，这个脚本存在但**故意什么都不做**，把它当驱动就是报假喜。
    #    只有在它不会让位给 systemd 时才算数。
    if [[ -x /etc/cron.daily/logrotate ]] &&
       ! grep -q '/run/systemd/system' /etc/cron.daily/logrotate 2>/dev/null; then
        local svc
        for svc in crond cron; do
            systemctl cat "$svc" >/dev/null 2>&1 || continue
            systemctl is-active "$svc" >/dev/null 2>&1 ||
                systemctl enable --now "$svc" >/dev/null 2>&1
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                echo "${svc} → /etc/cron.daily/logrotate"
                return 0
            fi
        done
    fi

    # 3) 都没有：自己装一个 timer 只管我们这份配置。
    #
    # 与其去分辨 EL7 的 cron.d/0hourly→anacron→run-parts、各家 logrotate 包到底把
    # 触发器放哪、最小化镜像裁掉了什么，不如把这件事变成确定的：安装器本来就要求
    # systemd（Sing2.service 靠它），那就用 systemd。只在前两条都不成立时才装，
    # 免得和发行版自己的轮转重复触发——日内两次轮转会撞上 dateext 的同名文件。
    cat > /etc/systemd/system/Sing2-logrotate.service <<'UNIT'
[Unit]
Description=Rotate Sing2 logs
Documentation=https://github.com/silentdspeedup/Sing2-script

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/Sing2
UNIT
    cat > /etc/systemd/system/Sing2-logrotate.timer <<'UNIT'
[Unit]
Description=Daily rotation of Sing2 logs

[Timer]
OnCalendar=daily
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    # logrotate 未必在 /usr/sbin。ExecStart 路径错了 systemd 会把 unit 记成 bad，
    # 那就又回到「装了但不跑」，所以按实际位置修正。
    local lr
    lr=$(command -v logrotate 2>/dev/null)
    if [[ -n "$lr" && "$lr" != "/usr/sbin/logrotate" ]]; then
        sed -i "s#^ExecStart=.*#ExecStart=${lr} /etc/logrotate.d/Sing2#" \
            /etc/systemd/system/Sing2-logrotate.service
    fi
    systemctl daemon-reload >/dev/null 2>&1
    if systemctl enable --now Sing2-logrotate.timer >/dev/null 2>&1 &&
       systemctl is-active Sing2-logrotate.timer >/dev/null 2>&1; then
        echo "Sing2-logrotate.timer（本脚本自建——系统没有可用的轮转驱动）"
        return 0
    fi
    rm -f /etc/systemd/system/Sing2-logrotate.timer /etc/systemd/system/Sing2-logrotate.service
    systemctl daemon-reload >/dev/null 2>&1
    return 1
}

# install_logrotate 生成 /etc/logrotate.d/Sing2。
#
# 几个选择的理由：
#   copytruncate  —— **必须**。Sing2 全程持有日志 fd，默认的 create 模式会 rename
#                    旧文件再建新文件，而 Sing2 仍写向那个已被改名的 inode，轮转后
#                    新文件永远是空的。代价是 cp 与 truncate 之间有个极窄的写入窗口
#                    可能丢几行——对访问日志可以接受。
#   不加 delaycompress —— 那是给 create 模式用的（进程还握着旧 fd，压缩会压到半截）。
#                    copytruncate 下副本在压缩前就已完整，加了只是白留一个未压缩文件。
#   dateext       —— 轮转出 access.log-20260726.gz 而不是 access.log.1.gz，按日期
#                    找日志比按序号直观，且序号会随每次轮转平移。
#   noolddir      —— 就地保留，不搬到别处（与 XrayR 习惯一致）。
#   maxsize       —— 见下方注释：只有在 logrotate 跑得比每天更勤时才有额外意义。
#
# 路径与 config.yml 里 Log.AccessPath / Log.ErrorPath 的出厂值一一对应，
# 都固定在 ${CONF_DIR} 下。改了配置里的路径就自己调这份文件。
install_logrotate() {
    command -v logrotate >/dev/null 2>&1 || {
        echo -e "${yellow}未安装 logrotate，跳过日志轮转配置${plain}"
        return 0
    }

    # 路径取 config.yml 里**实际配置**的值，取不到才回落到出厂路径。
    # 这里长期是硬编码的，而函数头和 README 都写着「从 config.yml 读实际路径」——
    # 于是改过 Log.AccessPath 的人以为轮转跟着走了，实际上轮转盯着两个不存在的
    # 文件空转（missingok 让它连句话都不说），真正在涨的那个没人管。
    local access error
    access=$(config_log_path AccessPath) || access="${CONF_DIR}/access.log"
    error=$(config_log_path ErrorPath) || error="${CONF_DIR}/error.log"

    cat > /etc/logrotate.d/Sing2 <<EOF
${access}
${error}
{
    daily
    rotate 7
    compress
    copytruncate
    dateext
    dateformat -%Y%m%d
    notifempty
    missingok
    noolddir
    su root root
    # 上限保护。注意：系统的 logrotate 通常每天只跑一次（cron.daily 或
    # logrotate.timer），此时 maxsize 不会在日内提前触发。访问日志涨得快的
    # 节点可以让它跑得更勤，见 README「日志轮转」一节——但**先把上面的
    # dateformat 加上小时**（-%Y%m%d%H），否则日内第二次轮转会撞上已存在的
    # 同名文件，logrotate 直接 skip，改勤了反而不轮转。
    maxsize 512M
}
EOF
    chmod 644 /etc/logrotate.d/Sing2

    # 语法自检：写坏了会让**系统全部**日志轮转任务一起失败，不能只写不验。
    if ! logrotate -d /etc/logrotate.d/Sing2 >/dev/null 2>&1; then
        echo -e "${red}logrotate 配置自检未通过${plain}，已删除以免影响系统其它轮转任务："
        logrotate -d /etc/logrotate.d/Sing2 2>&1 | sed 's/^/  /' | head -10
        rm -f /etc/logrotate.d/Sing2
        return 0
    fi

    # 配置能解析 ≠ 会被执行。没有驱动就别报喜——那句「已配置」会让运维不再管这件事，
    # 而真相是日志会一直涨到磁盘满。
    local driver
    if driver=$(ensure_logrotate_driver); then
        echo -e "${green}日志轮转已配置${plain}：${access}、${error}（每天，保留 7 份，gzip 压缩，就地存放）"
        echo -e "  由 ${green}${driver}${plain} 触发。logrotate 不是常驻进程，也不在 crontab 里——"
        echo -e "  要确认它真的会跑：${green}sing2 status${plain}（会显示驱动与上次轮转时间）"
        # 轮转配置正确 ≠ 有东西可轮转。sing2 generate 默认把两个日志路径都注释掉，
        # 日志全进 journald，磁盘上根本没有这两个文件。不点破的话，用户会去
        # /etc/Sing2 找 .gz 找不到，然后得出「轮转坏了」——症状和真坏一模一样。
        if ! config_log_path AccessPath >/dev/null && ! config_log_path ErrorPath >/dev/null; then
            echo -e "  ${yellow}注意：当前 config.yml 没有启用文件日志${plain}（Log.AccessPath / Log.ErrorPath 均为空），"
            echo -e "  日志全部走 journald，这份轮转配置暂时空转。填上路径后自动生效。"
        fi
    else
        echo -e "${yellow}日志轮转配置已写入，但系统上没有任何东西会执行它${plain}"
        echo -e "  ${access}、${error} 会一直增长直到写满磁盘。"
        echo -e "  既没有可用的 ${green}logrotate.timer${plain}，也没有在跑的 cron 提供 /etc/cron.daily。"
        echo -e "  处理：装上并启用其一，例如 ${green}systemctl enable --now logrotate.timer${plain}；"
        echo -e "  容器/最小化镜像里也可以由宿主定期执行 ${green}logrotate /etc/logrotate.d/Sing2${plain}"
    fi
}

# install_unit 把 unit 装好并**验证 systemd 真的能用它**，不行就自愈重写。
# 只写文件不验证，会把「装了但起不来」这种最难查的状态留给用户。
install_unit() {
    local src=$1

    rm -f /etc/systemd/system/Sing2.service
    if [[ -f "$src" ]]; then
        install -m 644 "$src" /etc/systemd/system/Sing2.service
    elif ! fetch "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/Sing2.service" \
        /etc/systemd/system/Sing2.service; then
        echo -e "${yellow}获取 Sing2.service 失败，改用内置版本${plain}"
        write_builtin_unit
    fi
    chmod 644 /etc/systemd/system/Sing2.service
    relabel_unit
    systemctl daemon-reload

    if unit_is_registered; then
        return 0
    fi

    # 第一次没成：换内置 ASCII 版本 + 重新打标签再试一次。
    echo -e "${yellow}systemd 未接受该 unit 文件，改用内置版本重试……${plain}"
    write_builtin_unit
    chmod 644 /etc/systemd/system/Sing2.service
    relabel_unit
    systemctl daemon-reload

    if unit_is_registered; then
        echo -e "${green}内置 unit 生效${plain}"
        return 0
    fi

    echo -e "${red}systemd 仍不接受 Sing2.service${plain}"
    echo -e "  状态：$(systemctl list-unit-files 2>/dev/null | grep '^Sing2\.service' || echo '未登记')"
    echo -e "  SELinux：$(getenforce 2>/dev/null || echo 'N/A')"
    echo -e "  上下文：$(ls -Z /etc/systemd/system/Sing2.service 2>/dev/null)"
    echo -e "  请把以上输出连同 ${green}journalctl -b -u systemd --no-pager | tail -30${plain} 一起反馈"
    exit 1
}

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat ca-certificates logrotate -y
    else
        apt-get update -y
        apt-get install wget curl unzip tar cron socat ca-certificates logrotate -y
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    [[ ! -f /etc/systemd/system/Sing2.service ]] && return 2
    local temp
    temp=$(systemctl is-active Sing2 2>/dev/null)
    [[ x"${temp}" == x"active" ]] && return 0 || return 1
}

# 管理脚本与 Sing2 本体的发版节奏不同（脚本改一行不值得给本体打 tag），
# 所以"本体已是最新"时也要刷新它，否则脚本层的修复就永远推不下去。
install_manager() {
    if fetch "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/Sing2.sh" /usr/bin/sing2; then
        chmod +x /usr/bin/sing2
        ln -sf /usr/bin/sing2 /usr/bin/Sing2   # 大小写兼容
    else
        echo -e "${yellow}管理脚本下载失败，可稍后手动获取；不影响 Sing2 本体运行${plain}"
    fi
}

# 已安装版本。以二进制自报为准而不是记在某个文件里——文件会和实际装的东西脱节。
# `sing2 version` 打印 "sing2 v0.0.2"；本地 make build 出来的是 "dev"，
# 那种情况当作未知，照常重装。
installed_version() {
    [[ -x "${INSTALL_DIR}/sing2" ]] || return 1
    local v
    v=$("${INSTALL_DIR}/sing2" version 2>/dev/null | awk '{print $2}')
    [[ -n "$v" && "$v" != "dev" ]] || return 1
    echo "$v"
}

install_Sing2() {
    local last_version url
    # 空串必须当成"没指定版本"。`sing2 update` 直接回车会把一个空参数一路传到这里，
    # 而老逻辑只看 $#，于是拼出 .../download//Sing2-linux-64.zip 然后 404。
    if [[ $# -eq 0 || -z "$1" ]]; then
        # 版本号取自端点上的 latest 对象。它在一个版本的全部产物上传成功之后才
        # 更新，所以这里读到的版本号对应的资产必然是齐的。
        require_dist_config
        local vtmp
        vtmp=$(mktemp) || { echo -e "${red}无法创建临时文件${plain}"; exit 1; }
        if fetch "${DIST_BASE}/latest" "$vtmp"; then
            last_version=$(tr -d ' \t\r\n' < "$vtmp")
        fi
        rm -f "$vtmp"
        if [[ -z "$last_version" ]]; then
            echo -e "${red}获取 Sing2 最新版本失败${plain}"
            echo -e "  分发端点不可达，或密钥无效——密钥错误与路径不存在返回的是同一个 404。"
            echo -e "  端点：${yellow}${DIST_BASE}${plain}"
            echo -e "  可手动指定版本：${yellow}bash install.sh v1.0.0${plain}"
            exit 1
        fi
        echo -e "检测到最新版本：${green}${last_version}${plain}，开始安装"
    else
        last_version=$1
        # release tag 一律带 v 前缀，允许用户少打这个 v（0.0.2 → v0.0.2）。
        [[ "$last_version" =~ ^[0-9] ]] && last_version="v${last_version}"
        echo -e "开始安装 Sing2 ${green}${last_version}${plain}"
    fi

    # 兜底：宁可在这里停，也不要把空版本号拼进 URL 再去问 GitHub 要 404。
    if [[ -z "$last_version" ]]; then
        echo -e "${red}版本号为空，拒绝拼接下载地址${plain}"
        exit 1
    fi
    # 同版本不重装。退出码 10 是给 Sing2.sh 的信号，让它别报"更新完成"。
    local current
    current=$(installed_version) || current=""
    if [[ -n "$current" && "$current" == "$last_version" && "${FORCE}" != "1" ]]; then
        echo -e "${green}当前已是 ${last_version}，无需更新${plain}"
        install_manager
        # 同版本路径也要跑：脚本层的修复本来就靠 `sing2 update` 下发（install_manager
        # 就是为此才放在这里）。轮转配置同理——它可能被手删了、或者装的时候机器上
        # 还没有可用的驱动。不在这里补，用户就只能靠 --force 重装本体才能修一份
        # 与本体无关的配置。幂等，重复跑无副作用。
        install_logrotate
        echo -e "如需强制重装本体：${yellow}bash install.sh ${last_version} --force${plain}"
        exit 10
    fi
    [[ -n "$current" ]] && echo -e "当前版本：${yellow}${current}${plain} → ${green}${last_version}${plain}"

    require_dist_config
    url="${DIST_BASE}/${last_version}/Sing2-${arch}.zip"

    # 下载到临时目录再落盘：直接删 INSTALL_DIR 会在下载失败时把一个能跑的节点
    # 变成一个删干净的节点。
    # tmp **刻意不声明成 local**：清理由文件头的 cleanup_tmp/EXIT trap 负责，而
    # EXIT 在函数返回之后才触发，那时 local 已经销毁。
    tmp=$(mktemp -d) || { echo -e "${red}无法创建临时目录${plain}"; exit 1; }

    echo -e "下载：${url}"
    if ! fetch "${url}" "${tmp}/Sing2.zip"; then
        echo -e "${red}下载失败${plain}——请确认该版本存在、密钥正确，且服务器能访问分发端点"
        echo -e "  分发端点对「密钥错误」与「版本不存在」返回同一个 404，无法从响应上区分。"
        exit 1
    fi

    # 校验和验证。每个 zip 旁边都有一个同名 .dgst，内容形如 `SHA256= <hex>`。
    # 拿不到 .dgst 时降级为不验证而非失败：它是加固措施，不该让一个次要对象缺失
    # 把安装拦死。
    if fetch "${url}.dgst" "${tmp}/Sing2.zip.dgst" && command -v sha256sum >/dev/null 2>&1; then
        local want got
        # ⚠ 标签形态随 openssl 大版本变：3.x 打印 "SHA2-256= <hex>"，1.1.1 打印
        # "SHA256= <hex>"。旧版本的 .dgst 是当时的构建机生成的，而装回旧版本是
        # 允许的，所以两种都必须认。
        # 末尾再要求 64 位十六进制：匹配到意外的行时宁可判定为"没有期望值"（降级
        # 为不验证），也不要拿一段垃圾去比对然后报一个假的校验失败。
        want=$(grep -iE '^SHA-?2?-?256=' "${tmp}/Sing2.zip.dgst" 2>/dev/null |
            awk '{print $NF}' | grep -iE '^[0-9a-f]{64}$' | head -1)
        got=$(sha256sum "${tmp}/Sing2.zip" | awk '{print $1}')
        if [[ -n "$want" && "$want" != "$got" ]]; then
            echo -e "${red}校验和不匹配，拒绝安装${plain}"
            echo -e "  期望：${want}"
            echo -e "  实际：${got}"
            exit 1
        fi
        [[ -n "$want" ]] && echo -e "校验和：${green}sha256 匹配${plain}"
    else
        echo -e "${yellow}未能校验 sha256${plain}（.dgst 不可用或系统无 sha256sum），继续安装"
    fi

    if ! unzip -q -o "${tmp}/Sing2.zip" -d "${tmp}/unpacked"; then
        echo -e "${red}解压失败，下载的文件可能不完整${plain}"
        exit 1
    fi
    if [[ ! -f "${tmp}/unpacked/sing2" ]]; then
        echo -e "${red}压缩包里没有 sing2 二进制${plain}"
        exit 1
    fi

    # 升级场景：先停服务再换二进制，避免 ETXTBSY
    if check_status; then
        systemctl stop Sing2
    fi

    mkdir -p "${INSTALL_DIR}" "${CONF_DIR}"
    # 端点与密钥落盘，供后续 `sing2 update` 免输使用。放在这里而不是更早：只有确实
    # 下载成功过，才说明这两个值是对的，值得存。交互式那条路在验证通过时已经存过，
    # 这里覆盖的是环境变量／命令行参数那条路；已经存在就不再重复报喜。
    local was_stored=0
    [[ -s "$DIST_KEY_FILE" && -s "$DIST_BASE_FILE" ]] && was_stored=1
    if save_dist_config; then
        [[ $was_stored == 1 ]] ||
            echo -e "分发端点与密钥已保存到 ${green}${CONF_DIR}${plain}（600），后续 ${green}sing2 update${plain} 不再需要提供"
    else
        echo -e "${yellow}写入 ${CONF_DIR} 失败${plain}，下次更新需要重新提供"
    fi
    install -m 755 "${tmp}/unpacked/sing2" "${INSTALL_DIR}/sing2"

    install_unit "${tmp}/unpacked/Sing2.service"

    systemctl enable Sing2 >/dev/null 2>&1
    echo -e "${green}Sing2 ${last_version}${plain} 安装完成，已设置开机自启"

    install_manager

    # 配置：全新安装才铺示例，升级绝不覆盖
    if [[ ! -f "${CONF_DIR}/config.yml" ]]; then
        if [[ -f "${tmp}/unpacked/config.yml" ]]; then
            cp "${tmp}/unpacked/config.yml" "${CONF_DIR}/config.yml"
        fi
        chmod 600 "${CONF_DIR}/config.yml" 2>/dev/null
        echo
        echo -e "${yellow}全新安装：请先编辑 ${CONF_DIR}/config.yml 填入面板地址、ApiKey、NodeID${plain}"
        echo -e "${yellow}可执行 ${green}sing2 config${yellow} 编辑，或 ${green}sing2 generate${yellow} 用向导生成${plain}"
    else
        echo -e "检测到已有配置，保留 ${CONF_DIR}/config.yml 不动"
        systemctl start Sing2
        sleep 2
        if check_status; then
            echo -e "${green}Sing2 重启成功${plain}"
        else
            echo -e "${red}Sing2 可能启动失败${plain}，请用 ${green}sing2 log${plain} 查看日志"
        fi
    fi

    # 日志轮转。放在配置落地之后——它要从 config.yml 里读实际的日志路径。
    install_logrotate

    cd "$cur_dir" || exit 1
    rm -f install.sh

    echo
    echo "Sing2 管理脚本用法（sing2 / Sing2 均可）："
    echo "------------------------------------------"
    echo "sing2              - 显示管理菜单"
    echo "sing2 start        - 启动"
    echo "sing2 stop         - 停止"
    echo "sing2 restart      - 重启"
    echo "sing2 status       - 查看状态"
    echo "sing2 enable       - 设置开机自启"
    echo "sing2 disable      - 取消开机自启"
    echo "sing2 log [all]    - 合并查看全部运行日志（默认）"
    echo "sing2 log runtime  - 只看运行状态，排除逐连接错误"
    echo "sing2 log access   - 只看用户连接记录"
    echo "sing2 log failures - 只看连接失败、DNS 错误和超时"
    echo "sing2 config       - 编辑配置文件"
    echo "sing2 generate     - 生成配置文件（向导）"
    echo "sing2 x25519       - 生成 REALITY 密钥对"
    echo "sing2 update       - 更新到最新版"
    echo "sing2 update x.x.x - 更新到指定版本"
    echo "sing2 update -f    - 强制重装当前版本"
    echo "sing2 key          - 写入/轮换分发密钥"
    echo "sing2 install      - 安装"
    echo "sing2 uninstall    - 卸载"
    echo "sing2 version      - 查看版本"
    echo "------------------------------------------"
}

# 选项从参数里摘出来，剩下的才是版本号。
FORCE=0
declare -a install_args=()
expect=""
for a in "$@"; do
    if [[ -n "$expect" ]]; then
        printf -v "$expect" '%s' "$a"
        expect=""
        continue
    fi
    case "$a" in
        -f|--force)     FORCE=1 ;;
        --dist-key)     expect=DIST_KEY ;;
        --dist-key=*)   DIST_KEY="${a#*=}" ;;
        --dist-base)    expect=DIST_BASE ;;
        --dist-base=*)  DIST_BASE="${a#*=}" ;;
        "")             ;;   # 空参数忽略：`sing2 update` 回车曾把空串一路传下来
        *)              install_args+=("$a") ;;
    esac
done

# 环境变量/命令行给的端点也要过一遍规整（补协议、去尾斜杠），否则 fetch() 的前缀
# 判断会失配。
if [[ -n "$DIST_BASE" ]]; then
    DIST_BASE=$(normalize_dist_base "$DIST_BASE") || {
        echo -e "${red}DIST_BASE 格式不对${plain}"
        exit 1
    }
fi

# 环境变量/命令行没给就读落盘文件。要在 install_Sing2 之前，fetch() 靠这两个值
# 决定 URL 与是否附加认证头。
load_dist_config

# 索取放在 install_base **之前**：装包要好几分钟，让人等完再被问、输错了又得从头
# 来，是最难受的顺序。已有值时这里是空操作，所以 `sing2 update` 不会多出一次提问。
require_dist_config

echo -e "${green}开始安装 Sing2${plain}"
install_base
install_Sing2 "${install_args[@]}"
