#!/usr/bin/env bash

set -u

network_service="${1:-Wi-Fi}"
clash_config="${2:-${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml}"

if [[ ! -f "$clash_config" ]]; then
  printf 'ERROR: Clash Verge config not found: %s\n' "$clash_config" >&2
  exit 2
fi

proxy_port=$(awk -F: '/^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$clash_config")
if [[ ! "$proxy_port" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: no numeric mixed-port found in %s\n' "$clash_config" >&2
  exit 2
fi

web_proxy=$(networksetup -getwebproxy "$network_service" 2>&1)
secure_proxy=$(networksetup -getsecurewebproxy "$network_service" 2>&1)
web_enabled=$(printf '%s\n' "$web_proxy" | awk '/^Enabled:/ {print $2; exit}')
secure_enabled=$(printf '%s\n' "$secure_proxy" | awk '/^Enabled:/ {print $2; exit}')
web_port=$(printf '%s\n' "$web_proxy" | awk '/^Port:/ {print $2; exit}')
secure_port=$(printf '%s\n' "$secure_proxy" | awk '/^Port:/ {print $2; exit}')

listener_output=$(netstat -anv -p tcp 2>/dev/null | grep -E "[.:]${proxy_port}[[:space:]].*LISTEN" || true)
process_output=$(pgrep -fal 'verge-mihomo|Clash Verge|clash-verge' || true)

direct_code=$(curl --noproxy '*' -L -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 5 --max-time 12 https://www.baidu.com 2>/dev/null || true)
proxy_code=$(curl -L -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 8 --max-time 15 -x "http://127.0.0.1:${proxy_port}" \
  https://www.google.com 2>/dev/null || true)

system_proxy_ok=No
listener_ok=No
direct_ok=No
proxy_ok=No

if [[ "$web_enabled" == "Yes" && "$secure_enabled" == "Yes" && \
      "$web_port" == "$proxy_port" && "$secure_port" == "$proxy_port" ]]; then
  system_proxy_ok=Yes
fi
if [[ -n "$listener_output" ]]; then
  listener_ok=Yes
fi
if [[ "$direct_code" =~ ^[23][0-9][0-9]$ ]]; then
  direct_ok=Yes
fi
if [[ "$proxy_code" =~ ^[23][0-9][0-9]$ ]]; then
  proxy_ok=Yes
fi

printf 'Clash config: %s\n' "$clash_config"
printf 'Configured mixed-port: %s\n\n' "$proxy_port"
printf '[HTTP system proxy]\n%s\n\n' "$web_proxy"
printf '[HTTPS system proxy]\n%s\n\n' "$secure_proxy"
printf '[TCP listener]\n%s\n\n' "${listener_output:-None}"
printf '[Clash processes]\n%s\n\n' "${process_output:-None}"
printf '[Traffic checks]\n'
printf 'Direct Baidu (--noproxy): HTTP %s\n' "${direct_code:-000}"
printf 'Google via 127.0.0.1:%s: HTTP %s\n\n' "$proxy_port" "${proxy_code:-000}"
printf '[Summary]\n'
printf 'System proxy matches config: %s\n' "$system_proxy_ok"
printf 'mihomo listener present: %s\n' "$listener_ok"
printf 'Direct Internet reachable: %s\n' "$direct_ok"
printf 'Explicit proxy reachable: %s\n' "$proxy_ok"

if [[ "$system_proxy_ok" == Yes && "$listener_ok" == Yes && \
      "$direct_ok" == Yes && "$proxy_ok" == Yes ]]; then
  exit 0
fi
exit 1
