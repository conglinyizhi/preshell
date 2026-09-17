# preshell 项目规约（给 agent）

shell 命令分析器：**只报告事实，不做判断**。主语言 MoonBit，native target。

## 这个工具是什么

输入一段 shell 命令，输出它**碰了什么**：跑了哪些程序、读/写/删了哪些路径、
什么出去了、哪里看不出来。输出里没有「允许/拒绝」。

「该不该跑」取决于调用方的上下文（哪个沙箱、哪个用户、哪个会话），不属于这里。
判断层的示例写在 `docs/example-policy.md`，那是**调用方侧**的代码。

交付形态是**独立工具**：别人起子进程读 JSON，不链接进来。GPL 因此停在进程边界上，
这也是不做成库的原因。所以对外契约是 **CLI + JSON schema**，不是 `pub fn` 的多少。

## 目录

- `lib/` — 核心库（纯函数：不读文件系统、不起子进程、不发网络请求）
  - `ast.mbt` 语法树；`word.mbt` word 分类；`lexer.mbt` 词法；`parser.mbt` 递归下降
  - `subscript.mbt` 数组下标；`cwd.mbt` 工作目录跟踪；`paths.mbt` 路径归一化
  - `effects.mbt` 影响面提取（对外的核心答案）；`facts.mbt` 命令分类等事实
  - `status.mbt` 解析状态与 Report
- `cmd/preshell/` — CLI：argv 或 stdin 进，JSON 出
- `tools/corpus/` — 与 `bash -n` 的差分证据生成器
- `docs/example-policy.md` — 调用方怎么用这份 JSON（不是本工具的一部分）

## 不可退让的约束

1. **只报事实，不下判断**。不引入 allowlist、不比较「沙箱根目录」、不输出
   allow/ask/deny。要判定就让调用方拿 JSON 自己判。
2. **带洞的必须标出来**。`Param`/`CmdSub`/`Glob`/`Tilde` 产生的目标一律
   `dynamic: true`；`Unsupported`/`Invalid` 状态下 `uncertain` 强制为 true。
   宁可让调用方多处理一个不确定，也不要给一个看起来干净的假集合。
3. **`Invalid` 需要证据**。声称「bash 也会拒绝」既是对没运行的程序下断言，
   又会被读成「反正跑不起来」= 无害。默认一律 `Gap`，只有
   `tools/corpus/run.sh` 证明它落在「两边都报错」象限且从未出现在「我们的缺口」
   象限时，才能加进 `corroborated_syntax_messages()`。
4. **不建模的程序要显式标出来**。每个 `Exec` 带 `modeled` 标志；未建模
   （git/node/make/python/docker…）一律驱动 `uncertain`。理由：枚举世界上所有程序的
   文件行为是无界工作，但「我们不建模它」是有界且必须可见的——沉默会被读成
   「什么都不做」。往 `is_path_modeled` / `is_pure` / `is_network_modeled`
   里加名字是在对那个程序的行为下断言，**拿不准就别加**（不加会落到未建模，是安全方向）。
   另外误报比漏报更伤信任：`grep PATTERN file`、`find . -name PATTERN` 的首个参数
   不是路径，这类要单独处理。
5. **相对路径要交代清楚**。
   影响面里必须是 `/tmp/x`，并在 `impact.cwd` 里说明基准；模型不出来就标 uncertain。
   作用域按 shell 走：子 shell、命令替换、多命令管道的每个元素各有一份。

5. **输入规范化必须和 shell 一致**。NUL 字节要丢弃并连接（bash 就是这么做的：
   `true\0; rm -rf /` 会真的执行 rm），绝不能截断——截断会给出「Complete、无副作用」
   的假报告。非法 UTF-8 有损解码并报 issue，不要让整次运行失败。
6. **递归要有上限，切片要夹紧**。实测：4 万层嵌套 `if` 会把 native 栈打爆（SIGSEGV）、
   输入 `((` 会因为倒置的切片区间 abort（SIGABRT）。现在有 `max_nesting`（1024）、
   `max_issues`（64）、`max_effects`（4096），截断必须用 `*_dropped` 明说并强制
   `uncertain`。同理：任何从 token 记账推出的区间都可能是倒置的，`Lexer::slice` 夹住它。
