# Fail2ban-sh

Fail2ban 一键懒人配置脚本 —— 交互式配置 sshd 防爆破规则，自动适配新旧系统的日志方案，无需手动排查 `auth.log` 缺失、`backend` 选型等常见坑。

## 特性

- ✅ **自动检测日志 backend**：自动判断系统是否存在 `/var/log/auth.log`；对于 Debian 12+ 等默认不装 `rsyslog`、仅用 `journald` 的系统，自动切换到 `backend = systemd`，避免 `Have not found any log file for sshd jail` 报错
- ✅ **交互式配置**：全程命令行问答，无需手动编辑 `jail.local`
- ✅ **可选修改 SSH 端口**：自动备份 `sshd_config`，改端口后自动重启 `sshd` 并同步更新 fail2ban 的 `port` 字段
- ✅ **严格遵循 fail2ban 官方规则语义**：
  - `maxretry`：时间窗口内允许失败的最大次数
  - `findtime`：统计失败次数的时间窗口（脚本内以分钟为单位输入，自动换算为秒）
  - `bantime`：封禁时长（脚本内以小时为单位输入，自动换算为秒；支持 `-1` 永久封禁）
- ✅ **可选递增封禁**（`bantime.increment`）：重复触犯者封禁时长按 2 倍递增，封顶 7 天
- ✅ 自动安装 fail2ban（如未安装）、自动备份旧配置、执行完自动展示 jail 状态

## 使用方法

```bash
git clone https://github.com/lanjiangqaq/Fail2ban-sh.git
cd Fail2ban-sh
sudo bash fail2ban.sh
```

或者直接一行命令拉取运行：

```bash
curl -fsSL https://raw.githubusercontent.com/lanjiangqaq/Fail2ban-sh/main/fail2ban.sh -o fail2ban.sh && sudo bash fail2ban.sh
```

## 交互流程

脚本会依次询问：

1. **是否修改 SSH 端口**（会显示当前端口，回车默认不改）
2. **`maxretry`** — 允许失败的最大次数（默认 5）
3. **`findtime`** — 统计时间窗口，单位分钟（默认 10）
4. **`bantime`** — 封禁时长，单位小时（默认 24，可填 `-1` 永久封禁）
5. **是否启用递增封禁**

确认无误后自动写入 `/etc/fail2ban/jail.local` 并重启服务。

## ⚠️ 注意事项

- **修改 SSH 端口前，务必先在云服务商安全组 / 本地防火墙放行新端口**，否则重启 sshd 后可能导致无法远程连接
- 脚本会自动备份 `sshd_config` 和 `jail.local`（带时间戳后缀），出问题可随时回滚
- 仅支持 Debian/Ubuntu 系（apt 系）

## 常用排查命令

```bash
# 查看所有已加载的 jail
sudo fail2ban-client status

# 查看 sshd jail 详情（封禁列表、失败计数等）
sudo fail2ban-client status sshd

# 查看运行日志
sudo tail -f /var/log/fail2ban.log

# 解封某个 IP
sudo fail2ban-client set sshd unbanip <IP>
```

## License

MIT
