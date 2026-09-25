# 接入指引

给要把 PreShell 接进自己项目的读者。读这一份就够：从许可边界到调用姿势、
到上线前该检查什么。它只做静态分析——**不执行你的命令、不读磁盘、不联网**，
所以你可以放心把不可信的文本喂给它。

## 只有一种接法：子进程

PreShell 是**独立工具**，不是库。接它的唯一方式是起子进程，命令从 stdin 进，
报告从 stdout 出：

```
你的程序  ──stdin──▶  PreShell  ──stdout──▶  JSON 报告
```

不链接、不 import、不静态打包。这样调用方用任何语言都行，GPL 也停在进程边界上。

## 许可边界

PreShell 是 GPL-3.0-or-later。那是**程序**的许可，不是**协议**的许可。
你和它之间只有一条管道，两个程序在手臂长度上通信，自由软件的通行读法不把
这当成「你的作品包含了我」——所以你的项目可以闭源、可以用任何许可，
包括与 GPL 不兼容的许可。

越界与不越界：

| 做法 | 结果 |
|---|---|
| 把 `lib` 包 import 进你的 MoonBit 程序并链接 | 衍生作品，整体要 GPL-3.0-or-later |
| 把源码文件拷进你的仓库再用 | 衍生作品 |
| 改一改再编进你自己的可执行文件 | 衍生作品 |
| 起子进程，用 stdin/stdout 交换 JSON | **不是**衍生作品，你的代码归你 |
| 让用户自己装，你只调用 | 零义务，最省事 |
| 把二进制和你的程序放进同一个安装包一起发 | 聚合，各自的许可不变（GPLv3 §5），但分发义务归你（见下） |

如果你**分发**这个二进制（随包、随镜像、随容器），GPLv3 §6 要求你：

- 给对应源码，或者给一份书面 offer（网络分发时，给同一地点取得源码的等价方式）
- 保留版权声明与许可全文，即仓库里的 `LICENSE`
- 你改过就标明改动
- 不对下游加额外限制

推荐的接法因此是**别分发它**：在文档里写一句「需要 PreShell，请自行安装」，
你只调用 PATH 上的 `preshell`。这样你没有分发义务，也没有跟进版本的义务。

不要做的事：抹掉它的来源与许可；把它说成你自研的实现；把它的 JSON 契约
换个名字包装成你的私有格式再宣称自研；把它的源码抄进你的实现。
最后两条的后果和上表第一行一样。

一句免责：以上是 GPL 的通行读法，不是法律意见，法务口径严的团队请让法务过一眼。
工具本身也不带任何担保，报告是事实不是裁决——别拿它当唯一的闸门。

## 契约

有两种模式，命令都从 stdin 进，报告都从 stdout 出，退出码规则相同：

| | 单条模式 | 批量模式 `--stream` |
|---|---|---|
| stdin | 一条命令，原样 | 每行一个请求：`"命令"` 或 `{"id":…,"command":"…"}` |
| stdout | 恰好一个 JSON 对象 | 每行一个应答，顺序与输入一致；一行输入一行输出 |
| stderr | 帮助、用法、诊断，绝不混进 stdout | 同上，另外结尾一行计数 |

```
退出码     0 = 该产出的应答都产出了
           2 = 用法错误（未知选项、未知 --shell 值、不能组合的模式）：
               原因在 stderr，stdout 为空
           其它非 0 = 工具自己没跑起来
           （没有「危险」这种退出码：判断一律读 JSON）
```

空的命令文本**也是一条命令**：你会拿到一份「什么都没碰」的正常报告
（`status: Complete`、`effects: []`、`uncertain: false`）。之所以强调，是因为
调用方总是把手上拿到的东西原样塞进来，而「没有报告」和「工具坏了」必须能分开。

上面这些不止在这份文档里：`preshell --help` 是同一份契约的速查（带地址），
`preshell --spec` 是它的机读形式（JSON，给拿得到二进制、拿不到仓库的 agent 用），
完整手册的唯一事实来源是 `docs/preshell.md`：二进制用 `preshell --man` 输出纯文本，
用 `preshell --man-markdown` 输出 Markdown，`docs/preshell.1` 则供 `man preshell`；第三方材料和许可见 `docs/third-party-licenses.md`。
生成链由 `tools/embed_manual.mjs` 维护，不要直接编辑生成文件。

