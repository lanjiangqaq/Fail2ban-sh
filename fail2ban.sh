#!/usr/bin/env bash
#
# fail2ban-setup.sh — fail2ban sshd jail 配置与卸载脚本
#

# 移除严苛的自动退出机制，避免命令未匹配时引发静默崩溃
# 仅保留基础的权限验证

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行此脚本（例如: sudo bash $0）" >&2
    exit 1
fi

JAIL_LOCAL="/etc/fail2ban/jail.local"
SSHD_CONFIG="/etc/ssh/sshd_config"

# ==================== 卸载功能 ====================
uninstall_fail2ban() {
    echo "===================================="
    echo "         卸载 fail2ban"
    echo "===================================="
    read -rp "警告：此操作将停止服务并彻底清除 fail2ban 及其所有配置，是否继续？[y/N]: " CONFIRM_PURGE
    CONFIRM_PURGE=${CONFIRM_PURGE:-N}

    if [[ ! "$CONFIRM_PURGE" =~ ^[Yy]$ ]]; then
        echo "已取消卸载操作。"
        exit 0
    fi

    echo "[1/4] 停止并禁用 fail2ban 服务..."
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true

    echo "[2/4] 卸载软件包及依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y fail2ban
        apt-get autoremove -y
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y fail2ban
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y fail2ban
    fi

    echo "[3/4] 清理残留目录与配置..."
    rm -rf /etc/fail2ban /var/lib/fail2ban /var/log/fail2ban* /var/run/fail2ban

    echo "[4/4] 删除脚本自身..."
    SCRIPT_PATH=$(readlink -f "$0")
    echo "卸载完成。"
    rm -f "$SCRIPT_PATH"
    exit 0
}

