#!/usr/bin/env bash
# 流式模式（--stream）的验收测试。
#
# 这个模式存在的唯一理由是省掉每条命令一次起进程的开销，所以它必须满足两件事，
# 缺一件就等于没做：
#   1. 真流式：调用方写一条就能读到一条，不用等 EOF（否则就只是个批量模式）
#   2. 与单条模式逐字节等价：同一条命令，两种模式给出的报告必须一模一样
# 另外钉住帧的行为：空行也给一条带行号的拒绝对象（严格一行一答，绝不静默吞行），
# 坏行不破坏顺序，CRLF 与无尾随换行都能用。
BIN="${1:-_build/native/release/build/cmd/preshell/preshell.exe}"
CASES="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/corpus/bash-tests}"

bad=0
check() { # check <描述> <实际> <期望>
  if [ "$2" != "$3" ]; then
    printf '  失败: %s\n    实际: %s\n    期望: %s\n' "$1" "$2" "$3"
    bad=$((bad + 1))
  fi
}

# --- 1) 真流式：不关 stdin 也要能读到第一条 -------------------------------
# 用 coproc 手动喂一条再读，读不到就说明它在等 EOF。曾经就是这样：报告走
# println（块缓冲），一条几百字节填不满缓冲，于是「流式」变成了「批量」。
coproc PS { "$BIN" --stream 2>/dev/null; }
printf '"ls -la"\n' >&"${PS[1]}"
if ! IFS= read -r -t 5 -u "${PS[0]}" first; then
  echo "  失败: 写入一条后 5 秒内没有输出（在读 stdout 缓冲，或阻塞等 EOF）"
  bad=$((bad + 1))
  first=""
fi
printf '"rm -rf build"\n' >&"${PS[1]}"
if ! IFS= read -r -t 5 -u "${PS[0]}" second; then
  echo "  失败: 同一进程里的第二条命令没有回答"
  bad=$((bad + 1))
  second=""
fi
exec {PS[1]}>&-
wait "$PS_PID" 2>/dev/null
check "第一条是报告" "$(printf '%s' "$first" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).status)))' 2>/dev/null)" "Complete"
check "第二条是报告" "$(printf '%s' "$second" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).status)))' 2>/dev/null)" "Complete"

# --- 2) 逐字节等价：语料里每条命令，单条模式 vs 流式 ----------------------
# 语料是 bash 官方测试文件（GPL，出处见 tools/corpus/bash-tests/README.md），
# 每份都是一个多行脚本，正好覆盖含换行的命令。
node - "$BIN" "$CASES" <<'JS'
const { execFileSync } = require("node:child_process");
const { readFileSync, readdirSync } = require("node:fs");
const [bin, dir] = process.argv.slice(2);
const files = readdirSync(dir).filter(f => f.endsWith(".sub")).sort()
  .map(f => readFileSync(`${dir}/${f}`));
// 语料之外的边角：空命令、NUL、CRLF、非 ASCII 路径、heredoc、多行循环
const extra = ["", "ls -la", "rm -rf build && tar czf out.tgz src",
  "cat <<EOF\nhi\nEOF\n", "for f in x; do echo $f; done",
  "true\u0000; rm -rf /tmp/x", "echo 你好 > /tmp/文"];
const cases = extra.map(s => Buffer.from(s, "utf8")).concat(files);
const payload = Buffer.from(cases.map(c => JSON.stringify(c.toString("utf8")) + "\n").join(""), "utf8");
const out = execFileSync(bin, ["--stream"], { input: payload, maxBuffer: 1 << 30 })
  .toString("utf8").split("\n").filter(l => l !== "");
let bad = 0;
if (out.length !== cases.length) {
  console.log(`  失败: 输入 ${cases.length} 条，输出 ${out.length} 行（必须一行一答）`);
  bad++;
}
let mismatched = 0;
for (let i = 0; i < cases.length; i++) {
  const one = execFileSync(bin, [], { input: cases[i], maxBuffer: 1 << 26 }).toString("utf8").trim();
  if (out[i] !== one) {
    if (mismatched < 4) console.log(`  失败: 第 ${i + 1} 条两种模式不一致\n    单条: ${one.slice(0, 120)}\n    流式: ${(out[i] || "(缺行)").slice(0, 120)}`);
    mismatched++;
  }
}
console.log(`  裸字符串：${cases.length} 条命令，逐字节不一致 ${mismatched} 条`);

// 同一条命令带 id 再走一遍：信封里的报告必须与单条模式是同一个对象。
// 信封是为了让报告本身一字不变——id 要是塞进报告里，两种模式对同一条命令
// 就不再一致了。
const taggedPayload = Buffer.from(cases.map((c, i) => JSON.stringify({ id: i, command: c.toString("utf8") }) + "\n").join(""), "utf8");
const taggedOut = execFileSync(bin, ["--stream"], { input: taggedPayload, maxBuffer: 1 << 30 })
  .toString("utf8").split("\n").filter(l => l !== "");
let envBad = 0;
if (taggedOut.length !== cases.length) {
  console.log(`  失败: 带 id 时输入 ${cases.length} 条，输出 ${taggedOut.length} 行`);
  envBad++;
}
for (let i = 0; i < cases.length; i++) {
  const env = JSON.parse(taggedOut[i]);
  const one = JSON.parse(execFileSync(bin, [], { input: cases[i], maxBuffer: 1 << 26 }).toString("utf8"));
  if (env.id !== i) {
    if (envBad < 4) console.log(`  失败: 第 ${i + 1} 条的 id 没回来（拿到 ${JSON.stringify(env.id)}）`);
    envBad++;
    continue;
  }
  if (JSON.stringify(env.report) !== JSON.stringify(one)) {
    if (envBad < 4) console.log(`  失败: 第 ${i + 1} 条信封里的报告与单条模式不同`);
    envBad++;
  }
}
console.log(`  带 id 信封：${cases.length} 条命令，id 或报告不对 ${envBad} 条`);