PreShell 的 GitHub Release 页面是变更记录，不重复 README 的项目介绍。发布 workflow 从 tag 之间的
提交标题自动生成说明：`feat`、`fix`、`perf`、`refactor` 排在前面，所有详细记录折叠，
`ci`、`test`、`chore`、`build` 放在工程维护区。本地预览用
`tools/release_notes.sh --from v旧 --to HEAD --assets dist`。

开发者模式（`--scan`、`--shadow`、`--bench`、`--evidence`）不满足上面这条契约，
它们是给我自己调试用的。集成里只用默认模式、`--shell`、`--cwd` 与 `--stream`。

`--version` 给出版本与 schema 号，调用方据此锁住自己解析的形状：

```json
{"tool":"preshell","version":"0.2.1","schema":1}
```

## 相对路径与 pwd

**路径一律输出绝对路径，没有例外。** 这条要求决定了另一件事：基准从哪来。工具不读磁盘，
所以基准只能由调用方给。

```bash
preshell --cwd=/srv/app 'rm -rf dist'    # Delete: /srv/app/dist, impact.cwd: /srv/app
```

| 你怎么调用 | 报告里的路径 | `impact.cwd` | `uncertain` |
|---|---|---|---|
| `--cwd=/srv/app` | 绝对：`/srv/app/dist` | `/srv/app` | false |
| 不给 `--cwd` | 绝对：`<本进程当前目录>/dist` | 同上 | **true**，并带一条 `Note` |
| 命令自己 `cd /tmp` | 绝对：`/tmp/dist` | `/tmp` | false |

规则：

- **`--cwd` 事实上必填。** 它是调用方对「这条命令会在哪个目录里跑」的断言，必须是绝对路径；
  给相对值直接是用法错误（退出码 2）
- 没给 `--cwd` 时，工具拿**自己进程的当前目录**当基准推演：调用方一般是直接在
  自己的工作目录里起这个子进程，所以这通常就是对的。为了不把猜测当成事实，这份报告会
  附一条 `Note` 说明基准是推演来的，并置 `uncertain: true`。看到它就该传 `--cwd`
- `--cwd` 是解析起点，不是 `cd`：它不产生任何效果，也不出现在 `effects` 里；命令内部的
  `cd` 优先于它
- **两类路径给不出绝对路径**，都保持原样并置 `uncertain: true`。这不是回退策略，是绝对
  路径在信息上确实不存在；宁可留下缺口，也不编一个：
  - `cd` 的目的地不可建模（`cd $DIR`），此后的路径基准未知
  - **词首是运行时才展开的东西**（`$HOME/x`、`~/x`）。参数的值按原样使用，它是不是绝对
    路径是运行时事实，把基准拼上去只会算错（`$HOME/x` 配 `HOME=/home/u` 是 `/home/u/x`，
    不是 `/base/home/u/x`）。这个值调用方知道，由它收尾
- 词首的 `~` 属于后一类：`~` 是 `$HOME`、`~+` 是 `$PWD`、`~-` 是 `$OLDPWD`、`~user` 是那个
  用户的家目录；**登录名无效时 bash 原样保留前缀**，那时它反倒是相对路径。加引号的 `"~"`
  是字面量，照常锚定（依据：bash 5.3 手册的 "Tilde Expansion" 与 "Expansion"）

### cd 影响基准的范围

`cd` 只影响**同一条命令行里它之后的命令**，作用域跟 shell 一致：

- 单条命令、单个脚本文件：`cd /a && rm x` 里的 `x` 相对 `/a`
- 多个 `cd` 依次累积：`cd /a && cd b && cd ../c` 的基准是 `/a/c`
- 子 shell 不影响外面：`(cd /tmp && rm x); rm y` 里 `y` 仍按外层基准
- 命令替换不影响外面：`x=$(cd /tmp && rm y); rm z` 里 `z` 仍按外层基准
- 管道的每个元素各有一份：`cd /tmp | rm x` 里 `x` 不跟着 `/tmp`
- 交给另一个 shell 的脚本自己一份：`bash -c "cd /tmp; rm x"; rm y`
- `..` 到根为止：`cd / && cd ..` 仍是 `/`

