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
# 开发模式也要能在 stdin 上工作。--shadow 曾经因为读的是空字符串而打印空树，
# 这类故障不会崩、不会报错，只是什么都没输出。
total=$((total + 2))
if ! printf %s\\n "echo hi" | "$BIN" --shadow 2>/dev/null | grep -q '"parts"'; then
  echo "  --shadow 在 stdin 上没有产出语法树"
  bad=$((bad + 1))
fi
if ! printf %s\\n "echo hi" | "$BIN" --scan 2>/dev/null | grep -q '^status='; then
  echo "  --scan 在 stdin 上没有产出状态行"
  bad=$((bad + 1))
fi

# 契约的自证形式：--spec 必须仍是合法 JSON，且关键字段齐全。
# 它与 --help、man 页是三份说同一件事的副本，缺字段意味着有人只改了其中一份。
total=$((total + 1))
spec_json=$("$BIN" --spec 2>/dev/null)
if ! printf '%s' "$spec_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let d; try { d = JSON.parse(s) } catch (e) { console.log("不是合法 JSON"); process.exit(1) }
  const need = ["tool","version","schema","doc","modes","exit_codes","refusal","client_obligations","how_to_read"];
  const missing = need.filter(k => !(k in d));
  if (missing.length) { console.log("缺字段: " + missing.join(",")); process.exit(1) }
  const modes = (d.modes || []).map(m => m.name).join(",");
  if (!modes.includes("single") || !modes.includes("stream")) { console.log("modes 不含 single/stream"); process.exit(1) }
  if ((d.client_obligations || []).length !== 4) { console.log("调用方义务不是 4 条"); process.exit(1) }
})'; then
  echo "  --spec 输出不合格: $spec_json" | head -2
  bad=$((bad + 1))
fi

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
