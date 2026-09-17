# 调用方式

preshell 是**独立工具**，调用它的唯一方式是起子进程。这样调用方用任何语言都行，
GPL 也停在进程边界上——不链接、不 import、不静态打包。

## 契约

```
stdin      命令文本，原样传入（推荐）
stdout     恰好一个 JSON 对象，没有别的
stderr     帮助、用法、诊断——绝不混进 stdout
退出码     0 = 产出了报告；非 0 = 工具自己没跑起来
           （没有「危险」这种退出码：判断一律读 JSON）
```

`--version` 给出版本与 schema 号，调用方据此锁定自己解析的形状：

```json
{"tool":"preshell","version":"0.1.0","schema":1}
```

## 为什么用 stdin 而不是参数

`preshell --json '<一堆指令>'` 能用，但把命令当参数传有三个问题：

- 命令里本来就有引号、换行、`$`，调用方得先转义一遍；转错了自己看不出来
- 单个参数有长度上限（Linux 常见 128KB）
- 经 shell 传参会被二次展开，命令已经不是原来那条了

stdin 没有这些问题：命令原样进去，原样分析。

## 安装

```bash
moon build --release --target native
install -Dm755 _build/native/release/build/cmd/preshell/preshell.exe ~/.local/bin/preshell
preshell --version
```

（`moon install` 也能装，但要等发布到 Mooncakes。）

## 从各种语言调用

### Node.js

```js
import { spawnSync } from "node:child_process";

export function analyze(command) {
  const r = spawnSync("preshell", [], { input: command, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`preshell failed: ${r.stderr}`);
  return JSON.parse(r.stdout);
}
```

要点：`input` 而不是把命令拼进 argv；`r.stdout` 直接 `JSON.parse`——
因为 stdout 上不会有别的东西，不需要从输出里「抠 JSON」。

### Python

```python
import json, subprocess

def analyze(command: str) -> dict:
    r = subprocess.run(["preshell"], input=command, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"preshell failed: {r.stderr}")
    return json.loads(r.stdout)
```

### Rust

```rust
use std::process::{Command, Stdio};
use std::io::Write;

pub fn analyze(command: &str) -> serde_json::Value {
    let mut child = Command::new("preshell")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().expect("spawn preshell");
    child.stdin.take().unwrap().write_all(command.as_bytes()).unwrap();
    let out = child.wait_with_output().expect("wait preshell");
    assert!(out.status.success(), "preshell failed: {}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).expect("preshell produced invalid JSON")
}
```

### Shell

```bash
preshell < script.sh | jq .
```

## 读什么、别读什么

- `impact.effects` — 事实清单：`Exec` / `Read` / `Write` / `Delete` / `Net` / `Unknown`
- `impact.write_roots` — 会被改到的目录
- `impact.uncertain` — **先看这个**。true 表示这份影响面不是封闭集合
- `impact.cwd` — 相对路径的基准；字段缺失表示命令内部没有 `cd`，那基准就是调用方自己的
- `status` — `Complete` / `Unsupported` / `Invalid`，描述我们看懂了多少

别把 `uncertain: false` 读成「安全」，也别把 `effects` 里没有 `Write` 读成「不写」——
先看有没有 `modeled: false` 的 `Exec`：那是「有程序跑了，它碰什么我们不建模」。

## 性能与状态

- 单次调用约 1ms（进程启动为主，解析 3µs）。一次审查一条命令，不需要常驻
- 工具无状态、不写任何文件、不发网络请求，可以并发调用
- 不需要任何权限配置：它只读自己的 stdin
