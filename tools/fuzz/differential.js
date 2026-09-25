#!/usr/bin/env node
// 差分模糊：拿真 shell 当 oracle，检查两个方向的判定偏差。
//
// 与 mutate.js 的分工：那个只问「工具会不会死」（崩溃、挂死、输出不是 JSON）。
// 这个问「判定对不对」，因为有真 shell 在旁边做裁判，所以能给出比随机字节变异
// 强得多的证据。两条不变量：
//
//   1. shell 接受、我们拒绝 → 我们的缺口（少报，看得见的失败）
//   2. shell 拒绝、我们报 Complete → 我们太宽松（**危险方向**：调用方会把它
//      读成「这条命令没问题」）
//
// 种子是一份「构造动物园」：已经支持的各种写法各来一条。变异是结构性的
// （插一个构造、包一层 if、截断、拼接），所以变异体大多停在合法语法的近邻，
// 命中率比纯随机字节高得多。
//
// 注意：oracle 本身有已知噪声（zsh -n 会做部分求值、受限环境里进程替换会失败、
// bash -n 需要 shopt -s extglob）。所以每条失败都连 oracle 的原文一起打印，
// 由人判断，不当成自动结论。
//
// 用法：
//   node tools/fuzz/differential.js [选项]
//     --shell bash|zsh    方言（默认 bash）
//     --n <count>         轮数（默认 2000）
//     --seed <int>        随机种子（默认取时间，打印出来便于复现）
//     --out <dir>         失败样本落盘目录（默认 /tmp/preshell-diff）
//     --bin <path>        被测二进制
//     --timeout <ms>      单次超时（默认 5000）

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function arg(name, dflt) {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

const root = path.resolve(__dirname, "../..");
const bin = arg("bin", path.join(root, "_build/native/release/build/cmd/preshell/preshell.exe"));
const shell = arg("shell", "bash");
const n = parseInt(arg("n", "2000"), 10);
const timeout = parseInt(arg("timeout", "5000"), 10);
const outDir = arg("out", "/tmp/preshell-diff");
const seed = parseInt(arg("seed", String(Date.now() % 100000)), 10);
const dialectFlag = shell === "zsh" ? "--shell=zsh" : "--shell=bash";

// 确定性随机：同 seed 必得同序列。
let state = seed >>> 0 || 1;
function rnd() {
  state ^= state << 13;
  state ^= state >>> 17;
  state ^= state << 5;
  state >>>= 0;
  return state / 0x100000000;
}
function pick(xs) {
  return xs[Math.floor(rnd() * xs.length)];
}

// 构造动物园：都是我们已经支持、且 shell 也接受的写法。变异在它们附近展开。
const ZOO = [
  "echo hi",
  "echo a > out.txt",
  "cat < in.txt",
  "echo a >> log.txt 2>&1",
  "echo a >&2",
  "x=$(date); echo $x",
  "x=`date`; echo $x",
  "for i in a b; do echo $i; done",
  "for i in a b; do echo $i; done > /tmp/o",
  "while read -r line; do echo $line; done < in.txt",
  "if [[ -f x ]]; then echo y; fi",
  "if [[ \"$x\" == a ]] then :; fi",
  "case $x in a) echo one;; b|c) echo two;;& *) echo other;; esac",
  "f() { echo body; }",
  "function g { echo body; }",
  "f () { echo spaced; }",
  "{ echo a; } always { echo b; }",
  "() { echo anon; } arg",
  "(cd /tmp && rm -f x)",
  "{ echo a; } 2>/dev/null",
  "echo ${x:-default}",
  "echo ${a//b/c}",
  "echo \"${a//b/X{Y}/Z}\"",
  "echo ${#x}",
  "arr=(1 2 3); echo ${arr[1]}",
  "arr+=(4); echo ${arr[2]}",
  "(( i = 1 + 2 ))",
  "(( a + (b > c) ))",
  "echo $((1 + 2))",
  "echo [[:alpha:]]",
  "find . -name '*.tmp' -delete",
  "git status && git diff --stat",
  "tar xzf pkg.tar.gz -C /tmp",
  "make -C sub",
  "sqlite3 t.db 'select 1'",
  "npm install",
  "echo done # trailing comment",
  "echo 'single' \"double\" \\$escaped",
  "echo a\\ b",
  "cat <<EOF\nbody\nEOF",
];

const WRAPPERS = [
  (s) => `if true; then ${s}; fi`,
  (s) => `while false; do ${s}; done`,
  (s) => `( ${s} )`,
  (s) => `{ ${s}; }`,
  (s) => `f() { ${s}; }`,
  (s) => `${s} && echo next`,
  (s) => `${s} || true`,
  (s) => `case x in a) ${s} ;; esac`,
  (s) => `for i in 1 2; do ${s}; done`,
  (s) => `$( ${s} )`,
  (s) => `x=\`${s}\`; echo $x`,
];

const MUTATORS = [
  // 截断：从某个位置砍掉尾巴
  (s) => s.slice(0, Math.floor(rnd() * s.length)),
  // 删除一段
  (s) => {
    const i = Math.floor(rnd() * s.length);
    const j = i + 1 + Math.floor(rnd() * Math.max(1, s.length - i - 1));
    return s.slice(0, i) + s.slice(j);
  },
  // 复制一段
  (s) => {
    const i = Math.floor(rnd() * s.length);
    const j = i + 1 + Math.floor(rnd() * Math.max(1, s.length - i - 1));
    return s.slice(0, j) + s.slice(i, j) + s.slice(j);
  },
  // 插一个构造进去
  (s) => {
    const i = Math.floor(rnd() * (s.length + 1));
    return s.slice(0, i) + " " + pick(ZOO) + " " + s.slice(i);
  },
  // 包一层
  (s) => pick(WRAPPERS)(s),
  // 拼接两个种子
  (s) => s + "\n" + pick(ZOO),
  // 去掉一个引号 / 括号 / 反斜杠
  (s) => {
    const i = Math.floor(rnd() * s.length);
    const c = s[i];
    if (!"\"'(){}[]\\$;|&<>".includes(c)) return s;
    return s.slice(0, i) + s.slice(i + 1);
  },
  // 复读一个特殊字符
  (s) => {
    const i = Math.floor(rnd() * s.length);
    const c = s[i];
    if (!"\"'(){}[]\\$;|&<>".includes(c)) return s;
    return s.slice(0, i) + c + s.slice(i);
  },
];

function shellOk(src) {
  const r = spawnSync(shell, ["-n", "-c", src], {
    encoding: "utf8",
    timeout,
    // zsh -n 在受限环境里会因为进程替换建不了临时文件而 abort，也就顺带堵住
    // 核心转储堆积（本项目已经踩过一次）。
    env: { ...process.env, TMPPREFIX: "/tmp/preshell-diff-zsh" },
  });
  const msg = (r.stderr || "").split("\n").filter(Boolean)[0] || "";
  return { ok: r.status === 0, msg, crashed: r.signal != null };
}

function ourStatus(src) {
  const r = spawnSync(bin, ["--cwd=" + root, dialectFlag, "--scan"], {
    input: src,
    encoding: "utf8",
    timeout,
  });
  if (r.signal != null || r.status === null) return { status: "CRASH", msg: "" };
  const line = (r.stdout || "").split("\n")[0] || "";
  const status = line.replace(/^status=/, "").split(" ")[0] || "?";
  const issue = (r.stdout || "").split("\n")[1] || "";
  return { status, msg: issue.replace(/^issue: /, "").replace(/ \(line \d+\)$/, "") };
}

fs.mkdirSync(outDir, { recursive: true });
const gaps = [];
const permissive = [];
const crashes = [];
let agreed = 0;

for (let i = 0; i < n; i++) {
  const base = pick(ZOO);
  const mutant = pick(MUTATORS)(base);
  if (mutant.trim() === "") continue;
  const oracle = shellOk(mutant);
  const ours = ourStatus(mutant);
  const weAccept = ours.status === "Complete";
  if (ours.status === "CRASH") {
    crashes.push({ mutant, ours });
  } else if (oracle.ok && !weAccept) {
    gaps.push({ mutant, ours, oracle });
  } else if (!oracle.ok && weAccept && !oracle.crashed) {
    permissive.push({ mutant, ours, oracle });
  } else {
    agreed++;
  }
}

function dump(name, list) {
  if (list.length === 0) return;
  const file = path.join(outDir, `${name}-${seed}.txt`);
  const lines = list.map(
    (c) =>
      `--- 我们：${c.ours.status}${c.ours.msg ? " / " + c.ours.msg : ""}\n` +
      (c.oracle ? `--- oracle：${c.oracle.ok ? "接受" : "拒绝"} ${c.oracle.msg}\n` : "") +
      c.mutant
        .split("\n")
        .map((l) => "  " + l)
        .join("\n"),
  );
  fs.writeFileSync(file, lines.join("\n\n") + "\n");
  console.log(`  样本写到 ${file}`);
}

console.log(`差分模糊：shell=${shell} 轮数=${n} 随机种子=${seed}`);
console.log(`  一致 ${agreed}  缺口 ${gaps.length}  太宽松 ${permissive.length}  崩溃 ${crashes.length}`);
dump("gap", gaps);
dump("permissive", permissive);
dump("crash", crashes);
if (gaps.length > 0) {
  console.log("  缺口样例：");
  for (const g of gaps.slice(0, 5)) {
    console.log(`    [${g.ours.status}] ${JSON.stringify(g.mutant).slice(0, 100)}`);
  }
}
if (permissive.length > 0) {
  console.log("  太宽松样例（危险方向，先看 oracle 原文）：");
  for (const p of permissive.slice(0, 5)) {
    console.log(`    ${JSON.stringify(p.mutant).slice(0, 80)}  ← oracle: ${p.oracle.msg.slice(0, 60)}`);
  }
}
process.exit(gaps.length + permissive.length + crashes.length > 0 ? 1 : 0);
