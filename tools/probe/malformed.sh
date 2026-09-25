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
# 路径基准的契约：不给 --cwd 时用本进程当前目录推演，并且必须留下警告；
# 给了基准就以它为准，且不该再出现那条警告。绝对路径是硬要求，没有相对回退。
total=$((total + 3))
no_cwd=$("$BIN" <<<"rm -rf x" 2>/dev/null)
if ! printf '%s' "$no_cwd" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let d; try { d = JSON.parse(s) } catch (e) { console.log("不是合法 JSON"); process.exit(1) }
  const notes = (d.issues || []).filter(i => i.kind === "Note" && (i.message || "").indexOf("no --cwd given") === 0);
  if (notes.length !== 1) { console.log("缺 --cwd 时没有恰好一条基准警告，实际 " + notes.length); process.exit(1) }
  if (d.impact.uncertain !== true) { console.log("推演基准时没有置 uncertain"); process.exit(1) }
  const del = (d.impact.effects || []).filter(e => e.kind === "Delete");
  if (del.length !== 1 || !del[0].target.startsWith("/")) { console.log("推演的基准没有给出绝对路径: " + JSON.stringify(del)); process.exit(1) }
  if (!d.impact.cwd || !d.impact.cwd.startsWith("/")) { console.log("cwd 不是绝对路径: " + String(d.impact.cwd)); process.exit(1) }
})'; then
  echo "  未给 --cwd 时的回退行为不合格"
  bad=$((bad + 1))
fi

with_cwd=$(printf '%s' 'rm -rf x' | "$BIN" --cwd=/tmp/base 2>/dev/null)
if ! printf '%s' "$with_cwd" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let d; try { d = JSON.parse(s) } catch (e) { console.log("不是合法 JSON"); process.exit(1) }
  const notes = (d.issues || []).filter(i => (i.message || "").indexOf("no --cwd given") === 0);
  if (notes.length !== 0) { console.log("给了 --cwd 仍出现基准警告"); process.exit(1) }
  if (d.impact.cwd !== "/tmp/base") { console.log("cwd 不是给定基准: " + String(d.impact.cwd)); process.exit(1) }
  const del = (d.impact.effects || []).filter(e => e.kind === "Delete");
  if (del.length !== 1 || del[0].target !== "/tmp/base/x") { console.log("相对路径没有对着基准解析: " + JSON.stringify(del)); process.exit(1) }
})'; then
  echo "  给定 --cwd 时的解析不合格"
  bad=$((bad + 1))
fi

printf '%s' 'rm -rf x' | "$BIN" --cwd=relative/base >/dev/null 2>&1
[ "$?" = "2" ] || { echo "  相对 --cwd 的退出码不是 2"; bad=$((bad + 1)); }

# 词首是运行时展开时不能拼基准：`$HOME/x` 的展开值本身可能是绝对路径。
# 变量提取：调用方靠这个名字去查环境，抽错等于让它替换错东西。
total=$((total + 2))
if ! printf '%s' 'rm -rf "$HOME/a" "$HOME/b" $DIR/c' | "$BIN" --cwd=/base 2>/dev/null | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let d; try { d = JSON.parse(s) } catch (e) { console.log("不是合法 JSON"); process.exit(1) }
  const want = JSON.stringify(["HOME", "DIR"]);
  if (JSON.stringify(d.impact.vars) !== want) { console.log("impact.vars 不对: " + JSON.stringify(d.impact.vars)); process.exit(1) }
  const del = (d.impact.effects || []).filter(e => e.kind === "Delete");
  if (del.length !== 3 || JSON.stringify(del[0].vars) !== JSON.stringify(["HOME"])) { console.log("路径效果没带自己的 vars"); process.exit(1) }
  const plain = (d.impact.effects || []).filter(e => e.kind === "Exec");
  if (plain.some(e => (e.vars || []).length !== 0)) { console.log("静态命令名不该有 vars"); process.exit(1) }
})'; then
  echo "  路径变量提取不合格"
  bad=$((bad + 1))
fi
if ! printf '%s' 'rm -rf ~+ /tmp/x' | "$BIN" --cwd=/base 2>/dev/null | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const d = JSON.parse(s)
  if (JSON.stringify(d.impact.vars) !== JSON.stringify(["PWD"])) { console.log("~+ 没有映射到 PWD: " + JSON.stringify(d.impact.vars)); process.exit(1) }
})'; then
  echo "  波浪号到变量的映射不合格"
  bad=$((bad + 1))