### 要求：调用方必须提供 pwd

**人或 agent 调用时都要传 `--cwd`。** 不传不会报错，但报告会带 `Note` 与
`uncertain: true`，等于告诉下游「这个基准是猜的」。把基准说清楚是调用方的事，
工具不替这一步决定。

## 警告

`issues[]` 里的 `Note` 就是警告：解析成功，但这份报告不该被当成一份干净账单。

- 每条警告都会强制 `impact.uncertain: true`，所以「有没有警告」和「要不要多看一眼」是同一件事
- 目前只有基准相关的两条，都以 `no --cwd given` 开头：一条是没传 `--cwd`（基准从当前目录推演），
  一条是连当前目录都读不到（此后的路径只能保持原样）
- **基准值本身不写在警告里**，它在 `impact.cwd`：文案短、不随路径长度膨胀（批量模式下这条
  警告每行都会出现）
- 要程序化判定，匹配 `no --cwd given` 这个前缀就够。**别匹配整句**：文案是散文，会改
- `Gap` / `Syntax` 不是警告，是解析器发现：它们描述「我们看懂了多少」，会让 `status` 变成
  `Unsupported` / `Invalid`

## 为什么用 stdin 而不是参数

`preshell '<一堆指令>'` 能用，但把命令当参数传有三个问题：

- 命令里本来就有引号、换行、`$`，调用方得先转义一遍；转错了自己看不出来
- 单个参数有长度上限（Linux 常见 128KB）
- 经 shell 传参会被二次展开，命令已经不是原来那条了

stdin 没有这些问题：命令原样进去，原样分析。

## 安装与分发

### 直接用发布版（不想装工具链）

```bash
TAG=v0.2.1
gh release download "$TAG" -R conglinyizhi/preshell -D /tmp/preshell
cd /tmp/preshell && sha256sum -c SHA256SUMS
install -Dm755 preshell-$TAG-*.linux ~/.local/bin/preshell
```

产物是自仓库那个 tag 构建的 x86_64 Linux 二进制（发布由 `.github/workflows/release.yml`
自动完成）；不想用二进制就照下面自己编。

### 你自己编（开发时）

```bash
moon build --release --target native
install -Dm755 _build/native/release/build/cmd/preshell/preshell.exe ~/.local/bin/preshell
install -Dm644 docs/preshell.1 ~/.local/share/man/man1/preshell.1
preshell --version
preshell --spec | jq .     # 契约的机读形式
man preshell                # 同上，给人看的
```

（`moon install` 也能装，但要等发布到 Mooncakes。）

### 让用户自己装（推荐的集成姿势）

文档里写清依赖，代码里只调用 `preshell`：

```markdown
本工具需要 PreShell（GPL-3.0-or-later），请自行安装：
<moon build 的说明，或发行版包名>
```

二进制找不到时报错并提示用户装，**不要静默降级**——降级等于把审查悄悄关掉。

### 你随包分发

照「许可边界」那张表的义务清单办。许可全文在仓库 `LICENSE`，源码就是这个仓库。

## 从各种语言调用

### 最小可用

Node.js：

```js
import { spawnSync } from "node:child_process";

export function analyze(command) {
  const r = spawnSync("preshell", [], { input: command, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`PreShell failed: ${r.stderr}`);
  return JSON.parse(r.stdout);
}
```

Python：

```python
import json, subprocess

def analyze(command: str) -> dict:
    r = subprocess.run(["preshell"], input=command, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"PreShell failed: {r.stderr}")
    return json.loads(r.stdout)
```

Rust：

```rust
use std::process::{Command, Stdio};
use std::io::Write;

pub fn analyze(command: &str) -> serde_json::Value {
    let mut child = Command::new("preshell")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().expect("spawn preshell");
    child.stdin.take().unwrap().write_all(command.as_bytes()).unwrap();
    let out = child.wait_with_output().expect("wait preshell");
    assert!(out.status.success(), "PreShell failed: {}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).expect("preshell produced invalid JSON")
}
```

Shell：

```bash
preshell < script.sh | jq .
```

要点：命令走 `input`/stdin，不拼进 argv；`stdout` 直接解析，不需要从输出里
「抠 JSON」——它上面不会有别的东西。

### 生产上要补的四件事