// id 形态本身的规矩：回显、拒绝要带回可读的 id、未知键要拒绝、裸字符串不受影响
const shape = [
  ['{"id":17,"command":"ls"}', r => r.id === 17 && r.report && r.report.status === "Complete"],
  ['{"id":"w1","command":"ls"}', r => r.id === "w1" && r.report && r.report.status === "Complete"],
  ['{"command":"ls"}', r => r.version === 1 && !("id" in r)],
  ['"ls"', r => r.version === 1 && !("id" in r)],
  ['{"id":"w2","command":5}', r => r.id === "w2" && typeof r.error === "string"],
  ['{"id":"w3","command":"ls","timeout":5}', r => r.id === "w3" && /timeout/.test(r.error)],
  ['{"id":0,"command":"ls"}', r => r.id === 0 && !!r.report],
];
let shapeBad = 0;
for (const [line, ok] of shape) {
  const got = JSON.parse(execFileSync(bin, ["--stream"], { input: Buffer.from(line + "\n"), maxBuffer: 1 << 26 })
    .toString("utf8").trim());
  // 信封与裸报告都要能被判定：先看规则是否满足
  if (!ok(got)) {
    console.log(`  失败: ${line} 的应答不符合约定：${JSON.stringify(got).slice(0, 100)}`);
    shapeBad++;
  }
}
console.log(`  形态约定：${shape.length} 条，不符 ${shapeBad} 条`);

const total = mismatched + envBad + shapeBad;
process.exit(total === 0 ? 0 : 1);
JS
[ $? -eq 0 ] || bad=$((bad + 1))

# --- 3) 帧：严格一行一答，坏行不破坏顺序 ----------------------------------
out=$(printf '"ls"\n\n{"a":1}\n"echo hi"\n' | "$BIN" --stream 2>/dev/null)
# 注意 $(...) 会吃掉末尾换行：直接对它 wc -l 会少算一行，必须补回来
check "四行输入（含空行与坏行）出四行" "$(printf '%s\n' "$out" | wc -l)" "4"
check "空行被明确拒绝且带行号" "$(printf '%s\n' "$out" | sed -n '2p' | grep -c '"line":2')" "1"
check "坏行拒绝且带行号" "$(printf '%s\n' "$out" | sed -n '3p' | grep -c '"line":3')" "1"
check "坏行之后的报告仍在原位" "$(printf '%s\n' "$out" | sed -n '4p' | grep -c '"target":"echo"')" "1"
# 拒绝对象里不许出现报告字段，否则调用方会把「你第 3 行不是 JSON」读成「这条命令有问题」
check "拒绝对象不带 version" "$(printf '%s\n' "$out" | sed -n '2p' | grep -c '"version"')" "0"
check "拒绝对象不带 status" "$(printf '%s\n' "$out" | sed -n '2p' | grep -c '"status"')" "0"

# --- 4) CRLF 与无尾随换行 -------------------------------------------------
check "CRLF 输入" "$(printf '"ls"\r\n"pwd"\r\n' | "$BIN" --stream 2>/dev/null | wc -l)" "2"
check "最后一行没有换行也算一条" "$(printf '"ls"' | "$BIN" --stream 2>/dev/null | wc -l)" "1"

# --- 5) 退出码与 stdout 纯净 ---------------------------------------------
# 基准警告必须逐行出现：流式里每条报告都要能独立交给下游，不能只在开头说一次。
total_note=$(printf '"rm -rf x"\n' | "$BIN" --stream 2>/dev/null | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const d = JSON.parse(s.trim().split("\n")[0])
  const notes = (d.issues || []).filter(i => (i.message || "").indexOf("no --cwd given") === 0)
  console.log((notes.length === 1 && d.impact.uncertain === true) ? "ok" : "bad")
})')
check "无 --cwd 时每条报告都带基准警告" "$total_note" "ok"

printf '"ls"\n{oops}\n' | "$BIN" --stream >/tmp/stream_out.txt 2>/tmp/stream_err.txt
check "有坏行时退出码仍为 0" "$?" "0"
check "stdout 每行都是合法 JSON" "$(node -e 'const fs=require("fs");const ls=fs.readFileSync("/tmp/stream_out.txt","utf8").split("\n").filter(Boolean);let bad=0;for(const l of ls){try{JSON.parse(l)}catch(e){bad++}}process.stdout.write(String(bad))')" "0"
check "汇总在 stderr 上" "$(grep -c "reports" /tmp/stream_err.txt)" "1"

# --- 6) 组合用法必须被拒（否则 stdout 就不是能逐行解析的东西了） ----------
for combo in "--stream --pretty" "--stream --scan" "--stream --shadow"; do
  printf '' | $BIN $combo >/dev/null 2>&1
  check "$combo 退出码为 2" "$?" "2"
done
$BIN --stream 'ls' >/dev/null 2>&1
check "--stream 带命令参数退出码为 2" "$?" "2"

echo "--- 异常 $bad 处"
[ "$bad" = "0" ]
#
# 用法：tools/probe/stream.sh [二进制路径] [语料目录]
#   二进制默认 _build/native/release/build/cmd/preshell/preshell.exe
#   语料默认 tools/corpus/bash-tests
#
# 为什么要有这个文件：--stream 的价值是「不等进程」，它的风险是「两种模式对同一条
# 命令给出不同答案」。lib/stream_test.mbt 测帧本身（跨块断行、超长行、EOF），
# 这里测的是把它们接起来之后的 CLI 行为，以及两种模式的一致性。
