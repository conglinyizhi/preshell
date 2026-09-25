#!/usr/bin/env node
// 变异式模糊测试：拿真实语料当种子，随机变异后喂给 preshell。
//
// 目的不是「找到错误的判定」，而是找**工具死掉**：崩溃（信号）、挂死、
// 输出不是合法 JSON。这三类在真实使用里等于「审核器不工作」，而审核器不工作
// 时调用方最常见的反应是照常执行命令。
//
// 用法：
//   node tools/fuzz/mutate.js [选项]
//     --bin <path>       被测二进制（默认 _build/native/release/build/cmd/preshell/preshell.exe）
//     --seeds <list>     种子文件列表（默认 tools/corpus/bash-tests 下全部）
//     --n <count>        轮数（默认 3000）
//     --timeout <ms>     单次超时（默认 5000）
//     --out <dir>        失败样本落盘目录（默认 /tmp/preshell-fuzz）
//     --seed <int>       随机数种子，便于复现（默认取时间）
//
// 失败样本会连同当次的变异记录一起写到 --out，方便复现。

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function arg(name, dflt) {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

const root = path.resolve(__dirname, "../..");
const bin = arg("bin", path.join(root, "_build/native/release/build/cmd/preshell/preshell.exe"));
const n = parseInt(arg("n", "3000"), 10);
const timeout = parseInt(arg("timeout", "5000"), 10);
const outDir = arg("out", "/tmp/preshell-fuzz");
const rngSeed = parseInt(arg("seed", String(Date.now() % 2147483647)), 10);

// 线性同余，够用且可复现
let state = rngSeed;
function rnd(max) {
  state = (state * 1103515245 + 12345) & 0x7fffffff;
  return state % max;
}

const seedsDir = arg("seeds", path.join(root, "tools/corpus/bash-tests"));
let seeds = [];
if (fs.existsSync(seedsDir) && fs.statSync(seedsDir).isDirectory()) {
  for (const f of fs.readdirSync(seedsDir)) {
    if (f.endsWith(".sub")) seeds.push(path.join(seedsDir, f));
  }
} else if (fs.existsSync(seedsDir)) {
  seeds = fs.readFileSync(seedsDir, "utf8").split("\n").filter(Boolean);
}
if (seeds.length === 0) {
  console.error("没有种子文件：" + seedsDir);
  process.exit(2);
}

const buffers = seeds.map((f) => fs.readFileSync(f));
const META = Buffer.from("(){}[]<>|&;$`'\"\\ \n\t*?!~#-=");

const mutations = [
  // 1 单字节翻转
  (b) => {
    const i = rnd(b.length);
    b[i] = b[i] ^ (1 << rnd(8));
    return "flip@" + i;
  },
  // 2 删除一段
  (b) => {
    const i = rnd(b.length);
    const len = 1 + rnd(Math.min(64, b.length - i));
    return "delete@" + i + "+" + len + " " + (b = Buffer.concat([b.slice(0, i), b.slice(i + len)]), "");
  },
  // 3 复制一段
  (b) => {
    const i = rnd(b.length);
    const len = 1 + rnd(Math.min(256, b.length - i));
    return "dup@" + i + "+" + len + " " + (b = Buffer.concat([b.slice(0, i + len), b.slice(i, i + len), b.slice(i + len)]), "");
  },
  // 4 截断
  (b) => {
    const i = rnd(b.length + 1);
    b = b.slice(0, i);
    return "truncate@" + i;
  },
  // 5 插入元字符
  (b) => {
    const i = rnd(b.length + 1);
    const c = META[rnd(META.length)];
    b = Buffer.concat([b.slice(0, i), Buffer.from([c]), b.slice(i)]);
    return "meta@" + i + "=" + JSON.stringify(String.fromCharCode(c));
  },
  // 6 插入随机字节
  (b) => {
    const i = rnd(b.length + 1);
    const c = rnd(256);
    b = Buffer.concat([b.slice(0, i), Buffer.from([c]), b.slice(i)]);
    return "byte@" + i + "=0x" + c.toString(16);
  },
  // 7 与另一个种子拼接
  (b) => {
    const other = buffers[rnd(buffers.length)];
    const cut = rnd(b.length + 1);
    b = Buffer.concat([b.slice(0, cut), other]);
    return "splice@" + cut;
  },
  // 8 重复某一行很多次
  (b) => {
    const lines = b.toString("binary").split("\n");
    const i = rnd(lines.length);
    lines[i] = lines[i].repeat(1 + rnd(200));
    b = Buffer.from(lines.join("\n"), "binary");
    return "repeatline@" + i;
  },
  // 9 去掉所有换行
  (b) => {
    b = Buffer.from(b.toString("binary").replace(/\n/g, " "), "binary");
    return "nonewlines";
  },
  // 10 只留元字符
  (b) => {
    const keep = [];
    for (const c of b) if (META.includes(c)) keep.push(c);
    b = Buffer.from(keep);
    return "metasonly";
  },
];

fs.mkdirSync(outDir, { recursive: true });

let ok = 0,
  crash = 0,
  hang = 0,
  badjson = 0;
const findings = [];
// 变异体打到了多深：只看「有没有崩溃」不足以说明这个 fuzzer 有强度，
// 一个只喂进门的垃圾就被拒的 fuzzer 同样是干净的。这里统计解析状态的分布。
const statusCount = { Complete: 0, Unsupported: 0, Invalid: 0, unknown: 0 };

for (let round = 0; round < n; round++) {
  let buf = Buffer.from(buffers[rnd(buffers.length)]);
  const applied = [];
  const steps = 1 + rnd(4);
  for (let s = 0; s < steps; s++) {
    applied.push(mutations[rnd(mutations.length)](buf));
  }

  const r = spawnSync(bin, ["--cwd=" + root], {
    input: buf,
    timeout,
    maxBuffer: 64 * 1024 * 1024,
  });
  let verdict = "ok";
  if (r.error && r.error.code === "ETIMEDOUT") verdict = "hang";
  else if (r.signal) verdict = "crash";
  else if (r.status !== 0) verdict = "exit" + r.status;
  else {
    const out = (r.stdout || Buffer.alloc(0)).toString("utf8");
    try {
      const parsed = JSON.parse(out);
      const s = parsed && parsed.status;
      if (statusCount[s] !== undefined) statusCount[s]++;
      else statusCount.unknown++;
    } catch (e) {
      verdict = "badjson";
    }
  }

  if (verdict === "ok") {
    ok++;
  } else {
    if (verdict === "crash") crash++;
    else if (verdict === "hang") hang++;
    else badjson++;
    const file = path.join(outDir, "case-" + round + "-" + verdict);
    fs.writeFileSync(file, buf);
    fs.writeFileSync(
      file + ".meta",
      "seed-roulette=" + rngSeed + "\nverdict=" + verdict + "\nmutations=" + applied.join(" | ") + "\nbytes=" + buf.length + "\n",
    );
    findings.push(verdict + " " + file + "  [" + applied.join(" | ") + "]");
  }

  if ((round + 1) % 500 === 0) {
    process.stderr.write("  " + (round + 1) + "/" + n + "  崩溃 " + crash + " 挂死 " + hang + " 非法JSON " + badjson + "\n");
  }
}

console.log("轮数 " + n + "  种子数 " + seeds.length + "  rng=" + rngSeed);
console.log(
  "解析状态分布：Complete " +
    statusCount.Complete +
    "  Unsupported " +
    statusCount.Unsupported +
    "  Invalid " +
    statusCount.Invalid +
    "  未知 " +
    statusCount.unknown,
);
console.log("通过 " + ok + "  崩溃 " + crash + "  挂死 " + hang + "  输出异常 " + badjson);
if (findings.length) {
  console.log("\n失败样本：");
  for (const f of findings.slice(0, 30)) console.log("  " + f);
  if (findings.length > 30) console.log("  … 另有 " + (findings.length - 30) + " 个，见 " + outDir);
}
process.exit(findings.length === 0 ? 0 : 1);