上面那些片段能跑，但不够接生产。真正要处理的是**拿不到报告时怎么办**：
默认动作应当是「问人」，而不是放行。

Node.js：

```js
import { spawnSync } from "node:child_process";

const BIN = process.env.PRESHELL_BIN ?? "preshell";

// { ok: true, report } | { ok: false, reason }
export function analyze(command, { timeoutMs = 2000 } = {}) {
  const r = spawnSync(BIN, [], { input: command, encoding: "utf8", timeout: timeoutMs });
  if (r.error?.code === "ENOENT") return { ok: false, reason: "preshell-missing" };
  if (r.error) return { ok: false, reason: "preshell-failed" };   // 超时也在这类
  if (r.status !== 0) return { ok: false, reason: "usage-error" }; // stderr 里是原因
  try {
    return { ok: true, report: JSON.parse(r.stdout) };
  } catch {
    return { ok: false, reason: "bad-json" };
  }
}
```

Python：

```python
import json, os, subprocess

BIN = os.environ.get("PRESHELL_BIN", "preshell")

class PreshellUnavailable(RuntimeError):
    """拿不到报告：缺二进制、超时、用法错误、JSON 坏了都归这里。"""

def analyze(command: str, timeout: float = 2.0) -> dict:
    try:
        r = subprocess.run([BIN], input=command, capture_output=True,
                           text=True, timeout=timeout)
    except FileNotFoundError as e:
        raise PreshellUnavailable("PreShell 不在 PATH 上") from e
    except subprocess.TimeoutExpired as e:
        raise PreshellUnavailable("PreShell 超时") from e
    if r.returncode != 0:
        raise PreshellUnavailable(f"PreShell 退出 {r.returncode}: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout)
```

四件事：

1. **超时**。单次调用约 1ms，但还是要设上限（比如 2s）：一个卡住的子进程不该
   拖住你的主流程
2. **二进制缺失**要报错并提示安装，不降级
3. **坏 JSON / 非零退出**当成「拿不到报告」，和缺失同样处理
4. **不确定就是不确定**。`impact.uncertain: true`、`modeled: false` 的 `Exec`/`Spawn`
   都不是「没问题」，是需要你另想办法的地方

环境变量用 `PRESHELL_BIN` 之类的名字自己定，工具本身不读它——那是你封装的事。

## 读什么、别读什么

- `impact.effects` — 事实清单：
  - `Exec` — 跑了一个程序
  - `Read` / `Write` / `Delete` — 读了、写了、删了哪个路径
  - `Net` — 往哪去了网络
  - `Spawn` — **把控制权交给了另一个程序**：命令本身不决定会发生什么，
    而是在跑 `uv run`、`npx`、`poetry run`、`cargo run` 这类运行器时把命令行
    交给它。被交出去的那个程序碰什么，不在本工具的建模范围内（追下去等于把
    每门语言的生态都实现一遍），所以它只报出交接对象并置 `uncertain`。
    调用方可以把这类条目单独计数：它们是「你需要另想办法」而不是「什么都没发生」
  - `Unknown` — 有个洞（动态路径、没建模的程序、here-doc 正文之类）
- `impact.write_roots` — 会被改到的目录
- `impact.uncertain` — **先看这个**。true 表示这份影响面不是封闭集合
- `impact.cwd` — 这份报告里的路径是对着哪个基准解析的。路径本身已经是绝对路径，
  这个字段是给「基准对不对」用的：它是推演来的还是命令自己 `cd` 出来的，见上面「相对路径与 pwd」
- `status` — `Complete` / `Unsupported` / `Invalid`，描述我们看懂了多少

别把 `uncertain: false` 读成「安全」，也别把 `effects` 里没有 `Write` 读成「不写」——
先看有没有 `modeled: false` 的 `Exec` 或 `Spawn`：那是「有程序跑了，它碰什么我们不建模」。

拿到报告之后干什么，是另一个问题，见 [`example-policy.md`](example-policy.md)。

## 上线前检查单