# ==================== 配置功能 ====================
setup_fail2ban() {
    echo "===================================="
    echo "     fail2ban sshd 交互式配置"
    echo "===================================="
    echo

    # ---------- 检测日志 backend ----------
    if [[ -f /var/log/auth.log ]]; then
        BACKEND="auto"
        LOGPATH="/var/log/auth.log"
        echo "[检测] 发现 /var/log/auth.log，设置 backend = auto"
    else
        BACKEND="systemd"
        LOGPATH=""
        echo "[检测] 未发现 /var/log/auth.log，设置 backend = systemd"
    fi
    echo

    # ---------- 1. 安全读取 SSH 端口配置 ----------
    CURRENT_PORT=""
    if [[ -f "$SSHD_CONFIG" ]]; then
        CURRENT_PORT=$(grep -E '^\s*Port\s+[0-9]+' "$SSHD_CONFIG" 2>/dev/null | tail -n 1 | awk '{print $2}')
    fi
    
    # 如果未检测到或检测结果不是纯数字，则默认使用 22
    if [[ -z "$CURRENT_PORT" || ! "$CURRENT_PORT" =~ ^[0-9]+$ ]]; then
        CURRENT_PORT=22
    fi

    read -rp "是否修改 SSH 端口？当前端口为 ${CURRENT_PORT}。[y/N]: " CHANGE_PORT
    CHANGE_PORT=${CHANGE_PORT:-N}

    SSH_PORT="$CURRENT_PORT"
    if [[ "$CHANGE_PORT" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "请输入新的 SSH 端口（1-65535）: " NEW_PORT
            if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1 && NEW_PORT <= 65535 )); then
                SSH_PORT="$NEW_PORT"
                break
            else
                echo "端口格式无效，请输入 1-65535 范围内的有效整数。"
            fi
        done

        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        if grep -qE '^\s*#?\s*Port\s+[0-9]+' "$SSHD_CONFIG"; then
            sed -i -E "s/^\s*#?\s*Port\s+[0-9]+/Port ${SSH_PORT}/" "$SSHD_CONFIG"
        else
            echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"
        fi
        echo "[SSH] 端口已更新为 ${SSH_PORT}，原配置已备份。"
        echo "[警告] 请务必确认防火墙/安全组已开放该端口，以防连接中断。"
    else
        echo "[SSH] 维持当前端口 ${SSH_PORT}。"
    fi
    echo

    # ---------- 2. maxretry ----------
    while true; do
        read -rp "允许最大失败尝试次数 maxretry [默认 5]: " MAXRETRY
        MAXRETRY=${MAXRETRY:-5}
        if [[ "$MAXRETRY" =~ ^[0-9]+$ ]] && (( MAXRETRY >= 1 )); then
            break
        else
            echo "输入无效，请输入大于等于 1 的整数。"
        fi
    done
    echo

    # ---------- 3. findtime ----------
    while true; do
        read -rp "统计时间窗口 findtime（单位：分钟）[默认 10]: " FINDTIME_MIN
        FINDTIME_MIN=${FINDTIME_MIN:-10}
        if [[ "$FINDTIME_MIN" =~ ^[0-9]+$ ]] && (( FINDTIME_MIN >= 1 )); then
            FINDTIME=$(( FINDTIME_MIN * 60 ))
            break
        else
            echo "输入无效，请输入大于等于 1 的整数。"
        fi
    done
    echo

    # ---------- 4. bantime (以小时为单位) ----------
    while true; do
        read -rp "封禁时长 bantime（单位：小时，永久封禁请输入 -1）[默认 24]: " BANTIME_HOUR
        BANTIME_HOUR=${BANTIME_HOUR:-24}
        if [[ "$BANTIME_HOUR" == "-1" ]]; then
            BANTIME="-1"
            break
        elif [[ "$BANTIME_HOUR" =~ ^[0-9]+$ ]] && (( BANTIME_HOUR >= 1 )); then
            BANTIME="${BANTIME_HOUR}h"
            break
        else
            echo "输入无效，请输入大于等于 1 的整数表示小时，或输入 -1 表示永久封禁。"
        fi
    done
    echo

    # ---------- 5. 递增封禁 ----------
    read -rp "是否启用递增封禁机制（bantime.increment）？[y/N]: " ENABLE_INCREMENT
    ENABLE_INCREMENT=${ENABLE_INCREMENT:-N}
    echo

    # ---------- 配置确认 ----------
    echo "===================================="
    echo "配置确认："
    echo "  SSH 端口       : ${SSH_PORT}"
    echo "  日志后端       : ${BACKEND}"
    echo "  最大尝试次数   : ${MAXRETRY} 次"
    echo "  统计周期       : ${FINDTIME_MIN} 分钟 (${FINDTIME} 秒)"
    if [[ "$BANTIME" == "-1" ]]; then
        echo "  封禁时长       : 永久封禁 (-1)"
    else
        echo "  封禁时长       : ${BANTIME_HOUR} 小时 (${BANTIME})"
    fi
    echo "  递增封禁       : ${ENABLE_INCREMENT}"
    echo "===================================="
    read -rp "确认将上述配置写入并重启服务？[y/N]: " CONFIRM
    CONFIRM=${CONFIRM:-N}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "操作已取消。"
        exit 0
    fi

    # ---------- 依赖检测与安装 ----------
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "[系统] 未安装 fail2ban，执行安装程序..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y fail2ban
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y fail2ban
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release fail2ban
        fi
    fi

    # ---------- 写入 jail.local ----------
    if [[ -f "$JAIL_LOCAL" ]]; then
        cp "$JAIL_LOCAL" "${JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    {
        echo "[DEFAULT]"
        echo "ignoreip = 127.0.0.1/8 ::1"
        echo "bantime  = ${BANTIME}"
        echo "findtime = ${FINDTIME}"
        echo "maxretry = ${MAXRETRY}"
        if [[ "$ENABLE_INCREMENT" =~ ^[Yy]$ ]]; then
            echo "bantime.increment = true"
            echo "bantime.factor = 2"
            echo "bantime.maxtime = 168h"
        fi
        echo
        echo "[sshd]"
        echo "enabled  = true"
        echo "port     = ${SSH_PORT}"
        echo "filter   = sshd"
        if [[ "$BACKEND" == "systemd" ]]; then
            echo "backend  = systemd"
        else
            echo "backend  = auto"
            echo "logpath  = ${LOGPATH}"
        fi
    } > "$JAIL_LOCAL"

    echo "[配置] 已更新 ${JAIL_LOCAL}"

    # ---------- 重启对应服务 ----------
    if [[ "$CHANGE_PORT" =~ ^[Yy]$ ]]; then
        echo "[SSH] 正在重启 SSH 守护进程以应用新端口..."
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || echo "[警告] SSH 服务重启失败，请手动检查服务状态。"
    fi

    systemctl restart fail2ban || echo "[警告] fail2ban 重启出现问题，请检查。"
    sleep 1

    echo
    echo "===================================="
    echo "部署完成，当前服务状态："
    echo "===================================="
    if systemctl is-active --quiet fail2ban; then
        echo "fail2ban 服务状态：运行中"
    else
        echo "fail2ban 服务状态：未正常运行"
    fi
    echo
    fail2ban-client status sshd 2>/dev/null || echo "无法获取 sshd jail 状态，请检查 /var/log/fail2ban.log"
}

# ==================== 主菜单 ====================
clear
echo "===================================="
echo "    fail2ban 管理管理控制台"
echo "===================================="
echo "1. 安装 / 配置 fail2ban (sshd jail)"
echo "2. 完全卸载 fail2ban 并删除本脚本"
echo "3. 退出"
echo "===================================="
read -rp "请输入选项 [1-3]: " CHOICE

case "$CHOICE" in
    1)
        setup_fail2ban
        ;;
    2)
        uninstall_fail2ban
        ;;
    3)
        echo "退出脚本。"
        exit 0
        ;;
    *)
        echo "无效选项，执行终止。"
        exit 1
        ;;
esac