7. **误报比漏报更伤信任**。`grep PATTERN`、`find -name PATTERN`、`(( (a) + (b) ))`
   这类「首个操作数不是路径」「括号要整体配平」的规则，写错了就会凭空造出事实。

## 改代码时的顺序

1. 先加语料或最小复现（`tools/corpus/` 或 `*_test.mbt`），再改
2. `moon test --target native` 全绿
3. `tools/corpus/run.sh` 看四象限有没有移动，**尤其是「我们太宽松」那一格**
4. `moon fmt` + `moon check --target native`

收紧语法规则时默认会让缺口变大：实测一次过度修正让缺口从 12 涨到 81。
所以改完必须同时看两个格子，并把合法写法钉进回归护栏。

## 已知缺口（5 个文件）

已完成：分隔符规则、声明类内建赋值、命令词前重定向、数组下标（含引号）、
复合命令重定向、空命令、嵌套算术、here-doc × 命令替换、未闭合构造、
`<<-` 定界符去 tab、工作目录跟踪。

仍然缺的（都是边角）：`comsub-posix6`、`extglob8`（模式开关）、`func5`、
`posix2syntax`、`vredir2`。

## 「我们太宽松」那一格：3 个，全是 oracle 局限

- `extglob4.sub` / `extglob6.sub`：`echo @(?.|.?)` 这类模式在 `shopt -s extglob`
  下合法，而 `bash -n` 不执行 shopt 所以它拒。这是 oracle 的局限
- `exportfunc1.sub`：超过 bash 的 here-doc 数量上限（bash 实现限制）

## 真实脚本语料（第一步加固）

`tools/corpus/find_scripts.sh` 采集机器上真实脚本，`run.sh --list` 拿它们做差分。
实测 1384 个文件（/usr/bin /usr/share /etc /opt + 本仓库）：

- 两边都通过 1326（95.8%）
- 我们的缺口 29
- 我们太宽松 6，全部已归类：2 个是 polyglot（\`#!/bin/sh\` 开头、正文是 Scheme，
  bash -n 拒是因为它把整文件当 shell），4 个是 extglob（bash -n 不执行 shopt）
- 崩溃/超时 0

差分脚本必须用 stdin 喂文件，不能用 argv：libtool、configure 这类几百 KB 的脚本
会撞 ARG_MAX，看起来像崩溃其实是 E2BIG。这条踩过一次。

## 真实语料的首要缺口：相邻括号被错误合并（已修）

`arr=($(echo a))`、`echo "$(a $(b))"`、`case x in *) echo "($(date))";; esac` 曾经全部失败，
根因是词法器把相邻的括号**无条件**合并成一个 token，命令替换因此找不到自己的闭括号。

已修：词法器不合并 `((` 与 `))`，改由解析器用 `next_is_adjacent` 在算术命令与
`for ((...))` 头部按相邻位置识别，算术表达式按括号总数配平。真实语料缺口 29 降到 12、
bash 语法语料 5 降到 3。教训：`((`/`))` 只在算术上下文里才有意义，词法器不该替解析器
做这个判断。
缺口报错的大头（40 条 unexpected token after command、14 条 command substitution）。

## 方言判断：分两级，用真 POSIX sh 对齐

`#!/bin/sh` 或 `#!/bin/dash` 的脚本，我们自己判断「用了 bash 专有语法」。这个判断
**分两级**，因为 POSIX sh 的失败方式有两种（每条都拿 `dash -n` 实测过）：

- **解析期被拒绝**：数组赋值、`<<<`、`<( )`、`function` 关键字。说「在那个 shell 下
  跑不起来」是准确的
- **能解析但语义不同**：`[[ ]]`（dash 眼里是个叫 `[[` 的命令）、`(( ))`（dash 眼里是
  两层子 shell）。**不能说它跑不起来**，只能说行为不一样

这条区分踩过一次坑：先前一律说「would not run」，对 `[[ ]]` 是过强的断言，
`/usr/share/sddm/scripts/Xsession` 这类多 shell 脚本因此被误判成方言冲突。