- [ ] 二进制缺失、超时、JSON 坏了、退出码非 0：这四种的默认动作是「问人」不是放行
- [ ] `uncertain: true` 或存在 `modeled: false` 的 `Exec`/`Spawn` 时，你有对应动作
- [ ] 你没有把「`effects` 里没有 `Write`」读成「不写」
- [ ] 你按 `issues[].code` 分流警告，而不是匹配 `message` 文案
- [ ] 读了 `--version` 的 `schema` 并锁住解析形状；未知字段忽略，未知 `kind` 当
      `Unknown` 处理（这样工具出新版本不会把你的解析器打挂）
- [ ] 分发方式定了：用户自装（零义务）还是随包分发（GPLv3 §6 那四条义务）
- [ ] 传了 `--cwd`（绝对路径），或者接受报告里那条「基准是推演来的」的 `Note` 及 `uncertain`
- [ ] 命令是原样喂进去的，没有经过二次引用、二次展开
- [ ] 批量调用时：读到 EOF 就把未决请求全部判失败，另有超时兜底，绝不挂着等应答
- [ ] 批量且带 id 时：应答是信封，先取 `report`；有 `error` 就是那一行不是请求
- [ ] 你没有按「输出行数就是成功条数」去数：拒绝也占一行，一行输入一行输出
- [ ] 你没有把它当唯一闸门

## 在真实命令上的表现

上面那套语法语料只能回答「解析器对不对」。另一个问题更接近使用者：
在一台机器上真跑过的命令，这个工具好不好用。语料就用现有的会话记录
（`~/.pi/agent/sessions/**/*.jsonl`，里面记着 agent 实际执行过的命令），
量出来的结果如下：

| 语料 | 条数 | 读通 | 给出路径结论 | 我们的缺口 | 目标不像路径 |
|---|---|---|---|---|---|
| bash 命令 | 38250（去重） | 99% | 83% | 0 | 0 |
| sandbox-allow 请求 | 423 | 100% | 81% | 0 | 0 |

读不通的那几条，两条 shell （bash -n 与 zsh -n）也一并拒绝：命令本身就坏了，
工具报 Unsupported 是保守方向而不是漏报。

怎么复现：

```bash
tools/corpus/session_cases.py --n 800 --dump /tmp/real-cases
```

剩下那不到两成「只报 Exec」的，绝大多数是把脚本交给未建模的程序跑，
比如 `python3 <<'PY'` 这种。工具在这些场合的做法是**明说这是洞**：
Exec 上带 `modeled: false`，并把 `uncertain` 置真。对「审计指令」这个用途，
一个明说的洞比一个自信的错答案有用得多；那也正是你该去问人的地方。

会话记录是私人的：脚本只读入，报告只打命令首行与统计，不往仓库里写。

## 方言与 probe 模式

命令可能来自 bash 工具，也可能是 zsh 脚本。`--shell=S` 决定用哪套文法读输入：

- `auto`（默认）：按 shebang 选，没有 shebang 按 bash
- `bash` / `zsh`：钉死一套文法
- `probe`：先按输入自己声明的方言读，声明不了或读不通时再试 bash、zsh，
  取第一个 `status` 为 `Complete` 的结果

给一个工具不认识的 `--shell` 值会在启动时就报用法错误（退出码 2），
不会被悄悄当成 bash。

probe 的语义边界，调用方必须知道：

- **probe 成功不等于方言确定。** 同一段文本可能两套文法都能解析，但碰的东西不同：
  实测 `echo hi >! /tmp/out`，bash 写的是名为 `!` 的文件，zsh 写的是 `/tmp/out`。
  probe 只保证「找到一套读得通的文法」，不保证「这就是它的方言」
- 最后用了哪套文法写在 issue 里（`kind: "Note"`）。有两种情况会出现：
  一是回退到非声明的文法（或没有声明、bash 读不通而改用 zsh）；
  二是没有声明、bash 能读但 zsh 读出来的 effects 不一样。
  有这条 Note 时 `impact.uncertain` 为 true
- 输入自己声明了方言、又按那套方言读通时不加 Note：声明已经回答了问题
- 所有文法都不通过时，返回第一条（bash）的结果，`status` 保持 `Unsupported`，
  失败不会被包装成成功
- 目前只有 bash 和 zsh 两级，没有独立的 POSIX sh 文法：`sh`/`dash` 归到 bash，
  POSIX 差异由已有的 bashism Note 承担

报告的形状（`version` / `status` / `impact` / `issues`）没有变化，方言信息走 `issues`。

