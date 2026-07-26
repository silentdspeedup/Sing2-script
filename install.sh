#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sing2 一键安装脚本
#   bash <(curl -Ls https://raw.githubusercontent.com/silentdspeedup/Sing2-script/master/install.sh)
#   bash <(curl -Ls .../install.sh) v1.2.3     # 安装指定版本
#
# 布局（与 Sing2.service / Sing2.sh 一致）：
#   /usr/local/Sing2/sing2        二进制
#   /etc/Sing2/config.yml         配置（升级不覆盖）
#   /usr/bin/sing2                管理脚本（sing2 / Sing2 大小写均可）

set -o pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

REPO="silentdspeedup/Sing2"
SCRIPT_REPO="silentdspeedup/Sing2-script"
INSTALL_DIR="/usr/local/Sing2"
CONF_DIR="/etc/Sing2"

cur_dir=$(pwd)

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须以 root 运行此脚本\n" && exit 1

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
# 取值必须与发布产物名一致（Sing2 .github/build/friendly-filenames.json）。
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
    echo -e "已发布的架构见 https://github.com/${REPO}/releases"
    exit 1
fi
echo -e "架构：${green}${arch}${plain}"

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
    # 临时文件建在**目标同目录**，不要用 /tmp。
    # mv 会把源文件的 SELinux 上下文一起搬过去；从 /tmp 搬进 /etc/systemd/system 的
    # 文件会带着 user_tmp_t 标签落地，PID 1 读不了，systemd 就把这个 unit 记成 bad
    # （表现正是「list-unit-files 里有、systemctl status 说 not found」）。
    # 建在同目录则由策略的 type_transition 给出正确标签。
    tmpf=$(mktemp "${dest}.XXXXXX" 2>/dev/null) || tmpf=$(mktemp) || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 -o "$tmpf" "$url" || { rm -f "$tmpf"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate -O "$tmpf" "$url" || { rm -f "$tmpf"; return 1; }
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
Documentation=https://github.com/silentdspeedup/Sing2
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

    local access="${CONF_DIR}/access.log"
    local error="${CONF_DIR}/error.log"

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
    # 节点可以让它跑得更勤，见 README「日志轮转」一节。
    maxsize 512M
}
EOF
    chmod 644 /etc/logrotate.d/Sing2

    # 语法自检：写坏了会让**系统全部**日志轮转任务一起失败，不能只写不验。
    if logrotate -d /etc/logrotate.d/Sing2 >/dev/null 2>&1; then
        echo -e "${green}日志轮转已配置${plain}：${access}、${error}（每天，保留 7 份，gzip 压缩，就地存放）"
    else
        echo -e "${red}logrotate 配置自检未通过${plain}，已删除以免影响系统其它轮转任务："
        logrotate -d /etc/logrotate.d/Sing2 2>&1 | sed 's/^/  /' | head -10
        rm -f /etc/logrotate.d/Sing2
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
        last_version=$(curl -Ls "https://api.github.com/repos/${REPO}/releases/latest" |
            grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$last_version" ]]; then
            echo -e "${red}获取 Sing2 最新版本失败${plain}（可能触发了 GitHub API 限流）"
            echo -e "可手动指定版本：${yellow}bash install.sh v1.0.0${plain}"
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
        echo -e "如需强制重装本体：${yellow}bash install.sh ${last_version} --force${plain}"
        exit 10
    fi
    [[ -n "$current" ]] && echo -e "当前版本：${yellow}${current}${plain} → ${green}${last_version}${plain}"

    url="https://github.com/${REPO}/releases/download/${last_version}/Sing2-${arch}.zip"

    # 下载到临时目录再落盘：直接删 INSTALL_DIR 会在下载失败时把一个能跑的节点
    # 变成一个删干净的节点。
    local tmp
    tmp=$(mktemp -d) || { echo -e "${red}无法创建临时目录${plain}"; exit 1; }
    trap 'rm -rf "$tmp"' EXIT

    echo -e "下载：${url}"
    if ! fetch "${url}" "${tmp}/Sing2.zip"; then
        echo -e "${red}下载失败${plain}——请确认该版本存在，且服务器能访问 GitHub"
        exit 1
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
    echo "sing2 log          - 查看日志"
    echo "sing2 config       - 编辑配置文件"
    echo "sing2 generate     - 生成配置文件（向导）"
    echo "sing2 x25519       - 生成 REALITY 密钥对"
    echo "sing2 update       - 更新到最新版"
    echo "sing2 update x.x.x - 更新到指定版本"
    echo "sing2 update -f    - 强制重装当前版本"
    echo "sing2 install      - 安装"
    echo "sing2 uninstall    - 卸载"
    echo "sing2 version      - 查看版本"
    echo "------------------------------------------"
}

# --force/-f 从版本号里摘出来，剩下的才是版本号。
FORCE=0
declare -a install_args=()
for a in "$@"; do
    case "$a" in
        -f|--force) FORCE=1 ;;
        "")         ;;   # 空参数忽略：`sing2 update` 回车曾把空串一路传下来
        *)          install_args+=("$a") ;;
    esac
done

echo -e "${green}开始安装 Sing2${plain}"
install_base
install_Sing2 "${install_args[@]}"
