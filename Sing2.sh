#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sing2 管理脚本。安装后位于 /usr/bin/sing2（并软链 /usr/bin/Sing2）。
#
# 布局：
#   /usr/local/Sing2/sing2   二进制
#   /etc/Sing2/config.yml    配置
#   Sing2.service            systemd 单元
#   Sing2.service.d/memlimit.conf  内存软上限（只在设置过时存在）

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
# 内存软上限写在 drop-in 里而不是 Sing2.service 本身：升级会整份重写 unit，
# drop-in 不受影响。同目录下运维自己放的其它 drop-in 一概不碰。
MEMLIMIT_DIR="/etc/systemd/system/${SERVICE}.service.d"
MEMLIMIT_FILE="${MEMLIMIT_DIR}/memlimit.conf"
MEMLIMIT_WARNED=0
# 本脚本会直接运行 Go 二进制（version、x25519），也会把环境传给 install.sh。调用者
# shell 里一个写坏的 GOMEMLIMIT 会让二进制一启动就退出；服务自己的值只来自 drop-in。
unset GOMEMLIMIT

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

# confirm_restart [默认答案 y|n] [0] —— 问过再重启。默认答案不写就是 y。第二个参数 0
# 表示命令行调用：重启后不进菜单，答「否」也只留一句提示。
confirm_restart() {
    confirm "是否重启 Sing2" "${1:-y}"
    if [[ $? == 0 ]]; then
        if [[ $# -gt 1 ]]; then restart 0; else restart; fi
    else
        echo -e "未重启：执行 ${green}sing2 restart${plain} 后生效"
        [[ $# -gt 1 ]] || show_menu
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
    # 内存软上限：只删本脚本写的那一份；目录里还有运维自己的 drop-in 就留着目录。
    # memlimit.conf 里有不是本脚本写的内容时连它一起留着——那是运维自己的设置。
    if memlimit_foreign; then
        echo -e "${yellow}保留了 ${MEMLIMIT_FILE}${plain}：里面有不是本脚本写的内容，不需要了请自行删除"
    else
        memlimit_drop
    fi
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
    # drop-in 里任何一个文件 PID 1 读不了，systemd 同样会把整个 unit 记成 bad。
    # 本脚本自己的 memlimit.conf 在 check_install 里已经修过，剩下的只列出来。
    if [[ -d "$MEMLIMIT_DIR" ]]; then
        echo
        echo -e "  drop-in 目录（其中任何一个文件的 SELinux 上下文不对，systemd 都会不认整个 unit）："
        # 目录本身 + 其中每个文件（含隐藏文件），各带 SELinux 上下文。
        find "$MEMLIMIT_DIR" -maxdepth 1 -printf '%Z %p\n' 2>/dev/null | sed 's/^/    /'
        echo -e "    → 不是本脚本写的文件请自行检查，例如 ${green}restorecon -v <文件>${plain}"
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
    memlimit_heal
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
            show_memlimit_status
            show_logrotate_status
            ;;
        1)
            echo -e "Sing2 状态: ${yellow}未运行${plain}"
            show_enable_status
            show_memlimit_status
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

    # 沙箱豁免。这一条是**预测性**的：不用等一天，装完就能判。
    #
    # 发行版的 logrotate.service 普遍带 ProtectSystem=full，它把 /etc 挂成只读，
    # 而 Sing2 的日志出厂就在 /etc/Sing2/ 下。没有豁免时 logrotate 每天准时启动、
    # 准时报 `Read-only file system`，而**状态文件的日期照样往前推**——所以下面
    # 那条「有没有产物」的检查要等到第二天才看得出来，这条现在就能看出来。
    if systemctl cat logrotate.service 2>/dev/null | grep -q '^ProtectSystem=' &&
       ! systemctl cat logrotate.service 2>/dev/null | grep -q "ReadWritePaths=.*${CONF_DIR}"; then
        echo -e "          ${red}缺少沙箱豁免${plain}：logrotate.service 带 ${yellow}ProtectSystem${plain}，"
        echo -e "          它把 /etc 挂成只读，而日志在 ${CONF_DIR} 下——轮转会每天失败。"
        echo -e "          修：${green}sing2 update${plain}（会补写 ReadWritePaths 豁免）"
    fi

    # ⚠ 状态文件里的日期**不是**「上次轮转成功」的证据。
    #
    # logrotate 首次见到一个文件时会记下当前时间而**不轮转**（它没有基线可比），
    # 之后每次处理也会更新这个日期——包括轮转因为写不进目录而失败的那些次。
    # 这里原本把它直接标成「上次轮转」，于是产生了本项目最不该有的那种信号：
    # 界面显示「已配置，上次轮转 2026-9-1 0:0:2」，而同一个目录里
    # access.log 是 5.8 GB、一个 .gz 都没有。运维照着这行字判断「轮转正常」，
    # 真相是它一次都没成功过。
    #
    # 唯一可信的证据是**磁盘上有没有轮转产物**，所以下面先数产物、再报日期，
    # 并且在「有日期但没产物」时明确报警——那正是失败的形状。
    local logdir="${CONF_DIR}"
    local n_rotated
    n_rotated=$(ls -1 "${logdir}"/access.log-* "${logdir}"/access.log.[0-9]* 2>/dev/null | wc -l)

    local state last
    for state in /var/lib/logrotate/status /var/lib/logrotate.status; do
        [[ -f "$state" ]] || continue
        last=$(grep -F "${CONF_DIR}/access.log" "$state" 2>/dev/null | tail -1 | awk '{print $2}')
        [[ -n "$last" ]] && break
    done

    if [[ "$n_rotated" -gt 0 ]]; then
        echo -e "          access.log 轮转产物: ${green}${n_rotated} 份${plain}${last:+（logrotate 上次处理: ${last}）}"
    elif [[ -n "$last" ]]; then
        local sz=""
        [[ -f "${logdir}/access.log" ]] && sz=$(du -h "${logdir}/access.log" 2>/dev/null | awk '{print $1}')
        echo -e "          ${red}轮转从未成功${plain}：logrotate 上次处理于 ${yellow}${last}${plain}，"
        echo -e "          但 ${logdir} 下没有任何轮转产物${sz:+（access.log 当前 ${red}${sz}${plain}）}"
        echo -e "          排查（${yellow}别用 logrotate -d${plain}，它不带沙箱、永远通过）："
        echo -e "            ${green}systemctl start logrotate.service && journalctl -u logrotate.service -n 25${plain}"
        echo -e "          最常见的原因是发行版给 logrotate.service 加了 ${yellow}ProtectSystem${plain}，"
        echo -e "          把 /etc 挂成只读，而日志就在 ${logdir} 下。修：${green}sing2 update${plain}（会补写豁免）"
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

# ---------- 内存软上限（GOMEMLIMIT） ----------
# 默认不设，也不会自动设——只在运维明确要求时写一个 drop-in。
# install.sh 里有同名函数，取值规则必须一致；改一边就改两边。

# memlimit_bytes VALUE —— 按 Go 运行时的语法换算成字节数并输出；不合法返回 1。
#
# Go 的语法：正整数 + 可选单位 B / KiB / MiB / GiB / TiB，区分大小写，不写单位就是
# 字节（Go 源码 runtime/string.go 的 parseByteCount）。这里只收它的一个子集：不收 0、
# 不收正负号、不收前导零，乘出来超过 int64 的 Go 也不收。
#
# ⚠ 只能比 Go 严，不能比它松：Go 遇到写错的 GOMEMLIMIT 不是忽略，而是一启动就退出
# （malformed GOMEMLIMIT），systemd 每 10 秒拉起一次、每次都一样——节点就停在那里。
memlimit_bytes() {
    local re='^([1-9][0-9]{0,17})(B|KiB|MiB|GiB|TiB)?$' num mult
    [[ "$1" =~ $re ]] || return 1
    num=${BASH_REMATCH[1]}
    case "${BASH_REMATCH[2]}" in
        KiB) mult=1024 ;;
        MiB) mult=1048576 ;;
        GiB) mult=1073741824 ;;
        TiB) mult=1099511627776 ;;
        *)   mult=1 ;;
    esac
    # 最多 18 位，这一步的除法与下面的乘法都不会溢出。
    (( num <= 9223372036854775807 / mult )) || return 1
    echo $(( num * mult ))
}