## 性能与状态

- 单次调用约 1ms（进程启动为主，解析 5µs）。一次审查一条命令，不需要常驻
- 工具无状态、不写任何文件、不读你的磁盘、不发网络请求，可以并发调用
- 不需要任何权限配置：它只读自己的 stdin
- 它**不执行**你交给它的命令。这是它唯一的输出，也是你敢把不可信文本喂给它的原因

## 批量：一个进程里分析多条

一次调用的成本几乎全在起进程，不在分析（实测：单条 1.12 ms，分析本身 5 µs）。
要跑成百上千条时用 `--stream`：stdin 每行一个 **JSON 字符串**（就是命令），
stdout 每行一份报告，顺序一致。

```bash
jq -Rc . commands.txt | preshell --stream > reports.jsonl
```

（命令里可能有换行（heredoc、多行循环），所以沿原始文本按行切是不行的，必须转义。
JSON 是本工具已经会说的那门话，所以用它。）

规则：

- **一行输入一行输出，严格一一对应。** 不是 JSON 字符串的行（包括空行）不会被
  悄悄跳过，而是给 `{"error":"…","line":N}`。静默跳过在调用方那里会变成
  错位一位，那是本工具最不该制造的那种错
- 拒绝对象**不带 `version` / `status`**，一眼能与报告区分：「你第 7 行不是 JSON」
  和「shell 会拒绝这条命令」是两回事
- 边报告边写出，不等 EOF：调用方可以保持进程存活，写一条读一条
- 退出码仍是 0（契约里退出码只描述工具自己）；坏行数量与逐行诊断在 stderr 上汇总
- 方言仍只用进程级 `--shell`；`--pretty`、`--scan`、`--shadow`、`--evidence`、
  `--bench` 与 `--stream` 互斥（它们会破坏「stdout 一行一个对象」这条）

### 带 id 的请求：多个 worker 共用一个子进程

默认形态一行请求一行应答，靠顺序对齐。父进程里如果有多个 worker 抢一个子进程，
或者只是不想让「应答配得上请求」这件事依赖顺序，就给请求带一个 id：

```
"rm -rf build"                          → 裸报告（与单条模式逐字节相同）
{"id": 17, "command": "rm -rf build"}   → {"id":17,"report":{…}}
{"id": "w3-91", "command": "echo hi"}   → {"id":"w3-91","report":{…}}
```

规则一句话：**应答回显请求的形态**。没 id 的请求拿裸报告，带 id 的请求拿信封，
报告原封不动放在 `report` 里。

- id 是任意 JSON 值，**原样回显**，不解析不改格式（数字回数字，字符串回字符串）。
  **用不可猜的随机值，不要自增**：管道如果被别的进程共享（见下「客户端这边要守住四条」），
  可猜的 id 意味着伪造的应答能顶掉真应答；随机 id 让这种情况只能表现为「无主的应答」
- 工具**不查重**：同一个 id 发两次就回两条。唯一性与重试去重都是调用方的事
- **拒绝也带 id**，只要那一行读得出来：`{"id":"w2","error":"…","line":3}`。
  这对 worker 池是关键——某个 worker 的请求被拒时，它得知道是它自己
- **不认识的键会被拒绝**而不是忽略：写了 `{"command":"ls","timeout":5}` 的人
  以为超时生效了，静默丢掉等于骗他
- id 不查重，唯一性是父进程的事

为什么不把 id 直接塞进报告里：报告是两种模式共用的同一个对象，塞进去会让
「同一条命令、两种模式、同一份报告」这条性质失效。信封是为了让报告本身一字不变。
id 带来的开销在噪声里（实测 ±1%）。

父进程必须处理两件事：

1. **应答不来**：子进程崩了/被杀 → 读到 EOF 就把所有未决请求判失败，再加超时兜底。
   绝不能挂着等某个 id 等到天荒地老
2. **拿不到应答 ≠ 什么都没碰**——这条立场在父进程侧同样成立

一个最小父进程（Node）：

