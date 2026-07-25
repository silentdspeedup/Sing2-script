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
    tmpf=$(mktemp) || return 1
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

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat ca-certificates -y
    else
        apt-get update -y
        apt-get install wget curl unzip tar cron socat ca-certificates -y
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    [[ ! -f /etc/systemd/system/Sing2.service ]] && return 2
    local temp
    temp=$(systemctl is-active Sing2 2>/dev/null)
    [[ x"${temp}" == x"active" ]] && return 0 || return 1
}

install_Sing2() {
    local last_version url
    if [[ $# -eq 0 ]]; then
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
        echo -e "开始安装 Sing2 ${green}${last_version}${plain}"
    fi
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

    # systemd unit：优先用压缩包里的（离线可用），拿不到再回落到脚本仓库
    if [[ -f "${tmp}/unpacked/Sing2.service" ]]; then
        install -m 644 "${tmp}/unpacked/Sing2.service" /etc/systemd/system/Sing2.service
    elif ! fetch "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/Sing2.service" \
        /etc/systemd/system/Sing2.service; then
        echo -e "${red}获取 Sing2.service 失败${plain}"
        exit 1
    fi
    chmod 644 /etc/systemd/system/Sing2.service

    systemctl daemon-reload

    # 校验 systemd 确实登记了这个 unit。不验的话，一个写坏/写空的 unit 文件会让
    # 后续所有「文件在不在」式的判断都误报"已安装"，而 systemctl 一直说 not found
    # —— 正是最难排查的那种状态。
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^Sing2\.service'; then
        echo -e "${red}systemd 未能识别 Sing2.service${plain}"
        echo -e "  unit 文件前几行："
        sed -n '1,6p' /etc/systemd/system/Sing2.service 2>/dev/null | sed 's/^/    /'
        echo -e "  请连同 ${green}systemctl status Sing2${plain} 的输出一起反馈"
        exit 1
    fi

    systemctl enable Sing2 >/dev/null 2>&1
    echo -e "${green}Sing2 ${last_version}${plain} 安装完成，已设置开机自启"

    # 管理脚本
    if fetch "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/Sing2.sh" /usr/bin/sing2; then
        chmod +x /usr/bin/sing2
        ln -sf /usr/bin/sing2 /usr/bin/Sing2   # 大小写兼容
    else
        echo -e "${yellow}管理脚本下载失败，可稍后手动获取；不影响 Sing2 本体运行${plain}"
    fi

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
    echo "sing2 install      - 安装"
    echo "sing2 uninstall    - 卸载"
    echo "sing2 version      - 查看版本"
    echo "------------------------------------------"
}

echo -e "${green}开始安装 Sing2${plain}"
install_base
install_Sing2 "$@"