fi

# 波浪号不只出现在词首：重定向目标与赋值形参数（`of=~/x`）里它也展开，
# 那时把当前目录拼上去就是一条错的事实（实测 bash 会展开成 $HOME/x）。
total=$((total + 2))
for cmd in 'echo hi >~/x' 'dd of=~/b.img'; do
  if ! printf '%s' "$cmd" | "$BIN" --cwd=/base 2>/dev/null | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const d = JSON.parse(s)
  const path = (d.impact.effects || []).find(e => e.kind === "Write");
  if (!path) { console.log("没有写路径"); process.exit(1) }
  if (path.target.indexOf("/base") === 0) { console.log("把基准拼到了展开的路径上: " + path.target); process.exit(1) }
  if (JSON.stringify(path.vars) !== JSON.stringify(["HOME"])) { console.log("没有报出 HOME: " + JSON.stringify(path.vars)); process.exit(1) }
  if (d.impact.uncertain !== true) { console.log("没有置 uncertain"); process.exit(1) }
})'; then
    echo "  $cmd 的波浪号处理不合格"
    bad=$((bad + 1))
  fi
done

# 同一条路径在不同效果里说同样的话：命令名是洞时 Exec 也报名字，操作数是洞时
# 与它并列的 Unknown 报同一份名字。调用方按其中任何一条去找值都该得到答案。
total=$((total + 1))
if ! printf '%s' '$LAUNCHER --version && rm -rf $A/x' | "$BIN" --cwd=/base 2>/dev/null | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const d = JSON.parse(s)
  const pick = k => (d.impact.effects || []).filter(e => e.kind === k);
  const exec = pick("Exec")[0];
  if (JSON.stringify(exec.vars) !== JSON.stringify(["LAUNCHER"])) { console.log("命令名是洞时 Exec 没报名字"); process.exit(1) }
  const del = pick("Delete")[0], unk = pick("Unknown")[0];
  if (JSON.stringify(del.vars) !== JSON.stringify(["A"]) || JSON.stringify(unk.vars) !== JSON.stringify(["A"])) { console.log("同一条路径的 Delete 与 Unknown 报的变量不一致"); process.exit(1) }
  if (JSON.stringify(d.impact.vars) !== JSON.stringify(["LAUNCHER", "A"])) { console.log("并集不对: " + JSON.stringify(d.impact.vars)); process.exit(1) }
})'; then
  echo "同一条路径的变量报得不一致"
  bad=$((bad + 1))
fi

total=$((total + 2))
for expr in '$HOME/x' '~/x'; do
  if ! printf '%s' "rm -rf $expr" | "$BIN" --cwd=/base 2>/dev/null | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let d; try { d = JSON.parse(s) } catch (e) { console.log("不是合法 JSON"); process.exit(1) }
  const del = (d.impact.effects || []).filter(e => e.kind === "Delete");
  if (del.length !== 1) { console.log("没有一条 Delete"); process.exit(1) }
  if (del[0].target.indexOf("/base") === 0) { console.log("头部未解析却拼了基准: " + del[0].target); process.exit(1) }
  if (del[0].dynamic !== true) { console.log("没有标成非封闭集合"); process.exit(1) }
  if (d.impact.uncertain !== true) { console.log("没有置 uncertain"); process.exit(1) }
})'; then
    echo "  词首未解析的路径处理不合格（$expr）"
    bad=$((bad + 1))
  fi
done


total=$((total + 2))
if ! "$BIN" --man 2>/dev/null | grep -q '^PreShell$'; then
  echo "  --man 没有输出纯文本手册"
  bad=$((bad + 1))
fi
if ! "$BIN" --man-markdown 2>/dev/null | grep -q '^# PreShell$'; then
  echo "  --man-markdown 没有输出 Markdown 手册"
  bad=$((bad + 1))
fi

if ! printf '%s' "$spec_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let d; try { d = JSON.parse(s) } catch (e) { console.log("不是合法 JSON"); process.exit(1) }
  const need = ["tool","version","schema","doc","modes","exit_codes","refusal","client_obligations","how_to_read","paths"];
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
