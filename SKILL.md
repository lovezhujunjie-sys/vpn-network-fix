---
name: VPN网络修复
description: 修复老曾 Mac 上 Clash Verge Rev / mihomo 突然断网、部分应用打不开、系统代理端口错误、内核根本没起来、节点大面积失效、代理开关灰显。用户说“连不上网”“Clash挂了”“代理失效”“网断了”“上不了网了”“谁动了我的clash”“系统代理开关点不动”“浏览器打不开但终端能联网”时使用；按“内核是否在跑 / 配置端口 / 监听端口 / 系统代理 / 显式流量 / 节点是否活着”六层诊断，避免被 GUI 进程、终端代理环境变量或 lsof 漏报误导。
---

# VPN网络修复（Clash Verge 断网急救）

> 2026-07-25 首次验证：系统代理被重置到 `2023`，实际服务在 `7897`。
>
> 2026-08-02 再次验证：HTTP 代理关闭、HTTPS 代理单独指向无监听的 `2023`；mihomo 与 `7897` 正常。只修系统代理即可恢复，无须重启内核。
>
> **2026-10-27 第三次验证（新根因）：设置一个字没变，是 mihomo 内核压根没起来**——Clash Verge 自动更新流程把 helper service 卸了，重装时管理员授权框被取消（错误 `-128 用户已取消`），service 模式内核无法启动。系统代理仍指着 `7897`，端口没人接，全网流量进黑洞。用 `verge-mihomo` 手动拉起内核即刻恢复，无须改任何设置。

## 0. 环境

- Clash Verge Rev v2.5.2（2026-10-27 实测；自动更新会拉 v2.5.8，见场景 E）
- 配置目录：`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/`
- 运行时配置：`clash-verge.yaml`（`mixed-port`、`secret`、`proxies` 都在这里）
- 界面偏好：`verge.yaml`（⚠️ 这里的 `enable_system_proxy` **不代表**系统代理真实状态）
- 日志：`.../clash-verge-rev/logs/latest.log`
- Unix Socket：`/tmp/verge/verge-mihomo.sock`（调 API 用，不走 TCP）
- 内核二进制：`/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo`
- ClashX 已弃用；不要同时运行多个代理工具

## 1. 先诊断，后动手

不要先假设端口永远是 `7897`。按六层顺序核对事实，**内核这一层排最前面**：

1. 内核到底在不在跑（GUI 在 ≠ 内核在）。
2. 配置端口（`clash-verge.yaml` 的 `mixed-port`）。
3. 内核实际监听端口。
4. macOS 的 HTTP 与 HTTPS 系统代理。
5. 强制直连与显式代理的真实访问结果。
6. 主选节点是否活着（国内通、国外不通就是这层）。

优先运行只读诊断脚本：

```bash
bash scripts/diagnose.sh
```

也可手动核对：

```bash
clash_dir="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
clash_config="$clash_dir/clash-verge.yaml"
proxy_port=$(awk -F: '/^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$clash_config")

# ⚠️ 内核与 GUI 必须分开查，合并查会误判
pgrep -fal "MacOS/verge-mihomo" || echo "❌ 内核没跑"
pgrep -fal "MacOS/clash-verge$" || echo "(GUI 也没跑)"

networksetup -getwebproxy Wi-Fi
networksetup -getsecurewebproxy Wi-Fi
scutil --proxy
netstat -anv -p tcp | grep -E "[.:]${proxy_port}[[:space:]].*LISTEN"

# 真直连：忽略 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY，防止假阳性
curl --noproxy '*' -L -sS -o /dev/null -w '直连百度: HTTP %{http_code}\n' \
  --connect-timeout 5 --max-time 12 https://www.baidu.com

# 真代理：显式指定配置中的 mixed-port
curl -L -sS -o /dev/null -w '代理Google: HTTP %{http_code}\n' \
  --connect-timeout 8 --max-time 15 -x "http://127.0.0.1:${proxy_port}" https://www.google.com
```