对齐用的工具是 `tools/corpus/posix_oracle.sh`，oracle 取 `$SH_ORACLE`、否则 dash、
否则 busybox ash。1128 个声明 sh/dash 的系统脚本实测（dash 为 oracle）：

- 一致（我们的解析期断言成立）：3
- 误报：**0**
- 漏报：**0**
- 两边都拒绝（我们也没解析成功，不算漏报）：21
- 疑似 polyglot（正文是 Perl/Tcl/二进制）：2
- 一致放行：1102
- 我们标注了语义差异（`-n` 测不了）：5

结论：断言保守（无误报），但**归因粗糙**——21 个文件我们报了问题，但没说清是方言
问题。想更准就得按这些样本逐个补规则。

这个脚本自己也踩了三个坑（都写在这里，因为它们是「测量工具错了而不是被测对象错了」）：

- `(sh|dash)` 会把 `#!/usr/bin/env bash` 也配进来，因为 bash 里含 sh
- 输出管到 `head` 会让脚本吃 SIGPIPE 提前死，摘要在末尾读不到
- 计数器与临时文件路径混用一个变量名，bash 算术报错会终止整个循环

## 加固的三件套（每次改动都要过）

1. `moon test --target native` — 库内行为：逐命令语义、畸形输入、递归边界、输入规范化
2. `tools/corpus/run.sh` — 与 bash -n 的差分。默认语料是仓库里的
   `tools/corpus/bash-tests`（bash 5.3 的 tests/*.sub，GPL 出处见其 README），
   另外两种跑法：传目录指向解开的 bash 源码，或 `--list` 拿真实脚本。
   两栏必须盯：崩溃/超时为零、我们太宽松不新增
3. `tools/probe/malformed.sh` 与 `tools/fuzz/mutate.js` — 进程不许死。
   fuzzer 的 `--n`、`--seed` 可复现；它还会打印解析状态分布，
   用来确认变异体真的打到了解析器（全是进门即拒的话这个 fuzz 没有强度）

三件套都在 `.github/workflows/check.yml` 里，提交即跑。CI 不依赖网络：语料随仓库分发。

## shell 边界（第二步加固的产物）

工具解析的是 **bash 语义**，输入声明了别的 shell 时会说出来，不装作没看见：

- `#!/bin/sh` 或 `#!/bin/dash` 用了 bash 专有语法（数组、`[[ ]]`、`(( ))`、`<<<`、
  `<( )`、`function` 关键字）：加一条 `Note` 并强制 `uncertain`。这类脚本按声明
  在 dash 下跑不起来，但**解析是成功的**，所以 `status` 保持 `Complete`
- 完全没建模的 shell（zsh、fish、python…）：报 `Unsupported`，因为被解析的文法
  不是它那一套

这条区别很重要：`Note` 不改 `status`。把方言不符算成解析缺口，会让「缺口」这个
指标失去意义（实测一次把真实语料缺口从 12 冲到 214）。

`sh`/`dash`/`bash` 视为已建模集合，POSIX 脚本不产生噪音。判断依据是 shebang
本身，不是猜的：`declared_shell` 认 `#!/usr/bin/env X` 形式，也会剥掉 `-e` 这类参数。

## 定位失败时怎么查

- issue 带行号：`preshell --scan "$(cat f.sh)"` 每条都带 `(line N)`
- 差分给四象限和报错原文分布：`tools/corpus/run.sh`
- 按行二分对多行构造（here-doc、多行引号）会误导：用完整构造的切片，或直接看行号

## MoonBit 坑

项目里会撞到的语言级坑（`is` 右侧写变量会永远匹配、`unused_mut` 是 Error、
按码元切片 `s[a:b]` 静默改边界等）已合入 `clyzhi-moonwell-spring` skill 的
「静默错解」一节，动手前先读那一节。

另外本项目自己的教训：**别在 JS/node 脚本里拼带反引号的 MoonBit 代码做批量替换**，
转义会咬人；改动落成文件再拼。还有 `Array<T>` 是错的，MoonBit 是 `Array[T]`
（我在这个项目里写错三次）。