# 只去首尾空白（粘贴常带进空格或回车）。中间的空白不能删：「1 2」删成「12」就成了 12 字节。
memlimit_trim() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# memlimit_human BYTES —— 人看的大小：「1500 字节」「512 MiB」「约 1.46 GiB」。
memlimit_human() {
    local b=$1
    if (( b < 1048576 )); then
        printf '%s 字节' "$b"
    elif (( b < 1073741824 )); then
        (( b % 1048576 == 0 )) || printf '约 '
        printf '%s MiB' $(( b / 1048576 ))
    elif (( b % 1073741824 == 0 )); then
        printf '%s GiB' $(( b / 1073741824 ))
    else
        printf '约 %s.%02d GiB' $(( b / 1073741824 )) $(( b % 1073741824 * 100 / 1073741824 ))
    fi
}

# memlimit_show_value VALUE —— 显示用：值本身，括号里补上人看的大小。不写单位的值是
# 字节，一律注明——「1500」最容易被读成 1500 MiB。与值本身一样（2GiB）时不重复。
memlimit_show_value() {
    local v=$1 b h hs
    if ! b=$(memlimit_bytes "$v"); then
        printf '%s' "$v"
        return 0
    fi
    h=$(memlimit_human "$b")
    [[ "$h" == 约* ]] || h="＝${h}"
    hs=${h#＝}
    if [[ "$v" =~ ^[0-9]+B?$ ]]; then
        if (( b < 1048576 )); then
            printf '%s（%s）' "$v" "$h"
        else
            printf '%s（字节，%s）' "$v" "$h"
        fi
    elif [[ "${hs// /}" == "$v" ]]; then
        printf '%s' "$v"
    else
        printf '%s（%s）' "$v" "$h"
    fi
}

memlimit_refuse() {
    # 用 printf %q 原样显示被拒的值：它是运维敲进来的，不能让 echo -e 去解释里面的反斜杠，
    # 看不见的字符（中间夹的回车、全角数字）也要显出来。
    printf '%b不认识的取值：%b%q —— 未做任何改动\n' "$red" "$plain" "$1"
    echo -e "  写法：正整数加单位，单位只能是 ${green}B、KiB、MiB、GiB、TiB${plain}（区分大小写，不写单位就是字节）"
    echo -e "  例如 ${green}1500MiB${plain}、${green}2GiB${plain}；不支持小数（1.5GiB 请写 1536MiB），也不认 M、G、MB、GB"
    echo -e "  取消上限：${green}off${plain}"
}

# Sing2 进程的 PID；没在跑返回 1。不用 `show --value`：CentOS 7 的 systemd 219 没有它。
memlimit_main_pid() {
    local pid
    pid=$(systemctl show -p MainPID ${SERVICE} 2>/dev/null | cut -d= -f2)
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/environ" ]] || return 1
    echo "$pid"
}

# memlimit_pick —— 从 stdin 的 Environment= 行里取 GOMEMLIMIT 的值，多个以最后一个为准
# （与 systemd 相同）。只认完整的变量名：MY_GOMEMLIMIT=5 不算。双引号括起来的一整项是
# 一个变量（systemctl show 也这样打印带空格的值）："GOMEMLIMIT=1500MiB GOGC=50" 取出
# 「1500MiB GOGC=50」——systemd 交给 Go 的正是它，Go 不认。
memlimit_pick() {
    local v
    v=$(sed -n 's/^[[:space:]]*Environment=//p' |
        grep -oE '"([^"\\]|\\.)*"|[^"[:space:]]+' | grep -E '^"?GOMEMLIMIT=' | tail -1)
    v=${v#*GOMEMLIMIT=}
    v=${v%\"}
    [[ -n "$v" ]] || return 1
    printf '%s\n' "$v"
}

# 三个「当前值」，各答一个问题：
#   configured —— 本脚本的 drop-in 里写的
#   effective  —— systemd 下次启动时会给的（所有 drop-in 叠加后的结果）
#   running    —— 正在跑的进程启动时拿到的
# 三者可能不同：写了没重启、或者运维自己另有 drop-in 也设了它。
memlimit_configured() {
    [[ -f "$MEMLIMIT_FILE" ]] || return 1
    memlimit_pick < "$MEMLIMIT_FILE"
}

memlimit_effective() {
    systemctl show -p Environment ${SERVICE} 2>/dev/null | memlimit_pick
}

# systemd 手里的配置比磁盘上的旧：文件改过，之后没有成功的 daemon-reload。这时
# effective 与 configured 不同，原因不在别的 drop-in。
memlimit_stale() {
    [[ "$(systemctl show -p NeedDaemonReload ${SERVICE} 2>/dev/null)" == "NeedDaemonReload=yes" ]]
}

memlimit_running() {
    local pid=$1 v
    v=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -E '^GOMEMLIMIT=' | tail -1)
    v=${v#GOMEMLIMIT=}
    [[ -n "$v" ]] || return 1
    echo "$v"
}

# 进程在跑、且它拿到的值和 systemd 现在会给的不一样 —— 重启后才会生效。
memlimit_pending() {
    local pid want have
    pid=$(memlimit_main_pid) || return 1
    want=$(memlimit_effective) || want=""
    have=$(memlimit_running "$pid") || have=""
    [[ "$want" != "$have" ]]
}

# memlimit_warn VALUE BYTES —— 只提醒、不拒绝：这几种值 Go 都收，只是多半不是运维想要的。
# 返回提醒的条数（0 = 没有）；有提醒时，「是否重启」的默认答案改成 n。
memlimit_warn() {
    local v=$1 bytes=$2 n=0 total pid rss
    if [[ "$v" =~ ^[0-9]+B?$ ]]; then
        if [[ "$v" == *B ]]; then
            printf '%b注意：%s 的 B 就是字节%b' "$yellow" "$v" "$plain"
        else
            printf '%b注意：%s 没写单位，按字节算%b' "$yellow" "$v" "$plain"
        fi
        printf '＝%s 字节（约 %s MiB）' "$bytes" $(( bytes / 1048576 ))
        (( bytes < 1048576 )) && printf '；想要 MiB 请写 %sMiB' "${v%B}"
        printf '\n'
        n=$(( n + 1 ))
    fi
    if (( bytes < 268435456 )); then
        echo -e "${yellow}注意：低于 256MiB${plain}——上限太低时 Go 会频繁回收内存，CPU 明显升高。"
        n=$(( n + 1 ))
    fi
    total=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    if [[ "$total" =~ ^[0-9]+$ ]] && (( bytes > total * 1024 )); then
        echo -e "${yellow}注意：高于本机内存总量${plain}（MemTotal 约 $(( total / 1024 )) MiB）——内存用光之前到不了这个上限，等于没设。"
        n=$(( n + 1 ))
    fi
    # RSS 不是下限：它还含着没回收的垃圾，而压掉垃圾正是软上限的用处。只有远低于它
    # （不到一半）时，才多半连正在用的数据都装不下。
    if pid=$(memlimit_main_pid); then
        rss=$(awk '/^VmRSS:/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null)
        if [[ "$rss" =~ ^[0-9]+$ ]] && (( bytes < rss * 512 )); then
            echo -e "${yellow}注意：不到 Sing2 现在内存占用的一半${plain}（RSS 约 $(( rss / 1024 )) MiB）——这么低多半连正在用的数据都装不下：回收会一直跑、CPU 升高，内存也降不下来。"
            n=$(( n + 1 ))
        elif [[ "$rss" =~ ^[0-9]+$ ]] && (( bytes < rss * 1024 )); then
            echo -e "${yellow}注意：低于 Sing2 现在的内存占用${plain}（RSS 约 $(( rss / 1024 )) MiB）。"
            echo -e "  其中多少是还没回收的垃圾，从外面看不出来：压的是垃圾，正是软上限的用处；压到正在用的数据，回收就会一直跑、CPU 升高。重启后观察几分钟 CPU 与内存。"
            n=$(( n + 1 ))
        fi
    fi
    return "$n"
}

# memlimit_relabel PATH —— 把这一个路径（不递归）打回 systemd 该有的 SELinux 标签。
# 标签不对的 drop-in（典型是从 /tmp mv 进来的文件）PID 1 读不了，会让 systemd 把整个
# Sing2.service 记成 bad。类型真的变了返回 0（调用方该 daemon-reload），否则返回 1。
# 非 SELinux 系统上两条命令不存在或无害，类型读出来前后一样。
memlimit_relabel() {
    local p=$1 before
    [[ -e "$p" ]] || return 1
    before=$(stat -c %C "$p" 2>/dev/null | cut -d: -f3)
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -F "$p" >/dev/null 2>&1
    elif command -v chcon >/dev/null 2>&1; then
        chcon -t systemd_unit_file_t "$p" >/dev/null 2>&1
    fi
    [[ "$(stat -c %C "$p" 2>/dev/null | cut -d: -f3)" != "$before" ]]
}

# 写到一半被中断（Ctrl-C、kill）留下的临时文件只会是这个名字；不清掉，目录就删不掉。
memlimit_clean_tmp() {
    rm -f -- "$MEMLIMIT_DIR"/.memlimit.conf.??????
}

# memlimit_content VALUE —— memlimit.conf 的完整内容（ASCII，由 PID 1 解析）。
# 写入与「文件还是不是本脚本写的样子」的比对共用这一份。
memlimit_content() {
    printf '%s\n' \
        "# Written by the Sing2 manager script. Change it with: sing2 memlimit <value>" \
        "# Remove it with: sing2 memlimit off. A soft limit, not a hard cap." \
        "[Service]" \
        "Environment=GOMEMLIMIT=$1"
}

# memlimit_intact VALUE —— 文件逐字节就是 memlimit_write VALUE 会写的内容。手改丢了
# [Service]、换成了 CRLF、多了别的行，都算不一样。没有 cmp 时一律算不一样：多重写
# 一次无害。
memlimit_intact() {
    memlimit_content "$1" | cmp -s - "$MEMLIMIT_FILE" 2>/dev/null
}

# memlimit_foreign —— memlimit.conf 在，而里面有本脚本不会写的东西时返回 0。逐行看（去掉
# 行尾的 CR 和首尾空白），只认：空行、注释（# 或 ;）、[Service]、只设 GOMEMLIMIT 一个变量的
# Environment=GOMEMLIMIT=<值> 或 Environment="GOMEMLIMIT=<值>"（<值> 不含空白和引号，就是
# memlimit_pick 读得出来的写法）。同一行多一个变量、MemoryMax= 之类的其它设置、清空列表的
# Environment=……都是运维自己写进来的：整份重写或删掉这个文件，就把它们一起丢了。
# 不是普通文件或读不了，也算。第一行开头的 UTF-8 BOM（Windows 编辑器常加）systemd 会跳过，
# 这里也跳过。
memlimit_foreign() {
    local line t bom=$'\xef\xbb\xbf'
    [[ -e "$MEMLIMIT_FILE" ]] || return 1
    [[ -f "$MEMLIMIT_FILE" && -r "$MEMLIMIT_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line#"$bom"}; bom=""
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        case "$line" in
            ''|'#'*|';'*|'[Service]') continue ;;
            'Environment="GOMEMLIMIT='*'"') t=${line#'Environment="GOMEMLIMIT='}; t=${t%'"'} ;;
            'Environment=GOMEMLIMIT='*) t=${line#'Environment=GOMEMLIMIT='} ;;
            *) return 0 ;;
        esac
        [[ -n "$t" && "$t" != *[[:space:]\"\']* ]] || return 0
    done < "$MEMLIMIT_FILE"
    return 1
}

# memlimit_foreign_note —— memlimit_foreign 为真时告诉运维怎么办（查看与拒绝时共用）。
memlimit_foreign_note() {
    echo -e "  本脚本只写 [Service] 和一行 Environment=GOMEMLIMIT=<值>，不会重写或删除别的设置。"
    echo -e "  把它们挪到另一个 drop-in（例如 ${green}systemctl edit Sing2${plain} 写的 override.conf）之后，再设置或取消"
}

# memlimit_refuse_foreign —— 文件里有不是本脚本写的内容时说明并返回 0，调用方随即放弃：
# 设置（同值也是）、取消都不能整份重写或删掉运维自己的设置。
memlimit_refuse_foreign() {
    memlimit_foreign || return 1
    printf '%b%s 里有不是本脚本写的内容%b——未做任何改动\n' "$red" "$MEMLIMIT_FILE" "$plain"
    memlimit_foreign_note
    return 0
}

# memlimit_write VALUE —— 0 写好且 systemd 已重读，1 没写成（什么都没改），
# 4 文件已写好、但 systemctl daemon-reload 失败。
# 原子写入：同目录临时文件 → 644 → mv。临时文件建在 drop-in 目录里，SELinux 上由此
# 继承正确的标签，relabel 是兜底；临时文件名不以 .conf 结尾，systemd 不会读到写了
# 一半的它。
memlimit_write() {
    local value=$1 tmpf
    mkdir -p "$MEMLIMIT_DIR" || return 1
    memlimit_clean_tmp
    tmpf=$(mktemp "${MEMLIMIT_DIR}/.memlimit.conf.XXXXXX") || { rmdir "$MEMLIMIT_DIR" 2>/dev/null; return 1; }
    if ! memlimit_content "$value" > "$tmpf" ||
       ! chmod 644 "$tmpf" ||
       ! mv -f "$tmpf" "$MEMLIMIT_FILE"; then
        rm -f "$tmpf"
        rmdir "$MEMLIMIT_DIR" 2>/dev/null
        return 1
    fi
    # 目录可能是刚建的，也打一次（同样不递归，目录里别的文件不碰）。
    memlimit_relabel "$MEMLIMIT_DIR"
    memlimit_relabel "$MEMLIMIT_FILE"
    systemctl daemon-reload || return 4
    return 0
}

# 只删本脚本的那一份（和它中断留下的临时文件）；目录空了才连目录一起删
# （rmdir 对非空目录本来就会失败）。
memlimit_drop() {
    rm -f "$MEMLIMIT_FILE" || return 1
    memlimit_clean_tmp
    rmdir "$MEMLIMIT_DIR" 2>/dev/null
    return 0
}

# memlimit_heal —— 本脚本的 memlimit.conf 标签不对时，systemd 把整个 Sing2.service 记成
# bad，于是 restart、uninstall、连 sing2 memlimit off 都会被 check_install 拦下。
# 只在 systemd 不认这个 unit 时动手，只修这一个文件（不递归、不碰别的 drop-in）。
memlimit_heal() {
    local st
    check_status
    st=$?
    [[ $st == 2 ]] || return 0
    memlimit_relabel "$MEMLIMIT_FILE" || return 0
    systemctl daemon-reload
    echo -e "${yellow}已把 ${MEMLIMIT_FILE} 的 SELinux 标签改回正确的类型${plain}，systemd 已重新读取"
}

# 「systemd 仍给着一个值」的说明，几处共用：还没重新读取，或来自别处。
memlimit_note_other() {
    if memlimit_stale; then
        printf '%b注意：%bsystemd 仍给 %s 设着 GOMEMLIMIT=%s——它还没重新读取（上次 daemon-reload 没成功），修好后执行 %bsystemctl daemon-reload%b\n' \
            "$yellow" "$plain" "$SERVICE" "$1" "$green" "$plain"
    else
        printf '%b注意：%bsystemd 仍给 %s 设着 GOMEMLIMIT=%s——来自另一个 drop-in 或 unit 本身，%bsystemctl cat %s%b 查看\n' \
            "$yellow" "$plain" "$SERVICE" "$1" "$green" "$SERVICE" "$plain"
    fi
}

# memlimit_flag_bad VALUE OWN —— 手改出来、脚本不认的值打一行红字并返回 0；值没问题
# 什么都不打、返回 1。OWN=1：值在本脚本的文件里，用 sing2 memlimit 重写即可；OWN=2：
# 在 memlimit.conf 里，但那个文件里有不是本脚本写的内容（本脚本不重写它）；否则在
# 别的 drop-in 里。off 是 Go 认的写法（不设上限），不算。说「多半」：0、+N、前导零
# 脚本不收，Go 其实收。
memlimit_flag_bad() {
    [[ -n "$1" && "$1" != off ]] || return 1
    memlimit_bytes "$1" >/dev/null && return 1
    printf '  %b%q：脚本不认这个写法（Go 多半也不认，重启后 Sing2 会起不来）%b' "$red" "$1" "$plain"
    if [[ "$2" == 1 ]]; then
        printf '——用 %bsing2 memlimit <值>%b 重写\n' "$green" "$plain"
    elif [[ "$2" == 2 ]]; then
        printf '——改好 memlimit.conf 里的这一行\n'
    else
        printf '——它不在本脚本的文件里，%bsystemctl cat %s%b 查看\n' "$green" "$SERVICE" "$plain"
    fi
    return 0
}

# set_memlimit VALUE —— 0 已改动，1 拒绝/失败（什么都没改），3 无需改动，
# 4 systemd 没读到这次的改动（daemon-reload 失败，或重读后仍没有这个值；重启也用不上）。
# 提醒的条数留在 MEMLIMIT_WARNED，memlimit() 据此决定「是否重启」的默认答案。
set_memlimit() {
    local v bytes cur want
    MEMLIMIT_WARNED=0
    v=$(memlimit_trim "$1")
    if [[ "$v" == "off" ]]; then
        if [[ ! -e "$MEMLIMIT_FILE" ]]; then
            memlimit_drop
            # 本脚本的文件不在，不等于没设：上次 daemon-reload 可能没成功（systemd 手里
            # 还是旧值），运维也可能用 systemctl edit 自己设过。systemd 还给着值就先让它
            # 重读一次，再如实说。
            if ! want=$(memlimit_effective); then
                echo -e "内存软上限本来就${yellow}未设置${plain}，无改动"
                return 3
            fi
            if ! systemctl daemon-reload; then
                echo -e "${yellow}本脚本没有设置内存软上限（${MEMLIMIT_FILE} 不存在），而 systemctl daemon-reload 失败${plain}"
                memlimit_note_other "$want"
                return 4
            fi
            if want=$(memlimit_effective); then
                echo -e "本脚本没有设置内存软上限（${MEMLIMIT_FILE} 不存在），无改动"
                memlimit_note_other "$want"
                return 3
            fi
            echo -e "${green}已取消内存软上限${plain}（${MEMLIMIT_FILE} 早已删除，systemd 这次才重新读取）"
            return 0
        fi
        memlimit_refuse_foreign && return 1
        if ! memlimit_drop; then
            echo -e "${red}删除 ${MEMLIMIT_FILE} 失败${plain}"
            return 1
        fi
        if ! systemctl daemon-reload; then
            echo -e "${yellow}已删除 ${MEMLIMIT_FILE}，但 systemctl daemon-reload 失败${plain}——systemd 还没读到这个变化，修好后执行 ${green}systemctl daemon-reload${plain}"
            return 4
        fi
        echo -e "${green}已取消内存软上限${plain}（删除了 ${MEMLIMIT_FILE}）"
        want=$(memlimit_effective) && memlimit_note_other "$want"
        return 0
    fi

    if ! bytes=$(memlimit_bytes "$v"); then
        memlimit_refuse "$v"
        return 1
    fi
    memlimit_refuse_foreign && return 1
    memlimit_warn "$v" "$bytes"
    MEMLIMIT_WARNED=$?
    cur=$(memlimit_configured) || cur=""
    if [[ "$cur" == "$v" ]]; then
        # 文件里已是这个值。标签不对（从别处 mv 进来）先打回来；之后 systemd 给的仍不是
        # 它（上次 daemon-reload 没成功、文件被手改坏了），或文件已不是本脚本写的样子，
        # 就整份重写一次——光让 systemd 重读，救不了一个丢了 [Service] 的文件。
        memlimit_relabel "$MEMLIMIT_FILE"
        want=$(memlimit_effective) || want=""
        if [[ "$want" == "$v" ]] && memlimit_intact "$v"; then
            printf '内存软上限已经是 %b%s%b，无改动\n' "$green" "$(memlimit_show_value "$v")" "$plain"
            return 3
        fi
    fi
    memlimit_write "$v"
    case $? in
        0) ;;
        4)
            printf '%b已写入 %s，但 systemctl daemon-reload 失败%b——systemd 还没读到它，修好后再执行一次 %bsing2 memlimit %s%b\n' \
                "$yellow" "$MEMLIMIT_FILE" "$plain" "$green" "$v" "$plain"
            return 4
            ;;
        *)
            echo -e "${red}写入 ${MEMLIMIT_FILE} 失败${plain}，未做改动"
            return 1
            ;;
    esac
    if [[ "$cur" == "$v" ]]; then
        printf '内存软上限已经是 %b%s%b，已重写 %s 并让 systemd 重新读取\n' "$green" "$(memlimit_show_value "$v")" "$plain" "$MEMLIMIT_FILE"
    else
        printf '%b内存软上限已设为 %s%b，写入 %s\n' "$green" "$(memlimit_show_value "$v")" "$plain" "$MEMLIMIT_FILE"
    fi

    # 写完以 systemd 自己的说法为准，和 install_unit 验 unit 是同一个道理。
    want=$(memlimit_effective) || want=""
    if [[ -z "$want" ]]; then
        echo -e "${red}systemd 没有读到这个值${plain}——重启也用不上它"
        echo -e "  SELinux：$(getenforce 2>/dev/null || echo 'N/A')"
        echo -e "  上下文：$(ls -Z "$MEMLIMIT_FILE" 2>/dev/null)"
        echo -e "  排查：${green}systemctl cat ${SERVICE}${plain}"
        return 4
    elif [[ "$want" != "$v" ]]; then
        printf '%b注意：%bsystemd 实际会给 GOMEMLIMIT=%s——另一个排在后面的 drop-in 也设了它，\n' "$yellow" "$plain" "$want"
        echo -e "  ${green}systemctl cat ${SERVICE}${plain} 查看"
    fi
    return 0
}

show_memlimit() {
    local cur want pid have hs ws
    if memlimit_foreign; then
        # 不是本脚本写的文件：只说 systemd 会给什么，下面不再拿它和文件比、不出重写的主意
        # （设置、取消都会被拒绝）。cur 取 systemd 的值，下面的比对就自然跳过。
        cur=$(memlimit_effective) || cur=""
        hs="未设置"; [[ -n "$cur" ]] && hs=$(memlimit_show_value "$cur")
        printf '内存软上限（GOMEMLIMIT）：%bmemlimit.conf 里有不是本脚本写的内容%b（%s）\n' "$yellow" "$plain" "$MEMLIMIT_FILE"
        echo -e "  systemd 现在会给：${hs}"
        if [[ "$cur" == "$(memlimit_configured)" ]]; then memlimit_flag_bad "$cur" 2; else memlimit_flag_bad "$cur" 0; fi
        memlimit_foreign_note
    elif cur=$(memlimit_configured); then
        printf '内存软上限（GOMEMLIMIT）：%b%s%b，写在 %s\n' "$green" "$(memlimit_show_value "$cur")" "$plain" "$MEMLIMIT_FILE"
        memlimit_flag_bad "$cur" 1
    else
        cur=""
        echo -e "内存软上限（GOMEMLIMIT）：${yellow}未设置${plain}（默认）"
    fi
    want=$(memlimit_effective) || want=""
    ws="未设置"; [[ -n "$want" ]] && ws=$(memlimit_show_value "$want")
    if [[ "$want" != "$cur" ]]; then
        if memlimit_stale; then
            # 文件改过，systemd 手里还是改之前的——不是别的 drop-in 设的。
            printf '  %bsystemd 还没重新读取%b（上次 daemon-reload 没成功，或改完还没执行），它现在会给的仍是：%s\n' \
                "$yellow" "$plain" "$ws"
            if [[ -z "$cur" ]]; then
                echo -e "  执行 ${green}systemctl daemon-reload${plain} 让它重读"
            elif memlimit_bytes "$cur" >/dev/null; then
                printf '  执行 %bsing2 memlimit %s%b 让它重读\n' "$green" "$cur" "$plain"
            fi
        elif [[ -n "$want" ]]; then
            printf '  %bsystemd 实际会给：%s%b——来自另一个 drop-in 或 unit 本身，%bsystemctl cat %s%b 查看\n' \
                "$yellow" "$ws" "$plain" "$green" "$SERVICE" "$plain"
            memlimit_flag_bad "$want" 0
        elif memlimit_bytes "$cur" >/dev/null; then
            printf '  %bsystemd 没读到它%b——执行 %bsing2 memlimit %s%b（会重写这个文件、修好标签并让 systemd 重读）\n' \
                "$yellow" "$plain" "$green" "$cur" "$plain"
        else
            echo -e "  ${yellow}systemd 没读到它${plain}——${green}systemctl cat ${SERVICE}${plain} 查看"
        fi
    fi
    if pid=$(memlimit_main_pid); then
        have=$(memlimit_running "$pid") || have=""
        if [[ "$have" != "$want" ]]; then
            hs="未设置"; [[ -n "$have" ]] && hs=$(memlimit_show_value "$have")
            printf '  运行中的进程：%b%s%b——重启后才会变成 %s\n' "$yellow" "$hs" "$plain" "$ws"
        fi
    fi
    # 不是本脚本写的文件：设置、取消都会被拒，上面已经说了怎么办。
    memlimit_foreign || echo -e "  设置：${green}sing2 memlimit 1500MiB${plain}    取消：${green}sing2 memlimit off${plain}"
    echo -e "  这是 Go 的软上限，不是硬上限：Go 运行时管理的内存（主要是堆）接近它时用 CPU 换内存，已在用的内存压不下来。"
    echo -e "  进程 RSS 比这个值略高是正常的（二进制本身等不计入）。"
    echo -e "  内存峰值没成问题就不必设；2 GB 的机器上 1400MiB～1500MiB 是合理的值；不要低于节点平稳运行时的需要（回收后的低点，不是峰值）。"
}

# 菜单状态区的一行：systemd 下次启动会给的值，括号里说它从哪来、是否待重启。
# 只读，不修任何东西。
show_memlimit_status() {
    local cur want note="" c=$green own=0
    cur=$(memlimit_configured) || cur=""
    want=$(memlimit_effective) || want=""
    if memlimit_foreign; then
        # 文件不归本脚本管，它里面的值不按「本脚本的」来说，也不提示用 sing2 memlimit 重写。
        [[ "$want" == "$cur" ]] && own=2
        cur=""
        note="（memlimit.conf 里有不是本脚本写的内容，详见 sing2 memlimit）"
    elif [[ "$want" != "$cur" ]] && memlimit_stale; then
        note="（systemd 还没重新读取，详见 sing2 memlimit）"
    elif [[ -n "$cur" && -z "$want" ]]; then
        note="（memlimit.conf 没被 systemd 读到，详见 sing2 memlimit）"
    elif memlimit_pending; then
        if [[ -z "$want" ]]; then
            note="（已取消，重启后生效）"
        elif [[ "$want" == "$cur" ]]; then
            note="（已写入，重启后生效）"
        else
            note="（来自另一个 drop-in，重启后生效）"
        fi
    elif [[ -n "$want" && "$want" != "$cur" ]]; then
        note="（来自另一个 drop-in）"
    fi
    [[ -n "$note" ]] && c=$yellow
    if [[ -n "$want" ]]; then
        printf '内存软上限: %b%s%b%s\n' "$c" "$(memlimit_show_value "$want")" "$plain" "$note"
    else
        echo -e "内存软上限: 未设置${note:-（默认）}"
    fi
    # 手改出来、脚本不认的值：重启后多半起不来，状态区就要看得见。
    if ! memlimit_flag_bad "$cur" 1 && [[ "$want" != "$cur" ]]; then
        memlimit_flag_bad "$want" "$own"
    fi
    return 0
}

# memlimit —— 查看 / 设置 / 取消内存软上限。
#   sing2 memlimit            查看
#   sing2 memlimit 1500MiB    设置
#   sing2 memlimit off        取消
# 改完只问、不自作主张地重启；非交互调用（stdin 不是终端）一律不重启。
# 设置时有提醒（值偏低、偏高、没写单位……），「是否重启」默认答 n。
memlimit() {
    local cli=0 value rc def=y
    if [[ $# -gt 0 ]]; then cli=1; shift; fi   # 去掉命令行标记位

    if [[ $cli == 1 ]]; then
        if [[ $# -gt 1 ]]; then
            echo -e "${red}只接受一个取值${plain}，例如 ${green}sing2 memlimit 1500MiB${plain}"
            return 2
        fi
        if [[ $# == 0 ]]; then
            show_memlimit
            return 0
        fi
        value=$1
    else
        show_memlimit
        echo && echo -n "输入新值（如 1500MiB；off 取消上限；直接回车不改）: " && read -r value
        value=$(memlimit_trim "$value")
        if [[ -z "$value" ]]; then
            echo -e "未做改动"
            before_show_menu
            return 0
        fi
    fi

    set_memlimit "$value"
    rc=$?
    if [[ $rc == 1 || $rc == 4 ]]; then
        [[ $cli == 0 ]] && before_show_menu
        return "$rc"
    fi

    if ! memlimit_pending; then
        # 没有待生效的变化：进程没在跑（下次启动自然用新值），或它拿到的已经是这个值。
        [[ $rc == 0 ]] && ! memlimit_main_pid >/dev/null &&
            echo -e "Sing2 当前未运行，下次启动时生效"
        [[ $cli == 0 ]] && before_show_menu
        return 0
    fi
    echo -e "${yellow}运行中的 Sing2 还在用旧值，重启后生效${plain}"
    if (( ${MEMLIMIT_WARNED:-0} > 0 )); then
        def=n
        echo -e "上面有提醒，看过再决定——这次默认不重启"
    fi
    if [[ $cli == 0 ]]; then
        confirm_restart "$def"
    elif [[ -t 0 ]]; then
        confirm_restart "$def" 0
    else
        echo -e "非交互调用，不自动重启：执行 ${green}sing2 restart${plain} 后生效"
    fi
    return 0
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
    # 向导生成的这份**几乎没有注释**（它是上面那段 heredoc 拼出来的），而它刚刚把
    # 安装时铺下来的那份带注释的配置整个换掉了。所以这里必须指一下模板在哪，
    # 否则运维再想看某个键是干什么的、有哪些取值，节点上已经没有地方可查了。
    if [[ -f "${CONF_DIR}/config.yml.example" ]]; then
        echo -e "${yellow}注意：向导生成的配置不带注释。${plain}完整注释版模板在 ${green}${CONF_DIR}/config.yml.example${plain}"
    fi
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
    echo "sing2 memlimit     - 查看内存软上限（默认不设）"
    echo "sing2 memlimit 值  - 设置内存软上限，如 1500MiB；off 取消"
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
 ${green}18.${plain} 设置内存软上限（GOMEMLIMIT）
 "
    show_status
    echo && read -rp "请输入选择 [0-18]: " num

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
        18) check_install && memlimit ;;
        *) echo -e "${red}请输入正确的数字 [0-18]${plain}" ;;
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
        "memlimit")  check_install 0 && memlimit 0 "${@:2}" ;;
        "install")   check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "version")   check_install 0 && show_Sing2_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