### 诊断禁区（都是真踩过的）

- **不要把 GUI 进程当内核**。`ps aux | grep -i clash` 里出现 `clash-verge` 只说明界面活着；内核进程名是 `verge-mihomo`，没有它就等于断网。2026-10-27 就是只看到 GUI、没看到 `verge-mihomo`。
- **不要用 `verge.yaml` 的 `enable_system_proxy` 判断系统代理**。2026-10-27 该值是 `false`，而 `scutil --proxy` 显示 HTTP/HTTPS 都开着并指向 `7897`。界面记的账和系统真实状态是两本账，只认 `scutil`。
- **不要只查 `networksetup -getwebproxy Wi-Fi`**。HTTP 与 HTTPS 可以出现不同的启用状态和端口，2026-08-02 就是 HTTPS 单独错指 `2023`。
- **`lsof` 正结果可信，负结果不可信**。2026-08-02 实测 `lsof` 漏报过真实存在的监听；2026-10-27 它准确报了 `7897` 无人监听。结论：`lsof` 说有监听就算数，说没有必须用 `netstat + curl -x` 复核。

## 2. 按诊断矩阵修复

| 内核 | 端口监听 | 显式代理 | 系统代理 | 动作 |
|---|---|---|---|---|
| 没跑 | 无 | 失败 | 任意（常残留指向混合端口） | **场景 E**：手动拉起内核 / 修 service |
| 在跑 | 有 | 成功 | 端口错误/未启用 | **场景 A**：只修系统代理 |
| 在跑 | 无 / 显式代理失败 | 失败 | 任意 | **场景 B**：重启 GUI；仍不监听则转场景 E |
| 在跑 | 有 | 成功 | 正确 | 国内通、国外不通 → **场景 F** 查节点 |
| 任意 | 任意 | 任意 | 任意 | 直连也失败 → **场景 D**，先查 Wi-Fi/DNS |

### 场景 A：内核正常，但系统代理错误

只修系统代理，不重启 Clash Verge。把下面的 `7897` 替换为当前配置中实际读取到的 `mixed-port`：

```bash
osascript -e 'do shell script "networksetup -setwebproxy Wi-Fi 127.0.0.1 7897 && networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 7897" with administrator privileges'
```

使用 `osascript` 弹出管理员授权，避免非交互终端里的 `sudo` 卡住。`networksetup -setwebproxy` 与 `-setsecurewebproxy` 会同时写入地址、端口并启用对应代理。

### 场景 B：内核进程在，但配置端口没监听或显式代理失败

```bash
pkill -f "Clash Verge"
sleep 3
open -a "Clash Verge"
sleep 6
bash scripts/diagnose.sh
```

重启后若日志出现 `服务需要重装` / `failed to install service`，不要再重启，直接转场景 E。

只有诊断脚本确认监听和显式代理恢复后，才执行场景 A 的系统代理修正。

### 场景 C：系统代理开关灰显

直接使用场景 A 的命令设置 HTTP/HTTPS 代理，再在 Clash Verge 中确认代理模式是“规则模式”，不是 PAC。若仍灰显，再检查管理员权限（多半是 helper service 坏了，转场景 E），不要反复点击。

### 场景 D：直连也失败

如果 `curl --noproxy '*'` 也失败，先检查 Wi-Fi 默认路由和 DNS；这不是单纯的 Clash 系统代理端口问题。不要通过重启 mihomo 掩盖底层网络故障。

### 场景 E（2026-10-27 新增）：内核根本没起来，helper service 被卸掉了

**典型现象**：所有 App 打不开网页，但终端里 `curl --noproxy '*' https://www.baidu.com` 是 200。GUI 图标在、能点开，但内核进程不存在，`7897` 无人监听。

**根因链**（照 `logs/latest.log` 对时间线）：

