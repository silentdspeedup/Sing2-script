#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sing2 管理脚本。安装后位于 /usr/bin/sing2（并软链 /usr/bin/Sing2）。
#
# 布局：
#   /usr/local/Sing2/sing2   二进制
#   /etc/Sing2/config.yml    配置
#   Sing2.service            systemd 单元

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

SCRIPT_REPO="silentdspeedup/Sing2-script"
BIN="/usr/local/Sing2/sing2"
CONF_DIR="/etc/Sing2"
CONF="${CONF_DIR}/config.yml"
# 分发端点与密钥。本脚本只负责写入与展示，实际使用它们的是 install.sh。
DIST_BASE_FILE="${CONF_DIR}/dist_base"
DIST_KEY_FILE="${CONF_DIR}/dist_key"
SERVICE="Sing2"

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

confirm() {
    if [[ $# -gt 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        [[ x"${temp}" == x"" ]] && temp=$2
    else
        read -rp "$1 [y/n]: " temp
    fi
    [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]] && return 0 || return 1
}

confirm_restart() {
    confirm "是否重启 Sing2" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/install.sh")
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    # 空参数一律丢掉：install.sh 会把空串当成版本号拼进下载地址
    # （.../download//Sing2-*.zip → 404）。"用最新版"的正确表达是不传参数。
    local -a passthru=()
    if [[ $# == 0 ]]; then
        local version
        echo && echo -n -e "输入指定版本(默认最新版，加 -f 强制重装): " && read -r version
        for a in ${version}; do passthru+=("$a"); done
    else
        shift   # 去掉菜单标记位
        local a
        for a in "$@"; do [[ -n "$a" ]] && passthru+=("$a"); done
    fi

    bash <(curl -Ls "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/install.sh") "${passthru[@]}"
    local rc=$?
    case $rc in
        0)  echo -e "${green}更新完成，已自动重启 Sing2，请用 sing2 log 查看运行日志${plain}"
            exit ;;
        10) ;;  # 已是最新，install.sh 自己说过了，别再报"更新完成"
        *)  ;;  # 失败，install.sh 已经打印过原因
    esac
    [[ $# == 0 ]] && before_show_menu
}

# 写文件：先建临时文件再改权限再搬运。umask 宽松的机器上直接 `> file` 会先留下一个
# 644 的文件，哪怕随后 chmod 也已经有一个窗口。
write_secret_file() {
    local dest=$1 value=$2 tmpf
    mkdir -p "${CONF_DIR}"
    tmpf=$(mktemp "${dest}.XXXXXX") || return 1
    chmod 600 "$tmpf"
    printf '%s' "$value" > "$tmpf"
    mv -f "$tmpf" "$dest" || { rm -f "$tmpf"; return 1; }
    chmod 600 "$dest"
    return 0
}

# dist_key —— 写入/轮换分发端点与密钥。
#
# 用 read -rs 读密钥而不是接命令行参数：那是最常见的泄露方式（shell history、
# ps 的命令行都是可读的）。端点则回显，看得见才能发现打错。
dist_key() {
    local base key confirm_key cur

    if [[ -s "$DIST_BASE_FILE" ]]; then
        cur=$(tr -d ' \t\r\n' < "$DIST_BASE_FILE")
        echo -e "当前端点：${green}${cur}${plain}"
    else
        cur=""
        echo -e "当前${yellow}未设置${plain}端点"
    fi
    echo -n "输入端点（回车沿用当前值）: "
    read -r base
    base=$(printf '%s' "$base" | tr -d ' \t\r\n')
    [[ -z "$base" ]] && base="$cur"
    if [[ -z "$base" ]]; then
        echo -e "${red}端点不能为空${plain}，未做改动"
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi
    [[ "$base" == http://* || "$base" == https://* ]] || base="https://$base"
    base=${base%/}   # 结尾斜杠会让下载时的前缀判断失配，认证头就带不上

    if [[ -s "$DIST_KEY_FILE" ]]; then
        cur=$(tr -d ' \t\r\n' < "$DIST_KEY_FILE")
        # 只回显首尾各 4 位：足够确认「是不是同一把」，又不至于把整把打到屏幕上
        # （运维经常在录屏或共享终端里跑这个）。
        echo -e "当前密钥：${green}${cur:0:4}…${cur: -4}${plain}（长度 ${#cur}）"
    else
        echo -e "当前${yellow}未设置${plain}密钥"
    fi
    echo -n "输入新密钥（留空取消，输入时不回显）: "
    read -rs key
    echo
    key=$(printf '%s' "$key" | tr -d ' \t\r\n')
    if [[ -z "$key" ]]; then
        echo -e "${yellow}已取消，未做改动${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 0
    fi
    echo -n "再输入一次确认: "
    read -rs confirm_key
    echo
    confirm_key=$(printf '%s' "$confirm_key" | tr -d ' \t\r\n')
    if [[ "$key" != "$confirm_key" ]]; then
        echo -e "${red}两次输入不一致，未做改动${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi

    if ! write_secret_file "$DIST_BASE_FILE" "$base" ||
       ! write_secret_file "$DIST_KEY_FILE" "$key"; then
        echo -e "${red}写入失败${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi
    echo -e "${green}已写入 ${CONF_DIR}${plain}（600，仅 root 可读）"
    echo -e "验证：${green}sing2 update${plain}——不对会在下载前报错，不会动到现有安装"
    [[ $# == 0 ]] && before_show_menu
}

config() {
    echo "编辑配置文件后将自动重启 Sing2"
    ${EDITOR:-vi} "${CONF}"
    sleep 2
    check_status
    case $? in
        0) echo -e "Sing2 状态: ${green}已运行${plain}" ;;
        1)
            echo -e "检测到您未启动 Sing2 或 Sing2 自动重启失败，是否查看日志？[Y/n]" && read -r yn
            if [[ x"${yn}" =~ ^[Yy]$ || -z "${yn}" ]]; then
                show_log
            fi
            ;;
        2) echo -e "Sing2 状态: ${red}未安装${plain}" ;;
    esac
    [[ $# == 0 ]] && before_show_menu
}

uninstall() {
    confirm "确定要卸载 Sing2 吗？" "n"
    [[ $? != 0 ]] && { [[ $# == 0 ]] && show_menu; return 0; }

    systemctl stop ${SERVICE}
    systemctl disable ${SERVICE}
    rm -f /etc/systemd/system/${SERVICE}.service
    systemctl daemon-reload
    systemctl reset-failed
    rm -rf /usr/local/Sing2/
    rm -f /usr/bin/sing2 /usr/bin/Sing2
    rm -f /etc/logrotate.d/Sing2   # 留着会让系统每天为不存在的日志跑一次轮转
    # 安装器在系统没有任何轮转驱动时会自建这个 timer（install.sh 的
    # ensure_logrotate_driver 第 3 条）。多数机器上它不存在，rm 是无害的。
    if systemctl cat Sing2-logrotate.timer >/dev/null 2>&1; then
        systemctl disable --now Sing2-logrotate.timer >/dev/null 2>&1
        rm -f /etc/systemd/system/Sing2-logrotate.timer /etc/systemd/system/Sing2-logrotate.service
        systemctl daemon-reload
    fi

    echo ""
    echo -e "${green}卸载成功${plain}"
    echo -e "${yellow}配置目录 ${CONF_DIR} 已保留${plain}（含 config.yml 与证书）。"
    echo -e "如需彻底清除：${green}rm -rf ${CONF_DIR}${plain}"
    echo ""
    [[ $# == 0 ]] && before_show_menu
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}Sing2 已在运行，无需再次启动${plain}"
    else
        local out
        out=$(systemctl start ${SERVICE} 2>&1)
        sleep 2
        check_status
        case $? in
            0) echo -e "${green}Sing2 启动成功，请用 sing2 log 查看运行日志${plain}" ;;
            2) echo; diagnose_missing_unit ;;
            *)
                echo -e "${red}Sing2 启动失败${plain}"
                [[ -n "$out" ]] && echo -e "  systemctl: ${out}"
                echo -e "  最近日志："
                journalctl -u ${SERVICE}.service -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
                echo -e "  配置自检：${green}${BIN} serve -c ${CONF} ${plain}（前台跑，Ctrl-C 退出）"
                ;;
        esac
    fi
    [[ $# == 0 ]] && before_show_menu
}

stop() {
    systemctl stop ${SERVICE}
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}Sing2 停止成功${plain}"
    else
        echo -e "${red}Sing2 停止失败${plain}，请用 sing2 log 查看日志"
    fi
    [[ $# == 0 ]] && before_show_menu
}

restart() {
    systemctl restart ${SERVICE}
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}Sing2 重启成功，请用 sing2 log 查看运行日志${plain}"
    else
        echo -e "${red}Sing2 重启失败${plain}，请用 sing2 log 查看日志"
    fi
    [[ $# == 0 ]] && before_show_menu
}

status() {
    systemctl status ${SERVICE} --no-pager -l
    [[ $# == 0 ]] && before_show_menu
}

enable() {
    systemctl enable ${SERVICE} 2>&1 | sed 's/^/  /'
    if [[ ${PIPESTATUS[0]} == 0 ]]; then
        echo -e "${green}Sing2 设置开机自启成功${plain}"
    else
        echo -e "${red}Sing2 设置开机自启失败${plain}"
    fi
    [[ $# == 0 ]] && before_show_menu
}

disable() {
    systemctl disable ${SERVICE}
    if [[ $? == 0 ]]; then
        echo -e "${green}Sing2 取消开机自启成功${plain}"
    else
        echo -e "${red}Sing2 取消开机自启失败${plain}"
    fi
    [[ $# == 0 ]] && before_show_menu
}

# config_log_path 取出 config.yml 里某个日志路径键的当前值。
# 只认**未被注释**的值：`ErrorPath: # /etc/Sing2/error.log` 这种形状是"没配置"。
config_log_path() {
    local key=$1 line val
    [[ -f "$CONF" ]] || return 1
    line=$(grep -E "^[[:space:]]*${key}:" "$CONF" 2>/dev/null | grep -vE "^[[:space:]]*#" | tail -1)
    [[ -n "$line" ]] || return 1
    val=${line#*:}
    val=${val%%#*}
    val=$(printf '%s' "$val" | tr -d "\"' \t\r")
    [[ -n "$val" ]] || return 1
    echo "$val"
}

show_log_usage() {
    echo "日志查看用法："
    echo "  sing2 log all       合并查看 panel/journald 与完整运行日志（默认）"
    echo "  sing2 log runtime   只看 Sing2/panel 和核心运行信息，排除逐连接错误"
    echo "  sing2 log access    只看用户连接记录（Log.AccessPath）"
    echo "  sing2 log failures  只看连接失败、DNS 错误和超时（Log.ErrorPath）"
}

# connection: 是 sing-box 逐连接错误的稳定标记。runtime 排除它，failures 只保留它。
show_recent_journal() {
    local mode=$1
    case "$mode" in
        all)      journalctl -u ${SERVICE}.service -n 50 --no-pager ;;
        runtime)  journalctl -u ${SERVICE}.service -n 2000 --no-pager |
                  grep -vE '(^|[[:space:]])connection:' | tail -n 50 ;;
        failures) journalctl -u ${SERVICE}.service -n 2000 --no-pager |
                  grep -E '(^|[[:space:]])connection:' | tail -n 50 ;;
    esac
}

show_recent_log_file() {
    local logfile=$1 mode=$2
    case "$mode" in
        all|access) tail -n 50 "$logfile" ;;
        runtime)    tail -n 2000 "$logfile" |
                    grep -vE '(^|[[:space:]])connection:' | tail -n 50 ;;
        failures)   tail -n 2000 "$logfile" |
                    grep -E '(^|[[:space:]])connection:' | tail -n 50 ;;
    esac
}

follow_journal() {
    local mode=$1
    case "$mode" in
        all)      journalctl -u ${SERVICE}.service -f --no-pager ;;
        runtime)  journalctl -u ${SERVICE}.service -f --no-pager |
                  grep --line-buffered -vE '(^|[[:space:]])connection:' ;;
        failures) journalctl -u ${SERVICE}.service -f --no-pager |
                  grep --line-buffered -E '(^|[[:space:]])connection:' ;;
    esac
}

follow_log_file() {
    local logfile=$1 mode=$2
    # -F 会在 logrotate 后重新打开文件；文件暂未生成时也会持续等待。
    case "$mode" in
        all|access) tail -n 0 -F "$logfile" ;;
        runtime)    tail -n 0 -F "$logfile" |
                    grep --line-buffered -vE '(^|[[:space:]])connection:' ;;
        failures)   tail -n 0 -F "$logfile" |
                    grep --line-buffered -E '(^|[[:space:]])connection:' ;;
    esac
}

show_log() {
    local return_to_menu=0 mode="${1:-all}"
    [[ $# == 0 ]] && return_to_menu=1

    case "$mode" in
        all|runtime|access|failures) ;;
        *)
            echo -e "${red}未知日志视图：${mode}${plain}"
            show_log_usage
            [[ $return_to_menu == 1 ]] && before_show_menu
            return 2
            ;;
    esac

    check_status
    if [[ $? == 2 ]]; then
        diagnose_missing_unit
        [[ $return_to_menu == 1 ]] && before_show_menu
        return 1
    fi

    local errlog accesslog follower_pid
    errlog=$(config_log_path "ErrorPath") || errlog=""
    accesslog=$(config_log_path "AccessPath") || accesslog=""

    if [[ "$mode" == "access" ]]; then
        if [[ -z "$accesslog" ]]; then
            echo -e "${yellow}配置中没有启用 Log.AccessPath，当前没有独立的用户连接日志。${plain}"
            echo "请在 ${CONF} 的 Log 段设置 AccessPath 后重启 Sing2。"
            [[ $return_to_menu == 1 ]] && before_show_menu
            return 1
        fi

        echo -e "${yellow}--- 用户连接日志：${accesslog}（最近 50 行） ---${plain}"
        if [[ -f "$accesslog" ]]; then
            show_recent_log_file "$accesslog" access
        else
            echo -e "${yellow}日志文件尚未生成；将等待第一条连接记录。${plain}"
        fi
        echo -e "${yellow}--- 以下为实时用户连接记录，Ctrl-C 退出 ---${plain}"
        follow_log_file "$accesslog" access
        [[ $return_to_menu == 1 ]] && before_show_menu
        return
    fi

    if [[ "$mode" == "failures" ]]; then
        echo -e "${yellow}--- 用户连接失败（最近 50 条）---${plain}"
        if [[ -n "$errlog" ]]; then
            if [[ -f "$errlog" ]]; then
                show_recent_log_file "$errlog" failures
            else
                echo -e "${yellow}配置指向 ${errlog}，但文件尚未生成；将等待第一条错误。${plain}"
            fi
            echo -e "${yellow}--- 以下为实时连接失败，Ctrl-C 退出 ---${plain}"
            follow_log_file "$errlog" failures
        else
            show_recent_journal failures
            echo -e "${yellow}--- 以下为实时连接失败，Ctrl-C 退出 ---${plain}"
            follow_journal failures
        fi
        [[ $return_to_menu == 1 ]] && before_show_menu
        return
    fi

    if [[ "$mode" == "runtime" ]]; then
        echo -e "${yellow}--- Sing2/panel 运行信息（最近 50 条）---${plain}"
    else
        echo -e "${yellow}--- Sing2/panel 日志（最近 50 行）---${plain}"
    fi
    show_recent_journal "$mode"

    if [[ -n "$errlog" && -f "$errlog" ]]; then
        echo
        echo -e "${yellow}--- ${errlog}（最近 50 条）---${plain}"
        show_recent_log_file "$errlog" "$mode"
    elif [[ -n "$errlog" ]]; then
        echo -e "${yellow}提示：配置指向 ${errlog}，但该文件尚不存在（还没产生日志）${plain}"
    fi

    if [[ "$mode" == "runtime" ]]; then
        echo -e "${yellow}--- 以下为实时运行信息（已排除逐连接错误），Ctrl-C 退出 ---${plain}"
    else
        echo -e "${yellow}--- 以下为全部实时运行日志，Ctrl-C 退出 ---${plain}"
    fi

    # ErrorPath 非空时，sing-box 与 panel 日志分属文件和 journald，需同时跟随。
    if [[ -n "$errlog" ]]; then
        follow_log_file "$errlog" "$mode" &
        follower_pid=$!
        trap 'kill "$follower_pid" 2>/dev/null; wait "$follower_pid" 2>/dev/null' EXIT INT TERM
        follow_journal "$mode"
        kill "$follower_pid" 2>/dev/null
        wait "$follower_pid" 2>/dev/null
        trap - EXIT INT TERM
    else
        follow_journal "$mode"
    fi
    [[ $return_to_menu == 1 ]] && before_show_menu
}

install_bbr() {
    bash <(curl -L -s https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh)
}

update_shell() {
    # 先下到临时文件再替换：直接 `wget -O /usr/bin/sing2` 会在下载开始前清空目标，
    # 中途失败就把管理脚本本身变成一个 0 字节文件，连重试都没得用。
    local tmpf
    tmpf=$(mktemp) || { echo -e "${red}无法创建临时文件${plain}"; before_show_menu; return 1; }
    if curl -fsSL --retry 3 --connect-timeout 15 -o "$tmpf" \
        "https://raw.githubusercontent.com/${SCRIPT_REPO}/master/Sing2.sh" && [[ -s "$tmpf" ]]; then
        mv -f "$tmpf" /usr/bin/sing2
        chmod +x /usr/bin/sing2
        ln -sf /usr/bin/sing2 /usr/bin/Sing2
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
    else
        rm -f "$tmpf"
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 GitHub${plain}"
        before_show_menu
    fi
}

# 0: running, 1: not running, 2: not installed
#
# 「已安装」以 **systemd 是否登记了这个 unit** 为准，而不是「文件在不在」。
# 一个写坏/写空/未 daemon-reload 的 unit 文件会让文件判断说"已安装、未运行"，
# 而 systemctl start 说 "Unit not found" —— 两个结论互相矛盾，运维无从下手。
check_status() {
    local unitline
    unitline=$(systemctl list-unit-files 2>/dev/null | grep "^${SERVICE}\.service" | head -1)
    # 空 = 没登记；含 bad = 文件在但 systemd 解析不了。两者都算"没装好"，
    # 否则就会出现「菜单说未运行、start 说 not found」的自相矛盾。
    [[ -z "$unitline" || "$unitline" == *bad* ]] && return 2
    local temp
    temp=$(systemctl is-active ${SERVICE} 2>/dev/null)
    [[ x"${temp}" == x"active" ]] && return 0 || return 1
}

# diagnose 在 systemd 不认识这个 unit 时，把「为什么」直接摆出来。
# 没有它的话，用户只会看到 "not found"，而 `sing2 log` 又是空的（journal 里根本
# 没有这个 unit 的记录），排查就断在这里。
diagnose_missing_unit() {
    echo -e "${red}systemd 不认识 ${SERVICE}.service${plain}"
    echo
    if [[ -f /etc/systemd/system/${SERVICE}.service ]]; then
        local sz
        sz=$(stat -c%s /etc/systemd/system/${SERVICE}.service 2>/dev/null)
        echo -e "  unit 文件存在（${sz} 字节），但 systemd 没登记它。常见原因："
        if [[ "${sz}" == "0" ]]; then
            echo -e "    ${yellow}→ 文件是空的${plain}（多半是下载中断留下的残骸）"
        fi
        # CRLF 检测不用 grep：某些环境的 grep 会把文件当文本、把 CR 吃掉，
        # 检测就静默失效了。读首行判尾字符不依赖任何文本处理。
        local first
        IFS= read -r first < /etc/systemd/system/${SERVICE}.service 2>/dev/null
        if [[ "${first}" == *$'\r' ]]; then
            echo -e "    ${yellow}→ 文件是 CRLF 行尾${plain}，systemd 解析不了"
        fi
        echo -e "    → SELinux 上下文不对（从 /tmp 拷进来的文件 PID 1 读不了）"
        echo -e "       当前：$(ls -Z /etc/systemd/system/${SERVICE}.service 2>/dev/null | awk '{print $1}')"
        echo -e "       SELinux：$(getenforce 2>/dev/null || echo 'N/A')"
        echo -e "    → 或者装完没执行 systemctl daemon-reload"
        echo -e "  systemd 记录的状态：$(systemctl list-unit-files 2>/dev/null | grep "^${SERVICE}\.service" || echo '未登记')"
        echo
        echo -e "  文件前几行："
        sed -n '1,6p' /etc/systemd/system/${SERVICE}.service | sed 's/^/    /'
    else
        echo -e "  /etc/systemd/system/${SERVICE}.service ${yellow}不存在${plain} —— 安装没有完成。"
    fi
    echo
    echo -e "  ${green}重装即可修复：${plain}sing2 install"
    echo -e "  （配置 ${CONF_DIR}/config.yml 会保留）"
}

check_enabled() {
    local temp
    temp=$(systemctl is-enabled ${SERVICE} 2>/dev/null)
    [[ x"${temp}" == x"enabled" ]] && return 0 || return 1
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}Sing2 已安装，请勿重复安装${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi
    return 0
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        diagnose_missing_unit
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi
    return 0
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "Sing2 状态: ${green}已运行${plain}"
            show_enable_status
            show_logrotate_status
            ;;
        1)
            echo -e "Sing2 状态: ${yellow}未运行${plain}"
            show_enable_status
            show_logrotate_status
            ;;
        2) echo -e "Sing2 状态: ${red}未安装${plain}" ;;
    esac
}

# show_logrotate_status —— 「日志轮转到底有没有在跑」此前在任何界面上都看不到，
# 于是想确认的人只能自己猜命令，而最顺手的那个（crontab -l）**在配置正确的系统上
# 也必然为空**——logrotate 从不写用户 crontab。空 crontab 因此被读成「没配上」。
# 这里给出唯一可信的三件事：配置在不在、谁触发、上次真的轮转是什么时候。
show_logrotate_status() {
    if [[ ! -f /etc/logrotate.d/Sing2 ]]; then
        echo -e "日志轮转: ${red}未配置${plain}（重装或 ${green}sing2 update${plain} 会补上）"
        return
    fi

    local driver=""
    if systemctl is-active Sing2-logrotate.timer >/dev/null 2>&1; then
        driver="Sing2-logrotate.timer（自建）"
    elif systemctl is-active logrotate.timer >/dev/null 2>&1; then
        driver="logrotate.timer"
    elif [[ -x /etc/cron.daily/logrotate ]] &&
         ! grep -q '/run/systemd/system' /etc/cron.daily/logrotate 2>/dev/null &&
         { systemctl is-active crond >/dev/null 2>&1 || systemctl is-active cron >/dev/null 2>&1; }; then
        driver="cron → /etc/cron.daily/logrotate"
    fi

    if [[ -z "$driver" ]]; then
        echo -e "日志轮转: ${red}配置在，但没有任何东西会执行它${plain}——日志会一直涨"
        echo -e "          修：${green}sing2 update${plain}（会重新挑驱动，必要时自建 timer）"
        return
    fi
    echo -e "日志轮转: ${green}已配置${plain}，由 ${green}${driver}${plain} 触发"

    # 上次轮转时间。状态文件路径按发行版不同，两处都看。没有记录说明还没轮转过
    # ——刚装的机器就是这样，不是故障。
    local state last
    for state in /var/lib/logrotate/status /var/lib/logrotate.status; do
        [[ -f "$state" ]] || continue
        last=$(grep -F "${CONF_DIR}/access.log" "$state" 2>/dev/null | tail -1 | awk '{print $2}')
        [[ -n "$last" ]] && break
    done
    if [[ -n "$last" ]]; then
        echo -e "          access.log 上次轮转: ${green}${last}${plain}"
    else
        echo -e "          ${yellow}尚无轮转记录${plain}（刚安装时正常，首次触发后才会有）"
    fi
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

show_Sing2_version() {
    echo -n "Sing2 版本："
    ${BIN} version
    echo ""
    [[ $# == 0 ]] && before_show_menu
}

# REALITY 密钥对：私钥留本节点，公钥填面板。
# 面板的 server 串同时用于渲染用户订阅，私钥进面板就等于发给每个客户端。
gen_x25519() {
    if [[ ! -x ${BIN} ]]; then
        echo -e "${red}未找到 ${BIN}，请先安装 Sing2${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi
    echo ""
    ${BIN} x25519
    echo ""
    [[ $# == 0 ]] && before_show_menu
}

generate_config_file() {
    echo -e "${yellow}Sing2 配置文件生成向导${plain}"
    echo -e "${red}注意事项：${plain}"
    echo -e "${red}1. 生成的配置会写入 ${CONF}${plain}"
    echo -e "${red}2. 原配置会备份为 ${CONF}.bak${plain}"
    echo -e "${red}3. 向导只覆盖常用项，其余字段直接编辑 config.yml${plain}"
    read -rp "是否继续？(y/n) " go_on
    if [[ ! $go_on =~ ^[yY]$ ]]; then
        echo -e "${red}已取消${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 0
    fi

    # 面板类型决定节点载荷的解析方式，必须选对：SSpanel 恒按传统 6 段 server 串
    # 解析，Phoenix 恒按 custom_config 解析。选错节点起不来（会明确报错并提示改哪个值）。
    echo -e "${yellow}请选择对接的面板类型：${plain}"
    echo -e "${green}1.${plain} SSpanel   传统 SSpanel（节点下发 6 段 server 串）"
    echo -e "${green}2.${plain} Phoenix   Phoenix（节点下发 custom_config）"
    read -rp "请选择 [1-2]（默认 1）：" panel_choice
    case "${panel_choice}" in
    2) PanelType="Phoenix" ;;
    *) PanelType="SSpanel" ;;
    esac
    echo -e "${green}面板类型：${PanelType}${plain}"

    read -rp "请输入面板地址（如 https://panel.example.com）：" ApiHost
    read -rp "请输入面板对接 API Key：" ApiKey
    read -rp "请输入节点 ID：" NodeID

    echo -e "${yellow}请选择节点协议：${plain}"
    echo -e "${green}1.${plain} V2ray      （VMess / VLESS，由面板 enable_vless 决定）"
    echo -e "${green}2.${plain} Vless"
    echo -e "${green}3.${plain} Trojan"
    echo -e "${green}4.${plain} Shadowsocks"
    echo -e "${green}5.${plain} Mieru"
    echo -e "${green}6.${plain} TrustTunnel"
    read -rp "请输入 [1-6，默认 1]：" nt
    case "$nt" in
        2) NodeType="Vless" ;;
        3) NodeType="Trojan" ;;
        4) NodeType="Shadowsocks" ;;
        5) NodeType="Mieru" ;;
        6) NodeType="TrustTunnel" ;;
        *) NodeType="V2ray" ;;
    esac

    EnableVless="false"
    VlessFlow=""
    if [[ "$NodeType" == "V2ray" ]]; then
        confirm "该节点是否为 VLESS？（否则为 VMess）" "n"
        [[ $? == 0 ]] && EnableVless="true"
    fi
    if [[ "$NodeType" == "Vless" || "$EnableVless" == "true" ]]; then
        confirm "是否启用 XTLS Vision（flow=xtls-rprx-vision）" "y"
        [[ $? == 0 ]] && VlessFlow="xtls-rprx-vision"
    fi

    # REALITY：私钥必须节点本地持有
    EnableREALITY="false"
    RealityDest="www.microsoft.com:443"
    RealitySNI="www.microsoft.com"
    RealityPrivKey=""
    RealityShortId=""
    if [[ "$NodeType" == "Vless" || "$EnableVless" == "true" ]]; then
        confirm "是否启用 REALITY" "n"
        if [[ $? == 0 ]]; then
            EnableREALITY="true"
            read -rp "REALITY 回落目标 [默认 www.microsoft.com:443]：" tmp
            [[ -n "$tmp" ]] && RealityDest="$tmp"
            read -rp "REALITY SNI（须与回落目标一致）[默认 www.microsoft.com]：" tmp
            [[ -n "$tmp" ]] && RealitySNI="$tmp"
            read -rp "REALITY ShortId（面板若已配置请填相同值，留空表示不限）：" RealityShortId
            echo -e "${yellow}正在生成 REALITY 密钥对……${plain}"
            if [[ -x ${BIN} ]]; then
                local kp
                kp=$(${BIN} x25519)
                echo "$kp"
                RealityPrivKey=$(echo "$kp" | awk '/PrivateKey:/{print $2}')
                echo -e "${green}私钥已写入配置；请把上面的 PublicKey 填到面板${plain}"
            else
                echo -e "${red}未找到 ${BIN}，请稍后手动执行 sing2 x25519 并填入 PrivateKey${plain}"
            fi
        fi
    fi

    # 证书
    echo -e "${yellow}证书模式：${plain}"
    echo -e "${green}1.${plain} none  不启用 TLS（REALITY / Mieru 选这个）"
    echo -e "${green}2.${plain} file  使用本地证书文件"
    echo -e "${green}3.${plain} dns   ACME DNS-01 自动申请"
    echo -e "${green}4.${plain} http  ACME HTTP-01 自动申请（需 80 端口可达）"
    read -rp "请输入 [1-4，默认 1]：" cm
    case "$cm" in
        2) CertMode="file" ;;
        3) CertMode="dns" ;;
        4) CertMode="http" ;;
        *) CertMode="none" ;;
    esac
    CertDomain=""
    CertEmail=""
    CertProvider="cloudflare"
    if [[ "$CertMode" != "none" ]]; then
        read -rp "请输入证书域名：" CertDomain
    fi
    if [[ "$CertMode" == "dns" || "$CertMode" == "http" ]]; then
        read -rp "请输入 ACME 邮箱：" CertEmail
    fi
    if [[ "$CertMode" == "dns" ]]; then
        read -rp "请输入 DNS provider [默认 cloudflare]：" tmp
        [[ -n "$tmp" ]] && CertProvider="$tmp"
        read -rp "请输入 Cloudflare API Token（其它 provider 请稍后手改 DNSEnv）：" CFToken
    fi

    mkdir -p "${CONF_DIR}"
    [[ -f "${CONF}" ]] && mv "${CONF}" "${CONF}.bak"

    {
        cat <<EOF
Log:
  Level: warning # none / error / warning / info / debug
  AccessPath: # ${CONF_DIR}/access.log
  ErrorPath: # ${CONF_DIR}/error.log

AccessLog:
  Enable: false # 面板需实现 POST /mod_mu/users/accesslog

Nodes:
  - PanelType: "${PanelType}"
    ApiConfig:
      ApiHost: "${ApiHost}"
      ApiKey: "${ApiKey}"
      NodeID: ${NodeID}
      NodeType: ${NodeType}
      Timeout: 30
      EnableVless: ${EnableVless}
EOF
        [[ -n "$VlessFlow" ]] && echo "      VlessFlow: ${VlessFlow}"
        cat <<EOF
      SpeedLimit: 0 # Mbps，0 = 不限（本地设置会覆盖面板下发）
      DeviceLimit: 0 # 0 = 不限
      RuleListPath: # ${CONF_DIR}/rulelist
    ControllerConfig:
      # 0.0.0.0 只监听 IPv4。有 IPv6 直连用户请写 "::"（双栈），
      # 否则那部分用户连不上，而节点本身一切正常、日志也不会提示。
      ListenIP: 0.0.0.0
      SendIP: 0.0.0.0
      UpdatePeriodic: 60
      EnableDNS: false
      DNSType: AsIs
      EnableProxyProtocol: false
      EnableFallback: false
      EnableREALITY: ${EnableREALITY}
EOF
        if [[ "$EnableREALITY" == "true" ]]; then
            cat <<EOF
      DisableLocalREALITYConfig: false
      REALITYConfigs:
        Show: false
        Dest: ${RealityDest}
        ProxyProtocolVer: 0
        ServerNames:
          - ${RealitySNI}
        PrivateKey: ${RealityPrivKey}
        MaxTimeDiff: 0
        ShortIds:
          - "${RealityShortId}"
EOF
        fi
        cat <<EOF
      AutoSpeedLimitConfig:
        Limit: 0 # Mbps，0 = 关闭动态限速
        WarnTimes: 0
        LimitSpeed: 0
        LimitDuration: 0
      GlobalDeviceLimitConfig:
        Enable: false
      ConnLimitConfig:
        Enable: false
        MaxConnPerUser: 0
      CertConfig:
        CertMode: ${CertMode}
EOF
        [[ -n "$CertDomain" ]] && echo "        CertDomain: \"${CertDomain}\""
        if [[ "$CertMode" == "file" ]]; then
            echo "        CertFile: ${CONF_DIR}/cert/${CertDomain}.crt"
            echo "        KeyFile: ${CONF_DIR}/cert/${CertDomain}.key"
        fi
        if [[ "$CertMode" == "dns" || "$CertMode" == "http" ]]; then
            echo "        Email: \"${CertEmail}\""
        fi
        if [[ "$CertMode" == "dns" ]]; then
            echo "        Provider: ${CertProvider}"
            echo "        DNSEnv:"
            echo "          CLOUDFLARE_DNS_API_TOKEN: \"${CFToken}\""
        fi
    } > "${CONF}"

    chmod 600 "${CONF}"
    echo -e "${green}配置已生成：${CONF}${plain}"
    if [[ "$EnableREALITY" == "true" && -n "$RealityPrivKey" ]]; then
        echo -e "${yellow}提醒：REALITY 私钥只在本节点，面板只需填公钥。${plain}"
    fi
    echo -e "正在重启 Sing2 ……"
    restart 0
    [[ $# == 0 ]] && before_show_menu
}

open_ports() {
    systemctl stop firewalld.service 2>/dev/null
    systemctl disable firewalld.service 2>/dev/null
    setenforce 0 2>/dev/null
    ufw disable 2>/dev/null
    iptables -P INPUT ACCEPT 2>/dev/null
    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -P OUTPUT ACCEPT 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -t mangle -F 2>/dev/null
    iptables -F 2>/dev/null
    iptables -X 2>/dev/null
    netfilter-persistent save 2>/dev/null
    echo -e "${green}已放开防火墙端口${plain}"
    [[ $# == 0 ]] && before_show_menu
}

show_usage() {
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
    echo "sing2 key          - 写入/轮换分发端点与密钥"
    echo "sing2 install      - 安装"
    echo "sing2 uninstall    - 卸载"
    echo "sing2 version      - 查看版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}Sing2 后端管理脚本${plain}
--- https://github.com/${SCRIPT_REPO} ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 Sing2
  ${green}2.${plain} 更新 Sing2
  ${green}3.${plain} 卸载 Sing2
————————————————
  ${green}4.${plain} 启动 Sing2
  ${green}5.${plain} 停止 Sing2
  ${green}6.${plain} 重启 Sing2
  ${green}7.${plain} 查看 Sing2 状态
  ${green}8.${plain} 查看 Sing2 日志
————————————————
  ${green}9.${plain} 设置 Sing2 开机自启
 ${green}10.${plain} 取消 Sing2 开机自启
————————————————
 ${green}11.${plain} 一键安装 bbr (最新内核)
 ${green}12.${plain} 查看 Sing2 版本
 ${green}13.${plain} 升级 Sing2 维护脚本
 ${green}14.${plain} 生成 Sing2 配置文件
 ${green}15.${plain} 放行 VPS 的所有网络端口
 ${green}16.${plain} 生成 REALITY 密钥对
 ${green}17.${plain} 写入/轮换分发端点与密钥
 "
    show_status
    echo && read -rp "请输入选择 [0-17]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) install_bbr ;;
        12) check_install && show_Sing2_version ;;
        13) update_shell ;;
        14) generate_config_file ;;
        15) open_ports ;;
        16) check_install && gen_x25519 ;;
        # 不加 check_install：装不上正是因为缺密钥，这时候要求「先装好」是死循环。
        17) dist_key ;;
        *) echo -e "${red}请输入正确的数字 [0-17]${plain}" ;;
    esac
}

if [[ $# -gt 0 ]]; then
    case $1 in
        "start")     check_install 0 && start 0 ;;
        "stop")      check_install 0 && stop 0 ;;
        "restart")   check_install 0 && restart 0 ;;
        "status")    check_install 0 && status 0 ;;
        "enable")    check_install 0 && enable 0 ;;
        "disable")   check_install 0 && disable 0 ;;
        "log")       check_install 0 && show_log "${2:-all}" 0 ;;
        "update")    check_install 0 && update 0 "${@:2}" ;;
        "config")    config "$@" ;;
        "generate")  generate_config_file 0 ;;
        "x25519")    gen_x25519 0 ;;
        "key")       dist_key 0 ;;
        "install")   check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "version")   check_install 0 && show_Sing2_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