```js
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

export function openAnalyzer(bin = "preshell", args = []) {
  const child = spawn(bin, ["--stream", ...args], { stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map();
  let buf = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buf += chunk;
    for (;;) {
      const nl = buf.indexOf("\n");
      if (nl < 0) break;
      const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
      const msg = JSON.parse(line);
      const settle = pending.get(msg.id);
      if (!settle) continue;                // 无主的应答：记下来，别当成功
      pending.delete(msg.id);
      settle(msg.error ? { error: msg.error, line: msg.line } : { report: msg.report });
    }
  });
  // 子进程没了：未决请求一起失败，绝不留在那儿等
  child.on("exit", (code) => {
    for (const settle of pending.values()) settle({ error: `analyzer exited (${code})` });
    pending.clear();
  });
  return {
    analyze(command, timeoutMs = 5000) {
      // 随机而不是自增：见「客户端这边要守住四条」第 3 条
      const id = randomUUID();
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          if (pending.delete(id)) resolve({ error: "timeout" });
        }, timeoutMs);
        pending.set(id, (r) => { clearTimeout(timer); resolve(r); });
        child.stdin.write(JSON.stringify({ id, command }) + "\n");
      });
    },
    close() { child.stdin.end(); },     // 优雅收工：让它答完未决请求
    kill() { child.kill("SIGKILL"); },  // 硬杀：未决请求立刻全部失败
  };
}
```

要更高吞吐就**再起几个子进程**（单个约 7700 条/秒），而不是加 socket 或做守护进程：
谁起的子进程谁喂，版本不会漂移，也没有「守护进程没在跑」这条新策略。

### 客户端这边要守住四条

工具是单线程的，一次答一条，内部没有共享状态——同一条命令在流式与单条模式下逐字节一致
（458 条实测），所以它这边不会出现并发问题。**并发是调用方的事**：要更快就多起几个进程，
别指望一个子进程扛多核。单进程吞吐大致 4 万条/秒（小微命令）到 7 千条/秒（真实脚本那种大小）。

调用方要守住这四条，缺哪条都可能拿到错的应答：

1. **对 stdin 的写必须串行。** 多个线程或协程直接写同一个 fd，行可能被夹断：POSIX 只保证
   ≤ `PIPE_BUF`（Linux 4096 字节）的写是原子的，更大的写规范上允许交错。Node 的
   `child.stdin.write` 是单一 stream、内部排队，天然安全；直接 `os.write(fd, …)` 不安全，
   要自己加锁。（我们实测没能复现夹断——CPython 的 GIL 会把 syscall 串行化，所以这属于
   「按规范可能」，不是「常见」。夹断的后果是响亮的：JSON 不合法，得到带行号的拒绝）
2. **读必须按 `\n` 缓冲。** 一次 `read` 未必正好一行（实测按 37 字节读会拿到半行），
   管道不会替你切分。上面示例里的 `buf` 累积就是这个用途
3. **id 必须不可猜**（随机，不要自增），理由见上一节
4. **别让别的子进程继承那根 fd。** 谁拿到写端谁就能投递请求，还能拖住 EOF 让调用方
   永远等不到收工。Python 的 `close_fds=True` 与 Node 的 libuv 默认都设 CLOEXEC
   （实测：两者的旁系子进程都拿不到 PreShell 的那两个管道 inode），自己漏 fd 才会中招

夹带能做到什么：最多让工具去分析一段别人选的文本，调用方得到一份没要的报告。工具不执行、
不读盘、不联网、不改状态，这一层是它的安全垫；带 id 时调用方还能把「无主的应答」认出来
（示例里那句 `if (!settle) continue` 就是干这个的，别把它当成成功）。

代价（本机实测）：

| | 每条 |
| --- | --- |
| 单条模式（含调用方起进程） | 1.12 ms |
| `--stream` | 0.116 ms |

45100 条命令：流式 5.2 s，单条模式约 50 s。注意 0.116 ms 里分析只占 5 µs，
其余是 JSON 编解码与写出：流式省掉的是**进程**，不是分析。

如果你跑的是一套差分 harness（每条命令还要起 oracle，比如 `bash -n`、`zsh -n`），
别指望流式能把总时间压掉一个量级：那里 oracle 才是大头（实测 `zsh -n` 每份 3.19 ms，
`bash -n` 1.35 ms，PreShell 0.95 ms），流式只把其中属于 PreShell 的那一份拿掉。

不做守护进程、不做 socket、不做库存调用：仍然是子进程，仍然走 stdin/stdout。