```
昨天 12:19  后台自动下载 v2.5.8 更新包，标记"下次启动安装"
今天 10:20  开机自启 → 走更新流程 → [Service] 服务需要重装，执行重装流程
             [Service] uninstall service
今天 10:25  ERROR [Service] failed to install service code: 1,
             details: 0:560: execution error: 用户已取消。 (-128)
之后        ERROR Admin privileges required to run networksetup ...
             INFO  [Core] System proxy is disabled.
```

即：**先卸了、没装回来 → 内核起不来**。此时系统代理仍指着 `7897`（Mac 侧没人清），于是全部流量进黑洞。这不是谁改了设置，是自动更新把自己搞断的。

**第一步急救（不需要密码，立即恢复上网）**：

```bash
bash scripts/fix-core-manual.sh
```

它做的事等价于：

```bash
mkdir -p /tmp/verge
cd "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
nohup "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo" \
  -d "$PWD" -f "$PWD/clash-verge.yaml" > /tmp/verge-manual.log 2>&1 &
sleep 4
lsof -nP -iTCP:7897 -sTCP:LISTEN
```

关键点：**不碰任何设置文件、不碰系统代理**。因为系统代理本来就是对的（指向 7897），只缺一个来接的人。这也是“恢复到昨天中午的设置”能一次到位的原因——设置根本没坏。

启动初期日志出现 `context canceled` / `operation was canceled` 是并发探测被取消，属正常噪音；只要能 curl 通就不用管。

**局限（必须当面告诉老曾）**：手动内核是临时工，**重启电脑即失效**，GUI 也不认它。要一劳永逸必须修 service，那一步会弹系统管理员密码框，**只能他本人输**。

**第二步永久修复**：在 Clash Verge 界面里重新安装服务（设置 → 服务模式，点安装/重装），或让他手输一次密码走 `osascript ... with administrator privileges`。修好前叮嘱：**别重启电脑、别在 GUI 里点“重启内核”**（会跟手动内核抢 7897）。

### 场景 F（2026-10-27 新增）：内核正常但节点死了，国内通、国外时通时不通

**典型现象**：百度秒开，GitHub / YouTube 有时 200 有时 000，ChatGPT 403。机场节点大面积故障。

先看主选组当前钉在哪个节点，再测这一组还有谁活着：

```bash
sock=/tmp/verge/verge-mihomo.sock
secret=$(awk -F: '/^secret:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' \
  "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml")

# 组结构 + 当前选中
curl -s --unix-socket $sock -H "Authorization: Bearer $secret" \
  "http://localhost/proxies/$(python3 -c 'import urllib.parse;print(urllib.parse.quote("亏本机场"))')"

# 组内测速（把不可达节点筛出来）
curl -s -m 40 --unix-socket $sock -H "Authorization: Bearer $secret" \
  "http://localhost/group/$(python3 -c 'import urllib.parse;print(urllib.parse.quote("亏本机场"))')/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000"
```

判据：**当前选中的节点不在测速可用列表里 = 这个节点已经死了**，这是“能上但时通时不通”的直接原因。2026-10-27 主组钉在「🇸🇬新加坡」，27 个成员只测出 4 个活着，新加坡不在其中。

**切组**（切到 URLTest 自动挑最快，长期最省心）：

```bash
bash scripts/node-switch.sh auto      # 切到「自动选择」
bash scripts/node-switch.sh list      # 看组和当前节点
bash scripts/node-switch.sh set "🇺🇸美国圣何塞"  # 手动指定
```

API 原理（`scripts/node-switch.sh` 内部就是它）：

```bash
curl -s -X PUT --unix-socket $sock -H "Authorization: Bearer $secret" \
  -H "Content-Type: application/json" -d '{"name":"自动选择"}' \
  "http://localhost/proxies/$(python3 -c 'import urllib.parse;print(urllib.parse.quote("亏本机场"))')"
```

注意：组名是中文，URL 里必须 percent-encode，手打必错，一律走脚本。

## 3. 验收

修复后重新运行：

```bash
bash scripts/diagnose.sh
```

完成标准：

