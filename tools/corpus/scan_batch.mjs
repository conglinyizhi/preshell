#!/usr/bin/env node
// 把一个文件列表一次喂给 preshell 的流式模式，输出每个文件的结论。
//
// 为什么不让 shell 逐个文件调：语料与方言对照各要跑上千个文件，每个文件起
// 一次进程、读一次配置，那一半的开销就在这里。流式是一个进程吃一批。
//
// 输入：stdin 每行一个文件路径。
// 输出：每行 `<路径>\t<status>\t<issues>`，与原顺序一致。
//   - `status` 是 `Complete`/`Unsupported`/`Invalid`；工具没给出报告时是
//     `ERROR:<原话>`，调用方据此把「崩了或缺输入」与「判定结果」分开。
//   - `issues` 用 `\x1f`（US）分隔，消息里的换行写成 `\x1e`（RS），所以一行
//     就是一条记录，shell 侧 `read` 得动。
//
// 用法：scan_batch.mjs <preshell 二进制> [额外参数...] < 文件列表
//
// 契约是工具自己的 `--stream`：一行输入一行输出，拒绝也算一行，顺序不变。
// 这里不重排、不合并：行数对不上就报错，宁可让调用方看见，也不要错位。

import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";

const [bin, ...args] = process.argv.slice(2);
if (!bin) {
  console.error("用法：scan_batch.mjs <preshell 二进制> [额外参数...] < 文件列表");
  process.exit(2);
}

const paths = readFileSync(0, "utf8")
  .split("\n")
  .filter((p) => p.trim() !== "");

const child = spawn(bin, [...args, "--stream"], { stdio: ["pipe", "pipe", "pipe"] });

let out = "";
let err = "";
child.stdout.on("data", (d) => {
  out += d;
});
child.stderr.on("data", (d) => {
  err += d;
});

// 写完就关：输入可能几 MB，而输出同时在被读走，所以不会把管道堵死。
for (const p of paths) {
  let text = "";
  try {
    text = readFileSync(p, "utf8");
  } catch {
    // 读不动就当空输入：CLI 会照常回一行报告，行数不会错位。
    text = "";
  }
  child.stdin.write(JSON.stringify(text) + "\n");
}
child.stdin.end();

child.on("close", (code) => {
  const lines = out.split("\n").filter((l) => l !== "");
  if (lines.length !== paths.length) {
    console.error(
      `scan_batch：输入 ${paths.length} 个文件，回来 ${lines.length} 行；` +
        `流式契约是一行一答，先查工具是不是退了。${err ? "\n" + err : ""}`,
    );
    process.exit(1);
  }
  let bad = 0;
  for (let i = 0; i < paths.length; i++) {
    let status;
    let issues = "";
    try {
      const r = JSON.parse(lines[i]);
      if (typeof r.status === "string") {
        status = r.status;
        if (Array.isArray(r.issues)) {
          issues = r.issues
            .map((it) => String(it.message ?? "").replace(/\n/g, "\x1e"))
            .join("\x1f");
        }
      } else {
        // 拒绝对象：`{"error":…,"line":N}`，与报告的区别就在没有 status。
        status = "ERROR:" + String(r.error ?? "").replace(/\n/g, " ");
      }
    } catch (e) {
      status = "ERROR:" + String(e.message).replace(/\n/g, " ");
      bad++;
    }
    process.stdout.write(`${paths[i]}\t${status}\t${issues}\n`);
  }
  if (bad > 0) {
    console.error(`scan_batch：${bad} 行不是合法 JSON（上面的 status 是 ERROR:…）`);
  }
  process.exit(bad > 0 ? 1 : 0);
});
