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
TAG=v0.4.0
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
preshell --cwd=/srv/app 'rm -rf dist'
```

结果是 JSON 报告：

```json
{
  "status": "Complete",
  "impact": {
    "effects": [
      { "kind": "Delete", "target": "/srv/app/build", "dynamic": false }
    ],
    "write_roots": ["/srv/app"],
    "uncertain": false,
    "cwd": "/srv/app"
  },
  "issues": []
}
```

先看 `status` 和 `impact.uncertain`：

- `Complete`：解析完整
- `Unsupported`：shell 接受，但 PreShell 没有建模其中一部分
- `Invalid`：有证据表明 shell 自身也会拒绝这条命令
- `uncertain: true`：效果列表不是封闭集合，空列表不等于“什么都没碰”

## 相对路径与 pwd

**路径一律输出绝对路径。** 工具不读磁盘，所以基准只能由调用方给：

```bash
preshell --cwd=/srv/app 'rm -rf dist'    # Delete: /srv/app/dist
```

`--cwd` 必须是绝对路径，而且事实上必填——它是你对「这条命令会在哪个目录里跑」的断言。

没传时工具拿自己进程的当前目录推演（调用方一般就在自己的工作目录里起这个子进程），
并在报告里附一条 `Note` 说明基准是推演来的，同时置 `impact.uncertain: true`。
看到这条 Note 就该补 `--cwd`。

读了变量的路径会说出来：每条路径效果带 `vars`，`impact.vars` 是去重后的并集。工具不读环境，
所以它交出来的就是名字——拿 `HOME` 替换 `$HOME/x` 就得到真实路径。`~` 是 `HOME`、`~+` 是
`PWD`、`~-` 是 `OLDPWD`；`~user` 和 `~N` 是没有名字的洞，因为环境查不到它们。

命令自己写出来的值直接解出来，不再出现在 `vars` 里：`x=dist; rm -rf $x` 报 `/srv/app/dist`。
覆盖的范围是普通赋值、输入里写全的 `for` 词表、以及会写变量的内建（`export`、`read`、
`unset`、`printf -v` 等）。带空白的值按 shell 的规则分词——`x="a b"; rm $x` 是两条路径，
`rm "$x"` 是一条名字里带空格的路径；花括号展开也跟着算，所以 `rm -rf {a,b}` 是两条路径
而不是一个叫 `{a,b}` 的文件。剩下的仍是洞：通配符、命令替换、没设过的名字，以及只在
一条路径上成立的值。

一个名字可能有多个取值时（`if c; then x=a; else x=b; fi; rm $x`），那条效果会多一个
`candidates` 字段，列出这个洞可能是哪几条路径。它是**可能性，不是事实**：`target` 仍是
洞、`dynamic` 仍为真，列表要么穷尽要么不出现（不截断）。要拿事实继续用 `target` + `vars`。

同一行的同一件事只报一次：循环体按词表走多遍时不会刷屏。判定包含行号，所以写在两行上的
同一个 `rm x` 仍是两条；而「这份重复跑了几次」刻意不进报告。

有两类路径保持原样，因为对它们来说绝对路径确实不存在：`cd` 目的地不可建模之后的路径，
以及**词首是运行时才展开的东西**（`$HOME/x`、`~/x`）。参数的值按原样使用，结果是不是绝对
路径是运行时事实，而这个值调用方知道。两类都会置 `impact.uncertain`。

`--cwd` 是解析起点，不是 `cd`：它不产生任何效果，命令内部的 `cd` 优先于它。`cd`
只影响同一条命令行里它之后的部分——子 shell、命令替换、管道的每个元素、交给别的
shell 的脚本各有一份副本，多个 `cd` 依次累积。唯一保持原样的是 `cd` 目的地不可建模时
（`cd $DIR`）之后的路径，那里会置 `uncertain`，因为绝对路径在信息上确实不存在。

`issues[]` 里的 `Note` 是警告：解析成功了，但这份报告不该被当成干净账单。每条警告都会
强制 `impact.uncertain`。目前只有一条，文案以 `no --cwd given` 开头。要程序化判定就匹配这个
前缀，别匹配整句：文案是散文，会改。

完整契约见 [docs/integration.md](docs/integration.md)。

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
{"id":"random-value","report":{"status":"Complete"}}
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
- 有几类**畸形的输入仍会被接受**（两个 shell 都拒而我们报 Complete）：`${ ... }` 里不是
  合法展开的内容、数组赋值括号里的东西、case 分支 `;;` 到 `esac` 之间的垃圾、以及
  `[[ ... ]]` 里坏掉的条件。解析通过只说明语法在能识别的范围里成立，不是有效性保证

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
