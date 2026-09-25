# PreShell

PreShell（命令：`preshell`）是一个只报告事实的 shell 命令分析器，不是审批器。

给它一条 shell 命令，它会告诉你：

- 会执行哪些程序
- 会读取、写入或删除哪些路径
- 是否会联网或启动另一个程序
- 哪些部分无法静态确定

PreShell **不会执行输入的命令**，不会读取调用方磁盘，不会联网，也不做 allow/deny 判断。

> English: [README.md](README.md)
>
> 完整接入说明：[docs/integration.md](docs/integration.md)
>
> 第三方材料、来源和许可证：[docs/third-party-licenses.md](docs/third-party-licenses.md)

## 快速开始

### 使用发布版

```bash
TAG=v0.2.1
gh release download "$TAG" -R conglinyizhi/preshell -D /tmp/preshell
cd /tmp/preshell
sha256sum -c SHA256SUMS
install -Dm755 preshell-$TAG-*.linux ~/.local/bin/preshell
```

### 从源码构建

需要 MoonBit 工具链：

```bash
moon update
moon build --release --target native
install -Dm755 _build/native/release/build/cmd/preshell/preshell.exe ~/.local/bin/preshell
```

检查安装：

```bash
preshell --version
preshell --help
preshell --man
preshell --man-markdown
```

## 基本用法

推荐把命令通过 stdin 原样传入：

```bash
printf '%s' 'rm -rf build' | preshell
```

也可以把命令作为参数传入：

```bash
preshell 'rm -rf build'
preshell --pretty 'make -j8'
```

结果是 JSON 报告：

```json
{
  "version": 1,
  "status": "Complete",
  "impact": {
    "effects": [
      { "kind": "Delete", "target": "build", "dynamic": false }
    ],
    "write_roots": ["."],
    "uncertain": false
  },
  "issues": []
}
```

先看 `status` 和 `impact.uncertain`：

- `Complete`：解析完整
- `Unsupported`：shell 接受，但 PreShell 没有建模其中一部分
- `Invalid`：有证据表明 shell 自身也会拒绝这条命令
- `uncertain: true`：效果列表不是封闭集合，空列表不等于“什么都没碰”

## Bash 和 zsh

默认按输入的 shebang 选择方言，没有声明时按 bash 处理：

```bash
preshell --shell=bash < command.sh
preshell --shell=zsh < command.zsh
preshell --shell=probe < command.sh
```

zsh 支持需要明确指定 `--shell=zsh`，或者让输入通过 shebang 声明。PreShell 不把 zsh 源码打包进项目；zsh 语料只在外部源码树上用于验证。

## 批量分析

`--stream` 使用 JSON Lines，一行请求对应一行应答：

```bash
jq -Rc . commands.txt | preshell --stream > reports.jsonl
```

请求可以带随机 id：

```json
{"id":"random-value","command":"rm -rf build"}
```

对应的应答会带信封：

```json
{"id":"random-value","report":{"version":1,"status":"Complete"}}
```

流式调用时，调用方必须：

1. 串行写入 stdin
2. 按换行缓冲 stdout
3. 使用不可预测的随机 id
4. 防止其他子进程继承管道 fd

完整协议请运行：

```bash
preshell --spec
```

## 在 Markdown 中运行 MoonBit 示例

仓库里的 [lib/README.mbt.md](lib/README.mbt.md) 是可执行的 MoonBit Markdown 文档。
安装 MoonBit VS Code 插件后，可以在编辑器里获得代码高亮、诊断、跳转和 Test CodeLens。

在仓库根目录运行：

```bash
moon test lib/README.mbt.md --target native
```

这些示例直接调用现有的 `@lib.analyze` API，不启动外部 `preshell` 进程，也不需要额外库接口。

## 设计边界

- PreShell 是分析器，不是 sandbox
- PreShell 是事实报告器，不是策略引擎
- `[[ ... ]]` 的条件内容本身不求值，但其中的命令替换会继续分析
- 没有建模的外部程序会标记 `modeled: false` 并强制 `uncertain`
- 静态分析无法解决的内容会报告不确定性，不猜一个看似完整的答案

## 许可证与第三方材料

PreShell 自身使用 GPL-3.0-or-later，许可证全文见 [LICENSE](LICENSE)。

Bash 5.3 的部分语法测试作为第三方测试语料随仓库分发；zsh 源码不随仓库分发，只作为外部 oracle 使用。归属、来源、文件范围和许可边界见 [NOTICE](NOTICE) 与 [docs/third-party-licenses.md](docs/third-party-licenses.md)。

## 相关入口

- English README：[README.md](README.md)
- 完整接入：[docs/integration.md](docs/integration.md)
- 人类手册：[docs/preshell.md](docs/preshell.md)
- Agent 手册：`preshell --man-markdown`
- 机器契约：`preshell --spec`
- Release：[GitHub Releases](https://github.com/conglinyizhi/preshell/releases)
