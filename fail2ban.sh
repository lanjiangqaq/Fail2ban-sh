#!/usr/bin/env bash
#
# fail2ban-setup.sh — 一键交互式配置 fail2ban sshd jail
# 严格遵循 fail2ban 官方 jail.conf 规则语义：
#   maxretry: findtime 时间窗口内允许失败的次数，超过则封禁
#   findtime: 统计失败次数的时间窗口（单位：秒）
#   bantime : 封禁时长（单位：秒）
#   backend : 日志读取方式（systemd 用于纯 journald 系统，无 /var/log/auth.log 时使用）
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行（例如: sudo bash $0）" >&2
    exit 1
fi

JAIL_LOCAL="/etc/fail2ban/jail.local"
SSHD_CONFIG="/etc/ssh/sshd_config"

echo "===================================="
echo "   fail2ban sshd 一键配置脚本"
echo "===================================="
echo

# ---------- 检测日志 backend ----------
if [[ -f /var/log/auth.log ]]; then
    BACKEND="auto"
    LOGPATH="/var/log/auth.log"
    echo "[检测] 发现 /var/log/auth.log，使用 backend = auto"
else
    BACKEND="systemd"
    LOGPATH=""
    echo "[检测] 未发现 /var/log/auth.log（系统仅用 journald），使用 backend = systemd"
fi
echo

