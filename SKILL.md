---
name: VPN网络修复
description: 修复老曾 Mac 上 Clash Verge Rev / mihomo 突然断网、部分应用打不开、系统代理端口错误、内核僵死或代理开关灰显。用户说“连不上网”“Clash挂了”“代理失效”“网断了”“系统代理开关点不动”“浏览器打不开但终端能联网”时使用；按配置端口、监听端口、HTTP/HTTPS 系统代理和显式流量四层诊断，避免被终端代理环境变量或 lsof 漏报误导。
---

# VPN网络修复（Clash Verge 断网急救）

> 2026-07-25 首次验证：系统代理被重置到 `2023`，实际服务在 `7897`。
>
> 2026-08-02 再次验证：HTTP 代理关闭、HTTPS 代理单独指向无监听的 `2023`；mihomo 与 `7897` 正常。只修系统代理即可恢复，无须重启内核。

## 0. 环境

- Clash Verge Rev v2.5.1，mihomo 内核
- 配置：`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml`
- 日志：`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs/`
- Unix Socket：`/tmp/verge/verge-mihomo.sock`
- ClashX 已弃用；不要同时运行多个代理工具

## 1. 先诊断，后重启

不要先假设端口永远是 `7897`。先从配置读取 `mixed-port`，再核对四层事实：

1. 配置端口。
2. mihomo 实际监听端口。
3. macOS 的 HTTP 与 HTTPS 系统代理。
4. 强制直连与显式代理的真实访问结果。

优先运行只读诊断脚本：

```bash
bash scripts/diagnose.sh
```

也可手动核对：

```bash
clash_config="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
proxy_port=$(awk -F: '/^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$clash_config")

networksetup -getwebproxy Wi-Fi
networksetup -getsecurewebproxy Wi-Fi
scutil --proxy
netstat -anv -p tcp | grep -E "[.:]${proxy_port}[[:space:]].*LISTEN"
pgrep -fal 'verge-mihomo|Clash Verge|clash-verge'

# 真直连：忽略 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY，防止假阳性
curl --noproxy '*' -L -sS -o /dev/null -w '直连百度: HTTP %{http_code}\n' \
  --connect-timeout 5 --max-time 12 https://www.baidu.com

# 真代理：显式指定配置中的 mixed-port
curl -L -sS -o /dev/null -w '代理Google: HTTP %{http_code}\n' \
  --connect-timeout 8 --max-time 15 -x "http://127.0.0.1:${proxy_port}" https://www.google.com
```

不要只查 `networksetup -getwebproxy Wi-Fi`。HTTP 与 HTTPS 可以出现不同的启用状态和端口，本次故障就是 HTTPS 单独错指 `2023`。

不要用 `lsof` 的空结果直接判定“没监听”。2026-08-02 实测 `lsof` 漏报 `7897`，而 `netstat` 和显式代理请求都确认 mihomo 正常；以 `netstat + curl -x` 双证据为准。

## 2. 按诊断矩阵修复

### 场景 A：配置端口正在监听，显式代理可访问，但系统代理错误

只修系统代理，不重启 Clash Verge。把下面的 `7897` 替换为当前配置中实际读取到的 `mixed-port`：

```bash
osascript -e 'do shell script "networksetup -setwebproxy Wi-Fi 127.0.0.1 7897 && networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 7897" with administrator privileges'
```

使用 `osascript` 弹出管理员授权，避免非交互终端里的 `sudo` 卡住。`networksetup -setwebproxy` 与 `-setsecurewebproxy` 会同时写入地址、端口并启用对应代理。

### 场景 B：mihomo 进程在，但配置端口没监听或显式代理失败

```bash
pkill -f "Clash Verge"
sleep 3
open -a "Clash Verge"
sleep 6
bash scripts/diagnose.sh
```

只有诊断脚本确认监听和显式代理恢复后，才执行场景 A 的系统代理修正。

### 场景 C：系统代理开关灰显

直接使用场景 A 的命令设置 HTTP/HTTPS 代理，再在 Clash Verge 中确认代理模式是“规则模式”，不是 PAC。若仍灰显，再检查管理员权限，不要反复点击。

### 场景 D：直连也失败

如果 `curl --noproxy '*'` 也失败，先检查 Wi-Fi 默认路由和 DNS；这不是单纯的 Clash 系统代理端口问题。不要通过重启 mihomo 掩盖底层网络故障。

## 3. 验收

修复后重新运行：

```bash
bash scripts/diagnose.sh
```

完成标准：

- HTTP 与 HTTPS 均为 `Enabled: Yes`，并指向 `127.0.0.1:<mixed-port>`。
- `netstat` 显示该端口由 mihomo 监听。
- 强制直连和显式代理最终返回 HTTP 2xx/3xx；脚本返回码为 0。
- 再用一个真实应用打开网页，排除“命令行通、应用仍未恢复”。

Google 有时先返回 302；诊断命令使用 `-L` 跟随跳转，不把正常重定向误判为失败。

## 4. 已知坑

| 坑 | 误判/现象 | 正确做法 |
|---|---|---|
| 只查 HTTP 代理 | 看不到 HTTPS 单独启用且端口错误 | 同时查 webproxy、securewebproxy 和 `scutil --proxy` |
| 普通 `curl` 测“直连” | 环境变量已走代理，故障被掩盖 | 直连加 `--noproxy '*'` |
| `lsof` 无输出 | 误判 mihomo 没监听 | 用 `netstat`，再用 `curl -x` 交叉验证 |
| 一看到断网就重启 | 中断正常内核和现有连接 | 监听与显式代理正常时只修系统代理 |
| `sudo` 卡 Password | 非交互终端无法输入密码 | 用 `osascript` 弹管理员授权 |
| 开关灰显 | UI 点不动 | 命令行设置并检查 PAC/权限 |
| 多代理工具冲突 | 端口反复被改 | 只保留 Clash Verge，移除 ClashX 自启动 |