- `verge-mihomo` 内核进程存在（不是只有 `clash-verge`）。
- HTTP 与 HTTPS 均为 `Enabled: Yes`，并指向 `127.0.0.1:<mixed-port>`。
- `netstat` 显示该端口由 mihomo 监听。
- 强制直连和显式代理最终返回 HTTP 2xx/3xx；脚本返回码为 0。
- **国外站要连测两次**：只测一次会把偶发成功当稳定。国内 + YouTube + GitHub 各两次都通才算好。
- 再用一个真实应用打开网页，排除“命令行通、应用仍未恢复”。

参考基准（2026-10-27 修复后实测）：百度 0.06s / YouTube 2～3s / GitHub 1.6～3.4s。

### 什么算“通”，什么算“断”

判断链路通不通，看**有没有拿到 HTTP 响应**，不看状态码好不好看：

| 返回 | 含义 |
|---|---|
| 204 | 探针正常（`gstatic/generate_204` 是首选探针）|
| 200 / 301 / 302 | 通 |
| **403** | 通（ChatGPT 常见，Cloudflare 拦节点，换节点可解）|
| **404** | 通（`api.anthropic.com` 根路径就是 404）|
| **429** | 通但被限流（拿 `google.com` 当探针反复测就会 429）|
| **000** | 真断（连不上）|

所以：**不要拿 `google.com` 当连通性探针**，2026-10-27 实测它会返回 429 并把“链路健康”误判成故障。用 `https://www.gstatic.com/generate_204`。ChatGPT 403、`api.anthropic.com` 根路径 404，都说明链路已通，不要当断网。

## 4. 已知坑

| 坑 | 误判/现象 | 正确做法 |
|---|---|---|
| 看到 GUI 进程就以为内核在 | `clash-verge` 在跑，`verge-mihomo` 没跑，全网上不了 | 分开 `pgrep`，内核名是 `verge-mihomo` |
| 用 `verge.yaml` 的 `enable_system_proxy` 判断系统代理 | 值是 `false`，系统代理其实开着 | 只认 `scutil --proxy` |
| 只查 HTTP 代理 | 看不到 HTTPS 单独启用且端口错误 | 同时查 webproxy、securewebproxy 和 `scutil --proxy` |
| 普通 `curl` 测“直连” | 环境变量已走代理，故障被掩盖 | 直连加 `--noproxy '*'` |
| `lsof` 无输出 | 误判 mihomo 没监听 | `lsof` 正结果可信、负结果用 `netstat` 复核 |
| 一看到断网就重启 | 中断正常内核和现有连接；service 坏了重启也没用 | 先分层诊断；日志出现 `failed to install service` 就别再重启 |
| 一看到断网就以为“设置被改了” | 反复折腾配置，越改越乱 | 先比对 profile 与系统代理是否真的变了；2026-10-27 就是设置没变、只缺内核 |
| `sudo` 卡 Password | 非交互终端无法输入密码 | 用 `osascript` 弹管理员授权，且必须本人输 |
| 开关灰显 | UI 点不动 | 命令行设置；多半是 service 坏了 |
| 只测一次国外站就下结论 | 偶发成功被当成稳定 | 每站连测两次 |
| 拿 `google.com` 当连通性探针 | 返回 429 被误判成断网 | 用 `gstatic/generate_204`；403/404/429 都算通 |
| 中文组名手打 API | URL 编码错，返回 404 | 走 `scripts/node-switch.sh` |
| 多代理工具冲突 | 端口反复被改 | 只保留 Clash Verge，移除 ClashX 自启动 |

## 5. 脚本清单

| 脚本 | 用途 | 是否改系统 |
|---|---|---|
| `scripts/diagnose.sh` | 只读六层诊断 | 否 |
| `scripts/fix-core-manual.sh` | 内核没起时手动拉起（场景 E 急救） | 只起进程，不动设置 |
| `scripts/node-switch.sh` | 代理组查看 / 测速 / 切换（场景 F） | 改当前选中节点 |
