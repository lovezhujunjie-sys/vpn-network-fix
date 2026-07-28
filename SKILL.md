---
name: VPN网络修复
description: 修复老曾 Mac 上 Clash Verge 突然断网的问题。当用户说"连不上网""Clash挂了""代理失效""网断了""系统代理开关点不动""Clash Verge连不上"时触发。底层诊断+一键修复：mihomo内核僵死重启、系统代理端口被重置到2023（应为7897）、权限不足导致开关灰显。2026-07-25实战验证通过。
---

# VPN网络修复（Clash Verge 断网急救）

> 2026-07-25 实战验证：老曾 Mac 上 Clash Verge Rev（mihomo 内核）反复出现"连不上网"，根因是系统代理被外部程序重置到 2023 端口，而实际服务在 7897。

---

## 0. 环境信息

- **工具**：Clash Verge Rev v2.5.1，mihomo 内核
- **配置目录**：`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/`
- **配置文件**：`clash-verge.yaml`（`mixed-port: 7897`）
- **日志目录**：`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs/`
- **Unix Socket**：`/tmp/verge/verge-mihomo.sock`
- **注意**：ClashX 已弃用，两者会冲突

---

## 1. 快速诊断（3步）

```bash
# 1. 看系统代理指向哪个端口
networksetup -getwebproxy Wi-Fi | grep Port
# 正常应该是 7897，如果是 2023 或其他值就是问题所在

# 2. 看 7897 有没有在监听
netstat -an | grep 7897 | grep LISTEN
# 没有输出 = mihomo 没绑定端口（僵死）

# 3. 看 mihomo 进程在不在
pgrep -f verge-mihomo
# 有 PID 但没端口 = 僵死状态
```

---

## 2. 一键修复

### 场景A：7897 在监听，只是系统代理指向错误

```bash
osascript -e 'do shell script "networksetup -setwebproxy Wi-Fi 127.0.0.1 7897 && networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 7897" with administrator privileges'
```

> 用 `osascript` 弹窗输密码，避免 `sudo` 在非交互终端卡住。

### 场景B：mihomo 僵死（进程在但没端口）或 7897 没监听

```bash
# 1. 杀掉 Clash Verge 全家桶
pkill -f "Clash Verge"
sleep 3

# 2. 重启
open -a "Clash Verge"
sleep 6

# 3. 确认 7897 恢复
netstat -an | grep 7897 | grep LISTEN

# 4. 修正系统代理
osascript -e 'do shell script "networksetup -setwebproxy Wi-Fi 127.0.0.1 7897 && networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 7897" with administrator privileges'
```

### 场景C：Clash Verge 系统代理开关灰显点不动

原因：Clash Verge 尝试用 PAC 模式或没有管理员权限。直接命令行设置 HTTP 代理（见场景A），然后去 Clash Verge 设置里确认代理模式是「规则模式」而非 PAC。

---

## 3. 验证修复

```bash
# 直连测试
curl -s -o /dev/null -w "百度: HTTP %{http_code}\n" --connect-timeout 5 https://www.baidu.com

# 代理测试（Google 需走代理）
curl -s -o /dev/null -w "Google: HTTP %{http_code}\n" --connect-timeout 10 -x http://127.0.0.1:7897 https://www.google.com
```

两个都 HTTP 200 = 修复成功。

---

## 4. 根因与预防

### 为什么系统代理会被改成 2023？

- macOS 网络切换（Wi-Fi ↔ 有线 ↔ 热点）时可能重置代理设置
- 其他代理类软件（VPN、Surge 等）可能抢占设置
- Clash Verge 自身 bug 在某些版本会将端口写错

### 预防措施

1. **不要同时开多个代理工具**（ClashX 已移除自启动）
2. **Clash Verge 设置里确认是「规则模式」不是 PAC**
3. 如果频繁复发，可以写个 launchd 定时检查脚本

---

## 5. 已知坑

| 坑 | 现象 | 解法 |
|---|---|---|
| `sudo` 卡 Password | 非交互终端无法输入密码 | 改用 `osascript` 弹窗 |
| mihomo 僵死 | 进程在、端口没绑定 | `pkill` + `open -a` 重启 |
| 开关灰显 | UI 点不动 | 命令行直接设 + 检查是否 PAC 模式 |
| ClashX 冲突 | 两个代理工具抢端口 | 只保留 Clash Verge，ClashX 移除自启动 |
