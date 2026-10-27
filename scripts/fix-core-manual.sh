#!/usr/bin/env bash
# 场景 E 急救：Clash Verge 的 helper service 坏了、内核根本没起来时，
# 直接用内核二进制把 mihomo 拉起来。
#
# 特点：不碰任何设置文件、不碰系统代理。系统代理本来就指向 mixed-port，
#       只缺一个来接的进程；把内核补回去就等于"回到原状"。
# 局限：这是临时内核，重启电脑即失效，GUI 也不认它。恢复上网后应尽快修 service。

set -u

clash_dir="${1:-${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
config="${clash_dir}/clash-verge.yaml"
core="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
log="/tmp/verge-manual.log"

# 1. 已经在内核就不重复起（避免端口冲突）
running=$(pgrep -f "MacOS/verge-mihomo" 2>/dev/null | tr '\n' ' ')
if [[ -n "${running// /}" ]]; then
  printf '内核已经在跑（PID %s），不重复启动。\n' "$running"
  exit 0
fi

# 2. 前置检查
if [[ ! -x "$core" ]]; then
  printf 'ERROR: 找不到内核或不可执行：%s\n' "$core" >&2
  exit 2
fi
if [[ ! -f "$config" ]]; then
  printf 'ERROR: 找不到运行时配置：%s\n' "$config" >&2
  exit 2
fi

port=$(awk -F: '/^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$config")
if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: 从 %s 读不到数字型 mixed-port\n' "$config" >&2
  exit 2
fi

# 3. 端口已被别人占住就别抢
if netstat -anv -p tcp 2>/dev/null | grep -qE "[.:]${port}[[:space:]].*LISTEN"; then
  printf '端口 %s 已有监听，不启动内核。先排查是谁在占用。\n' "$port"
  exit 0
fi

# 4. 拉起内核
mkdir -p /tmp/verge
nohup "$core" -d "$clash_dir" -f "$config" > "$log" 2>&1 &
pid=$!
printf '已拉起内核 PID=%s，等待监听 %s ...\n' "$pid" "$port"

for _ in $(seq 1 10); do
  if netstat -anv -p tcp 2>/dev/null | grep -qE "[.:]${port}[[:space:]].*LISTEN"; then
    printf '✅ 内核已监听 127.0.0.1:%s\n' "$port"
    printf '   内核日志：%s\n' "$log"
    printf '   验证：curl -s -m 10 -x http://127.0.0.1:%s https://www.google.com -o /dev/null -w "%%{http_code}\\n"\n' "$port"
    printf '   ⚠️ 临时内核，重启电脑即失效；请尽快在 Clash Verge 里重装服务（会弹管理员密码框）\n'
    exit 0
  fi
  sleep 1
done

printf '❌ 10 秒内没监听上端口，看日志末 20 行：\n' >&2
tail -20 "$log" >&2
printf '   启动初期出现 context canceled / operation was canceled 属正常噪音，不必当故障。\n' >&2
exit 1
