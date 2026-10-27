#!/usr/bin/env bash
# 只读六层诊断：内核 → 配置端口 → 监听 → 系统代理 → 真实流量 → 节点。
# 不修改任何设置。

set -u

network_service="${1:-Wi-Fi}"
clash_dir="${2:-${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
clash_config="${clash_dir}/clash-verge.yaml"
verge_config="${clash_dir}/verge.yaml"
log_file="${clash_dir}/logs/latest.log"

if [[ ! -f "$clash_config" ]]; then
  printf 'ERROR: Clash Verge config not found: %s\n' "$clash_config" >&2
  exit 2
fi

proxy_port=$(awk -F: '/^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$clash_config")
if [[ ! "$proxy_port" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: no numeric mixed-port found in %s\n' "$clash_config" >&2
  exit 2
fi

# ── 第 0 层：内核与 GUI 必须分开确认 ─────────────────────────────
core_pids=$(pgrep -f "MacOS/verge-mihomo" 2>/dev/null | tr '\n' ' ')
gui_pids=$(pgrep -f "MacOS/clash-verge$" 2>/dev/null | tr '\n' ' ')
service_pid=$(pgrep -f "clash-verge-service" 2>/dev/null | tr '\n' ' ')

# ── 第 1~2 层：配置端口与监听 ─────────────────────────────────
web_proxy=$(networksetup -getwebproxy "$network_service" 2>&1)
secure_proxy=$(networksetup -getsecurewebproxy "$network_service" 2>&1)
web_enabled=$(printf '%s\n' "$web_proxy" | awk '/^Enabled:/ {print $2; exit}')
secure_enabled=$(printf '%s\n' "$secure_proxy" | awk '/^Enabled:/ {print $2; exit}')
web_port=$(printf '%s\n' "$web_proxy" | awk '/^Port:/ {print $2; exit}')
secure_port=$(printf '%s\n' "$secure_proxy" | awk '/^Port:/ {print $2; exit}')

listener_output=$(netstat -anv -p tcp 2>/dev/null | grep -E "[.:]${proxy_port}[[:space:]].*LISTEN" || true)

# ── 第 3 层：真实流量 ────────────────────────────────────────
direct_code=$(curl --noproxy '*' -L -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 5 --max-time 12 https://www.baidu.com 2>/dev/null || true)
# 用 generate_204 做代理连通性检测：它只会返回 204，不受具体站点限流/风控影响。
# 2026-10-27 教训：拿 google.com 当探针会返回 429，把"链路通但被限流"误判成断网。
proxy_code=$(curl -L -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 8 --max-time 15 -x "http://127.0.0.1:${proxy_port}" \
  https://www.gstatic.com/generate_204 2>/dev/null || true)

core_ok=No; gui_ok=No
system_proxy_ok=No; listener_ok=No; direct_ok=No; proxy_ok=No
[[ -n "${core_pids// /}" ]] && core_ok=Yes
[[ -n "${gui_pids// /}" ]] && gui_ok=Yes
if [[ "$web_enabled" == "Yes" && "$secure_enabled" == "Yes" && \
      "$web_port" == "$proxy_port" && "$secure_port" == "$proxy_port" ]]; then
  system_proxy_ok=Yes
fi
[[ -n "$listener_output" ]] && listener_ok=Yes
[[ "$direct_code" =~ ^[23][0-9][0-9]$ ]] && direct_ok=Yes
# 收到 429/403 也说明 TCP+TLS+HTTP 全通，只是被限流/风控；只有 000 才是真断。
if [[ "$proxy_code" =~ ^[23][0-9][0-9]$ || "$proxy_code" == "429" || "$proxy_code" == "403" ]]; then
  proxy_ok=Yes
fi

# ── 输出 ───────────────────────────────────────────────────
printf 'Clash config: %s\n' "$clash_config"
printf 'Configured mixed-port: %s\n\n' "$proxy_port"

printf '[0. 内核进程]  ← GUI 在 ≠ 内核在\n'
printf 'verge-mihomo (内核): %s\n' "${core_pids:-❌ 没跑}"
printf 'clash-verge  (GUI) : %s\n' "${gui_pids:-未运行}"
printf 'clash-verge-service: %s\n\n' "${service_pid:-未运行}"

printf '[1. HTTP system proxy]\n%s\n\n' "$web_proxy"
printf '[2. HTTPS system proxy]\n%s\n\n' "$secure_proxy"
printf '[3. TCP listener]\n%s\n\n' "${listener_output:-None}"
printf '[4. Traffic checks]\n'
printf 'Direct Baidu (--noproxy): HTTP %s\n' "${direct_code:-000}"
printf 'Proxy probe (gstatic/generate_204) via 127.0.0.1:%s: HTTP %s\n' "$proxy_port" "${proxy_code:-000}"
printf '  (204=通；429/403=链路通但被限流/风控；000=真断)\n\n'

# ── 定向提示 ────────────────────────────────────────────────
if [[ "$core_ok" == No && "$direct_ok" == Yes ]]; then
  printf '[⚠️ 诊断：内层断网]\n'
  printf '系统代理指向 127.0.0.1:%s，但内核没在跑，流量进了黑洞。\n' "$proxy_port"
  printf '下一步：bash scripts/fix-core-manual.sh   # 场景 E 急救\n'
  if [[ -f "$log_file" ]] && grep -q "failed to install service" "$log_file" 2>/dev/null; then
    printf '日志中发现 failed to install service —— helper service 重装失败（多半是管理员授权被取消）。\n'
    printf '永久修复必须弹管理员密码框由本人输入。\n'
  fi
  printf '\n'
fi

if [[ "$core_ok" == Yes && "$proxy_ok" == Yes && "$listener_ok" == Yes ]]; then
  if [[ "$system_proxy_ok" == No ]]; then
    printf '[⚠️ 诊断：只差系统代理]\n'
    printf '内核正常、代理可用，只是系统代理与配置不一致。走场景 A，只修系统代理。\n\n'
  fi
fi

if [[ "$core_ok" == Yes && "$proxy_ok" == Yes && "$direct_ok" == Yes ]]; then
  if [[ -f "$verge_config" ]]; then
    ui_flag=$(awk -F: '/^enable_system_proxy:/ {gsub(/[ \t]/, "", $2); print $2; exit}' "$verge_config")
    if [[ "$ui_flag" == "false" && "$system_proxy_ok" == Yes ]]; then
      printf '[ℹ️ 记账不一致]\n'
      printf 'verge.yaml 记 enable_system_proxy=false，但系统代理实际开着。\n'
      printf '正常现象，勿据此判断；只认 scutil --proxy。\n\n'
    fi
  fi
fi

printf '[Summary]\n'
printf 'Core (verge-mihomo) running : %s\n' "$core_ok"
printf 'GUI (clash-verge) running   : %s\n' "$gui_ok"
printf 'System proxy matches config : %s\n' "$system_proxy_ok"
printf 'mihomo listener present     : %s\n' "$listener_ok"
printf 'Direct Internet reachable   : %s\n' "$direct_ok"
printf 'Explicit proxy reachable    : %s\n' "$proxy_ok"
printf '\n注：国外站只测一次不算数，修复后每站连测两次。\n'

if [[ "$core_ok" == Yes && "$system_proxy_ok" == Yes && "$listener_ok" == Yes && \
      "$direct_ok" == Yes && "$proxy_ok" == Yes ]]; then
  exit 0
fi
exit 1
