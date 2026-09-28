#!/usr/bin/env node
// 从候选文件里挑出真正的 shell 脚本，一行一个路径输出。
//
// 这一步原来在 find_scripts.sh 里用 `head -c 256 "$f" | grep -qE …` 做，每个
// 候选起两个进程。候选是几万个（`-perm -u+x` 把所有可执行文件都选进来了），
// 一次采集光这一项就是十秒。
//
// 为什么不换成 shell 内建的 `read -N 256`：`-N` 数的是**字符**，`head -c` 数的
// 是**字节**，两者在非 ASCII 文件上不等价——换过去实测能多收 6 个、少收 1 个
// 文件，而语料是四象限的基线，不能悄悄变。所以这里按字节读，语义与原来一致。
//
// 用法：filter_scripts.mjs < shebang 正则 < 候选路径列表

import { openSync, readSync, closeSync, readFileSync } from "node:fs";

const pattern = process.argv[2];
if (!pattern) {
  console.error("用法：filter_scripts.mjs <shebang 正则> < 候选列表");
  process.exit(2);
}
// `m` 是必须的：原来这一步是 `grep -qE`，它按行匹配，而 JS 的 `^` 默认只认整个
// 字符串的开头。首行是空行、shebang 在第二行的脚本真的存在（android-studio 的
// studio_safe.sh），少了这个标志就会把它们静默丢掉。
const re = new RegExp(pattern, "m");

const candidates = readFileSync(0).toString("utf8").split("\n");

const out = [];
for (const f of candidates) {
  if (f === "") continue;
  let fd;
  let buf;
  try {
    fd = openSync(f, "r");
    buf = Buffer.alloc(256);
    const n = readSync(fd, buf, 0, 256, 0);
    buf = buf.subarray(0, n);
  } catch {
    // 读不动就跳过：原来 `head` 失败时 `grep` 也拿不到东西，同样不算数。
    if (fd !== undefined) closeSync(fd);
    continue;
  }
  closeSync(fd);
  if (re.test(buf.toString("utf8"))) out.push(f);
}
process.stdout.write(out.join("\n") + (out.length > 0 ? "\n" : ""));
