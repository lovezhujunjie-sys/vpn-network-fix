#!/usr/bin/env bash
# 场景 F：内核正常但节点死了（国内通、国外时通时不通）。
# 通过 mihomo 的 Unix Socket API 查看代理组、测速、切换节点。
#
# 用法：
#   node-switch.sh list                    # 列出所有选择型代理组及当前节点
#   node-switch.sh delay                   # 测当前组内各节点延迟
#   node-switch.sh auto                    # 把当前组切到「自动选择」（URLTest 自动挑最快）
#   node-switch.sh set "🇺🇸美国圣何塞"       # 手动指定节点
#
# 环境变量：CLASH_DIR 可覆盖配置目录，CLASH_GROUP 可覆盖代理组名（默认 亏本机场）

set -u

clash_dir="${CLASH_DIR:-${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
config="${clash_dir}/clash-verge.yaml"
sock="/tmp/verge/verge-mihomo.sock"
group="${CLASH_GROUP:-亏本机场}"
test_url="https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"

if [[ ! -S "$sock" ]]; then
  printf 'ERROR: 找不到内核 socket %s —— 内核没在跑，先走场景 E（fix-core-manual.sh）\n' "$sock" >&2
  exit 2
fi
if [[ ! -f "$config" ]]; then
  printf 'ERROR: 找不到配置 %s\n' "$config" >&2
  exit 2
fi

secret=$(awk -F: '/^secret:/ {sub(/^secret:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit}' "$config")
api() { curl -s --unix-socket "$sock" -H "Authorization: Bearer ${secret}" "$@"; }
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

cmd="${1:-list}"

case "$cmd" in
  list)
    api "http://localhost/proxies" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin).get("proxies", {})
except Exception as e:
    print("解析失败:", e); sys.exit(1)
for k, v in d.items():
    if v.get("type") in ("Selector", "URLTest", "Fallback", "LoadBalance"):
        print("[%-9s] %-12s 当前: %s  (共 %d 个)" % (v["type"], k, v.get("now"), len(v.get("all", []))))
'
    ;;

  delay)
    printf '正在测速「%s」组内节点（最多 40 秒）...\n' "$group"
    api -m 40 "http://localhost/group/$(enc "$group")/delay?url=${test_url}&timeout=5000" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("解析失败:", e); sys.exit(1)
if "message" in d:
    print("测试失败:", d["message"]); sys.exit(1)
ok = sorted((v, k) for k, v in d.items() if isinstance(v, int) and v > 0)
bad = [k for k, v in d.items() if not (isinstance(v, int) and v > 0)]
print("✅ 可用 %d 个" % len(ok))
for v, k in ok:
    print("   %5dms  %s" % (v, k))
if bad:
    print("❌ 不可用 %d 个:" % len(bad))
    for k in bad:
        print("           %s" % k)
print()
print("判据：组内「当前选中」的节点如果不在上面可用列表里，就是它死了。")
'
    ;;

  auto)
    payload=$(python3 -c 'import json;print(json.dumps({"name":"自动选择"}))')
    code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --unix-socket "$sock" \
      -H "Authorization: Bearer ${secret}" -H "Content-Type: application/json" \
      -d "$payload" "http://localhost/proxies/$(enc "$group")")
    if [[ "$code" == "204" ]]; then
      sleep 1
      now=$(api "http://localhost/proxies/$(enc "$group")" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("now",""))' 2>/dev/null)
      printf '✅ 「%s」已切到「自动选择」，实际走: %s\n' "$group" "$now"
    else
      printf '❌ 切换失败（HTTP %s）\n' "$code" >&2
      exit 1
    fi
    ;;

  set)
    if [[ -z "${2:-}" ]]; then
      printf '用法: %s set "节点名"\n' "$0" >&2
      exit 2
    fi
    payload=$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$2")
    code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --unix-socket "$sock" \
      -H "Authorization: Bearer ${secret}" -H "Content-Type: application/json" \
      -d "$payload" "http://localhost/proxies/$(enc "$group")")
    if [[ "$code" == "204" ]]; then
      printf '✅ 「%s」已切到「%s」\n' "$group" "$2"
    else
      printf '❌ 切换失败（HTTP %s），检查节点名是否在组内\n' "$code" >&2
      exit 1
    fi
    ;;

  *)
    printf '用法: %s {list|delay|auto|set <节点名>}\n' "$0" >&2
    exit 2
    ;;
esac
