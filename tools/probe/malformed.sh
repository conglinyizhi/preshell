#!/usr/bin/env bash
# 畸形输入冒烟测试：每一个都必须是「产出 JSON 并 exit 0」，不许崩溃（信号）、不许挂死、不许污染 stdout。
BIN="${1:-_build/native/release/build/cmd/preshell/preshell.exe}"
CASES="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases.txt}"
bad=0
total=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  total=$((total + 1))
  out=$(printf '%s' "$line" | timeout 10 "$BIN" 2>/tmp/probe_err.txt)
  code=$?
  note=""
  if [ $code -ge 128 ]; then
    note="崩溃(signal $((code - 128)))"
  elif [ $code -eq 124 ]; then
    note="挂死"
  elif [ $code -ne 0 ]; then
    note="非零退出 $code"
  elif ! echo "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{JSON.parse(s)}catch(e){process.exit(1)}})'; then
    note="stdout 不是合法 JSON"
  fi
  if [ -n "$note" ]; then
    bad=$((bad + 1))
    printf '%-8s %q\n' "$note" "$line"
  fi
done < "$CASES"
echo "--- 共 $total 条，异常 $bad 条"
[ "$bad" = "0" ]
#
# 用法：tools/probe/malformed.sh [二进制路径] [用例文件]
#   二进制默认 _build/native/release/build/cmd/preshell/preshell.exe
#   用例默认同目录的 cases.txt（每行一条）
#
# 为什么单独放在这里：这是 CLI 层面的冒烟测试，测的是「进程不许崩」。
# MoonBit 的 lib/robustness_test.mbt 覆盖同类的库内行为，但那个测不到
# CLI 自己的路径（stdin 读取、参数解析、输出）。