# ---------- 1. 是否更改 SSH 端口 ----------
CURRENT_PORT=$(grep -E '^\s*Port\s+[0-9]+' "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | tail -1)
CURRENT_PORT=${CURRENT_PORT:-22}

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
            echo "端口无效，请输入 1-65535 之间的数字。"
        fi
    done

    # 修改 sshd_config
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    if grep -qE '^\s*#?\s*Port\s+[0-9]+' "$SSHD_CONFIG"; then
        sed -i -E "s/^\s*#?\s*Port\s+[0-9]+/Port ${SSH_PORT}/" "$SSHD_CONFIG"
    else
        echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"
    fi
    echo "[SSH] 端口已修改为 ${SSH_PORT}，已备份原配置文件。"
    echo "[警告] 修改端口后需要重启 sshd 才生效；重启前请确保防火墙/安全组已放行新端口，"
    echo "        否则可能导致无法连接！"
else
    echo "[SSH] 保持当前端口 ${SSH_PORT} 不变。"
fi
echo

# ---------- 2. maxretry ----------
while true; do
    read -rp "允许失败尝试的最大次数 maxretry [默认 5]: " MAXRETRY
    MAXRETRY=${MAXRETRY:-5}
    if [[ "$MAXRETRY" =~ ^[0-9]+$ ]] && (( MAXRETRY >= 1 )); then
        break
    else
        echo "请输入大于等于 1 的整数。"
    fi
done
echo

# ---------- 3. findtime ----------
while true; do
    read -rp "统计失败次数的时间窗口 findtime，单位：分钟 [默认 10]: " FINDTIME_MIN
    FINDTIME_MIN=${FINDTIME_MIN:-10}
    if [[ "$FINDTIME_MIN" =~ ^[0-9]+$ ]] && (( FINDTIME_MIN >= 1 )); then
        FINDTIME=$(( FINDTIME_MIN * 60 ))
        break
    else
        echo "请输入大于等于 1 的整数（分钟）。"
    fi
done
echo

# ---------- 4. bantime（小时结算，-1 表示永久封禁） ----------
while true; do
    read -rp "封禁时长 bantime，单位：小时，永久封禁请输入 -1 [默认 24]: " BANTIME_HOUR
    BANTIME_HOUR=${BANTIME_HOUR:-24}
    if [[ "$BANTIME_HOUR" == "-1" ]]; then
        BANTIME=-1
        break
    elif [[ "$BANTIME_HOUR" =~ ^[0-9]+$ ]] && (( BANTIME_HOUR >= 1 )); then
        BANTIME=$(( BANTIME_HOUR * 3600 ))
        break
    else
        echo "请输入大于等于 1 的整数（小时），或输入 -1 表示永久封禁。"
    fi
done
echo

# ---------- 5. 是否启用递增封禁（bantime.increment，fail2ban 官方支持） ----------
read -rp "是否启用递增封禁时长（重复触犯者封禁时间逐次翻倍）？[y/N]: " ENABLE_INCREMENT
ENABLE_INCREMENT=${ENABLE_INCREMENT:-N}
echo

# ---------- 汇总确认 ----------
echo "===================================="
echo "配置汇总："
echo "  SSH 端口         : ${SSH_PORT}"
echo "  backend          : ${BACKEND}"
echo "  maxretry          : ${MAXRETRY} 次"
echo "  findtime          : ${FINDTIME_MIN} 分钟 (${FINDTIME} 秒)"
if [[ "$BANTIME" == "-1" ]]; then
    echo "  bantime           : 永久封禁"
else
    echo "  bantime           : ${BANTIME_HOUR} 小时 (${BANTIME} 秒)"
fi
echo "  递增封禁          : ${ENABLE_INCREMENT}"
echo "===================================="
read -rp "确认写入配置并重启 fail2ban？[y/N]: " CONFIRM
CONFIRM=${CONFIRM:-N}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消，未做任何更改。"
    exit 0
fi

# ---------- 安装 fail2ban（如未安装） ----------
if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "[安装] 未检测到 fail2ban，正在安装..."
    apt update -y
    apt install -y fail2ban
fi

# ---------- 备份旧配置 ----------
if [[ -f "$JAIL_LOCAL" ]]; then
    cp "$JAIL_LOCAL" "${JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
    echo "[备份] 旧的 jail.local 已备份。"
fi

# ---------- 生成 jail.local ----------
{
    echo "[DEFAULT]"
    echo "ignoreip = 127.0.0.1/8 ::1"
    echo "bantime  = ${BANTIME}"
    echo "findtime = ${FINDTIME}"
    echo "maxretry = ${MAXRETRY}"
    if [[ "$ENABLE_INCREMENT" =~ ^[Yy]$ ]]; then
        echo "bantime.increment = true"
        echo "bantime.factor = 2"
        echo "bantime.maxtime = 604800"
    fi
    echo
    echo "[sshd]"
    echo "enabled = true"
    echo "port    = ${SSH_PORT}"
    echo "filter  = sshd"
    if [[ "$BACKEND" == "systemd" ]]; then
        echo "backend = systemd"
    else
        echo "backend  = auto"
        echo "logpath  = ${LOGPATH}"
    fi
} > "$JAIL_LOCAL"

echo "[写入] ${JAIL_LOCAL} 已生成。"
echo

# ---------- 若修改了端口，同步重启 sshd ----------
if [[ "$CHANGE_PORT" =~ ^[Yy]$ ]]; then
    echo "[SSH] 正在重启 sshd 服务以应用新端口..."
    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        echo "[SSH] sshd 已重启，新端口 ${SSH_PORT} 生效。"
    else
        echo "[警告] sshd 重启失败，请手动检查: systemctl status ssh"
    fi
fi

# ---------- 重启 fail2ban ----------
systemctl restart fail2ban
sleep 1

echo
echo "===================================="
echo "配置完成，当前状态："
echo "===================================="
systemctl is-active fail2ban && echo "fail2ban 服务：运行中" || echo "fail2ban 服务：未运行，请检查 journalctl -u fail2ban"
echo
fail2ban-client status sshd 2>/dev/null || echo "无法获取 sshd jail 状态，请检查 fail2ban 日志: /var/log/fail2ban.log"
echo
echo "提示："
echo "  查看规则详情: sudo fail2ban-client status sshd"
echo "  查看运行日志: sudo tail -f /var/log/fail2ban.log"
echo "  解封某 IP   : sudo fail2ban-client set sshd unbanip <IP>"
