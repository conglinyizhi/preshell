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
  - `opts.mbt` 选项值语义表；`git.mbt` git 子命令实测表；`shell.mbt`/`bashism.mbt` 方言边界
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

## 已知缺口

**两套语料的缺口都是 0。**

bash 语料（451 个 .sub）：434 通过 / 0 缺口 / 3 太宽松（oracle 局限）/ 0 崩溃。
最后一个缺口 `func5` 的 `<(:) () { ... }` 是个把带进程替换的词当函数名的定义，
修法是函数名不必是普通词（三种 shell 实测都接受）。

zsh 语料（1244 个文件）：**1237 到 1239 通过 / 0 缺口 / 5 到 7 太宽松（同前）/ 0 崩溃**。
两种跑法差两个文件，因为受限沙箱里 `zsh -n` 会对带进程替换的文件 abort；缺口与崩溃
两栏是稳定的。从最初的 353 一路做到零，逐刀数字与实测规则在 docs/zsh-plan.md。

读取侧（35 条常见调用）**35 条都能给出路径结论**：find、sqlite3、make、docker 与
包管理器的分支在 lib/tools.mbt（容器挂载按只读与否分读写，找不到的报洞）。

## 刻意保留的取舍

这些是选择，不是待发现的 bug：

- **运行器（`uv run`、`npx`、`poetry run`、`cargo run` 之类）按交接单列**：报 `Spawn`
  并指出交接对象，`uncertain` 置真。追下去等于把每门语言的生态实现一遍，所以这是
  刻意划的边界：它们是「你需要另想办法」，而不是「什么都没发生」
- **`[[ ... ]]` 整块不透明**：只找到配对的 `]]`，条件文本留作方言判断，表达式本身
  不解析（里面的命令替换照常审计）。所以语法畸形的条件会读成 Complete，而实现
  条件语法本体不划算
- **实参位置的赋值保守拒绕**（`f x=1`）：bash 会真执行它，报「没解析出来」是安全方向
- **花括号与词粘连**（`f () {echo x}`）是长尾：zsh 的右花括号 pushback 已实现，
  但粘连写法在某些形状下仍报 Unsupported
- **没建模的程序必须自报**：报成 `modeled: false` 的 Exec 并强制 uncertain，
  下面的效果列表是下界。这条是「不做无界枚举」的前提
- **oracle 不是纯语法检查器**：`zsh -n` 会求值一部分内容（除零、fd 号、进程替换），
  语料文件是函数体而它按顶层脚本读。每条分歧都附 oracle 原文，由人判断
- **非 Linux 未验证**：只在 Linux 上跑过，macOS 的 shell 差异没有环境验证


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

## 差分模糊（第三件套之外的那一件）

tools/fuzz/differential.js 拿**真 shell 当 oracle**，检查两个方向：shell 接受、我们
拒绝（缺口），以及 shell 拒绝、我们报 Complete（**危险方向**）。种子是一份构造动物园，
变异是结构性的，所以变异体大多停在合法语法的近邻。

它的第一批产出就是 16 例「我们太宽松」，语料一格都看不见：`always` 在 bash 方言下也被
接受、`for i in a` 缺体、数组缺右括号、命令位置孤立的右花括号、`function` 缺体。
还有一处更值钱的：`coproc NAME { }` 以前是**用错的结构被接受**（`{` 被当成实参），
语料显示「两边都通过」其实是假象，修正后树才是对的。

用法：
  node tools/fuzz/differential.js --n 800 --seed 1          # bash
  node tools/fuzz/differential.js --shell zsh --n 600 --seed 1
每条失败都附 oracle 原文（oracle 本身有已知噪声，由人判断）。

已知还没修的一类：二元算符后面又跟一个算符（`cmd &&& x`、`2>>&1`），两个 shell 都拒，
我们接受。修法是在算符序列上做检查，属于下一个工作日。

## 编译警告保持为 0

`moon check --target native` 现在没有任何警告，别让它再攒起来。修的时候有个坑：
**报告的条数会少于实际处数**（实测 245 报了、实际 247；`implicit_impl_as_method`
先用 77 条报了 Eq，修完 Eq 才冒出 Debug 与 ToJson 的另外 49 与 21 条）。所以按
「修到 0」而不是「修到数字对上」来判。

- `derive` 带来的 `Eq` / `Debug` / `ToJson` 方法要显式写出，集中放在
  `lib/extends.mbt`（和上游 `core/*/extends.mbt` 一个写法）。漏一个就回来一条警告
- CI 不 gate 警告：它装最新工具链，上游加一条新警告就会把构建弄红，等于用别人的
  节奏卡自己。靠提交前跑 `tools/ci_local.py`，以及这里的「保持 0」

## 本地先跑一遍 CI

推送之前用 `tools/ci_local.py`。它直接读 `.github/workflows/check.yml` 执行那里面
的步骤，不在这里另抄一份：抄一份就有两处定义，改了一边忘另一边。只有 runner 上
才需要的两步（安装 MoonBit、moon update）按名字跳过。

```bash
tools/ci_local.py            # 全部
tools/ci_local.py 语料 模糊   # 只跑名字匹配的步骤
```

## 加固的四件套（每次改动都要过）

1. `moon test --target native` — 库内行为：逐命令语义、畸形输入、递归边界、输入规范化
2. `tools/corpus/run.sh` — 与 bash -n 的差分。默认语料是仓库里的
   `tools/corpus/bash-tests`（bash 5.3 的 tests/*.sub，GPL 出处见其 README），
   另外两种跑法：传目录指向解开的 bash 源码，或 `--list` 拿真实脚本。
   两栏必须盯：崩溃/超时为零、我们太宽松不新增
3. `tools/probe/malformed.sh` 与 `tools/fuzz/mutate.js` — 进程不许死。
   fuzzer 的 `--n`、`--seed` 可复现；它还会打印解析状态分布，
   用来确认变异体真的打到了解析器（全是进门即拒的话这个 fuzz 没有强度）
4. `tools/fuzz/differential.js` — 拿真 shell 当 oracle 的差分模糊，见上一节。
   它负责的方向是语料看不见的那个：shell 拒绕而我们报 Complete

zsh 侧的差分另有跑法：`ORACLE="zsh -n" PFLAGS="--shell=zsh"`，语料用
`tools/corpus/zsh_corpus.sh` 从 zsh 源码树的 Completion 与 Functions 采集。

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

## bash 侧记分牌（451 个 .sub）

**434 通过 / 0 缺口 / 3 太宽松 / 3 两边报错 / 0 崩溃**（会话开始时是 431/3/3/3/0）。

那 3 个「太宽松」全是 oracle 的问题，不是漏判，两个成因都要记住：

- `extglob4.sub`、`extglob6.sub` 需要 `shopt -s extglob`。它们本来就来自 bash 自己的
  测试套件，`bash -n` 不带该选项会拒，`bash -O extglob -n` 就通过。
- `exportfunc1.sub` 第 14 行有十个立即文档，撞上 bash 的立即文档数量上限
  （`超出最大立即文档计数`）。这是资源上限，不是语法规则。

## zsh 支持

按 zsh 语义解析 zsh，不是只报一句「没建模」。完整计划、侦察结论、切片清单在
docs/zsh-plan.md；这里只放记分牌和口径。**缺口已经到零。**

- CLI：`--shell=auto|bash|zsh|probe`（auto 按 shebang，无 shebang 默认 bash；
  probe 按「声明的方言 → bash → zsh」回退，最后用的方言用 Note 写进报告）、`--evidence`
- 审核层与方言无关，不重复实现；差异只在词法与语法，用 lib/dialect.mbt 的 Dialect 分派
- 语料是 zsh 源码树的真实代码：1244 文件、131822 行（Completion + Functions），
  采集脚本 tools/corpus/zsh_corpus.sh，oracle 用 `zsh -n`。注意这些文件没有 shebang，
  量的时候要显式 `PFLAGS=--shell=zsh`
- 基线 886/353 → 现在 **1237 到 1239 通过 / 0 缺口 / 5 到 7 太宽松 / 0 崩溃**
  （语料 1244 个文件，区间来自 oracle 的环境敏感，见上）。
  缺口逐刀下降：方言分派 353 → 词位置括号 284 → 右花括号 264 → 数字范围 256 →
  展开花括号 255 → 数组元素括号 181 → case 模式分组 50 → csh 循环 47 →
  `>!` 与 `>&` 45 → 匿名函数 26 → 命令位置的 `[[` 23 → 算术里的 `#` 21 →
  引号内的 `[[` 不再当关键字 17 → 子解析沿用方言 15 → 引号里的进程替换/glob 12 →
  if/while 花括号体 8 → 算术里每个括号都计数 5 → 右花括号 pushback 4 →
  function 匿名函数与 case 的 in 3 → 花括号展开里的引号 2 → 函数名不必是普通词 0
- 「太宽松」那 5 条全是 oracle 的局限，差分脚本现在会附上 oracle 原文以便当场判断。
  更根本的一条：语料文件是**函数体**（autoload/source 用），zsh -n 按顶层脚本解析，
  顶层没有位置参数，`$5` 这类引用会被判错；这个象限先怀疑 oracle
- 已实测几条 zsh 与 bash 的真实差异，都别靠直觉：
  1. `(` 在词的位置是模式分组，不是子 shell：zsh `echo (b)` 能跑（报 unknown file
     attribute），bash 是语法错。元字符判定看 `cmd_pos`，对应 zsh 的 `incmdpos`
  2. `}` 不需要前置分隔符：`{ echo a }` 在 zsh 里跑得动、在 bash 里是语法错
  3. `<1->` 是数字范围 glob 而不是重定向，词中任意位置都成立；没有配对的 `>` 才是重定向
  4. `${a//b/X{Y}/Z}` 里的花括号：zsh 不加引号时嵌套，双引号内不嵌套；bash 都不嵌套。
     两个真实文件各要一种规则，这不是可以糊过去的细节
  5. `name=(` 是数组、`=(cmd)` 是进程替换、`name==(cmd)` 是赋值加进程替换，
     三者要分开；数组元素里的 `(` 是模式
  6. case 模式是一个词：`(net|open)bsd*)` 里的括号是 glob 分组（zsh 的 `incasepat`），
     但分支体里它又是子 shell，所以这个状态必须读模式时置位、进分支体前清掉
  7. `;|` 是 zsh 的「继续测下一个模式」（对应 bash 的 `;;&`），而 zsh 不认 `;;&`
  8. zsh 的 `for` 允许多个循环变量，也有 csh 形态 `for x ( a b ) body`；
     `repeat N { body }` 的循环体必须真被审计，否则 `repeat 3 { rm -rf x }` 会漏报
  9. zsh 的 `>!` 等于 `>|`（写目标文件），bash 的 `>!` 是写名为 `!` 的文件；
     `>& 文件` 两个 shell 都写文件，非描述符的 dup 目标必须报 Write
 10. `[[` 在命令位置是关键字，在实参位置是 glob 括号；读错会让整条条件变成一个词，
     状态仍是 Complete——所以改词法后要抽查 effects，不能只看状态
 11. `(( ))` 里的 `#` 是操作数（zsh 里是字符码算子），不是注释；注释跳过只在算术外生效
- 已实测的两条 zsh 与 bash 的真实差异，都别靠直觉：
  1. `(` 在词的位置是模式分组，不是子 shell：zsh `echo (b)` 能跑（报 unknown file
     attribute），bash 是语法错。元字符判定看 `cmd_pos`，对应 zsh 的 `incmdpos`
  2. `}` 不需要前置分隔符：`{ echo a }` 在 zsh 里跑得动、在 bash 里是语法错，
     因为 zsh 把 `}` 当保留字记号，词中间也停词
- 已佐证语法错的表按方言分（syntax_evidence）：zsh 下为空，所以 zsh 解析不升级成 Invalid。
  同一条消息在 bash 下有证据不等于在 zsh 下也有，反例已经在语料里抓到
- `zsh -n` **不是纯语法 oracle**：它仍会做部分求值（除零、fd 号都会报），
  所以在「我们太宽松」那一栏出现条目时先怀疑 oracle
- zsh 有一批选项会改变解析（SHGLOB/KSHGLOB/IGNOREBRACES/RC_QUOTES/ALIASES/SHORTLOOPS...），
  按默认值假设并在报告中注明，这条和 bash 的 extglob 是同一类问题

## 定位失败时怎么查

- issue 带行号：`preshell --scan "$(cat f.sh)"` 每条都带 `(line N)`
- 差分给四象限和报错原文分布：`tools/corpus/run.sh`
- 按行二分对多行构造（here-doc、多行引号）会误导：用完整构造的切片，或直接看行号

## 流式模式（--stream）

- 形态：stdin 每行一个 JSON 字符串（命令），stdout 每行一份报告，顺序一致。
  命令可能含换行（heredoc），所以不能沿原始文本按行切，必须转义
- **严格一行一答**：不是 JSON 字符串的行（含空行）给 `{"error":…,"line":N}`，
  绝不静默跳过。静默跳过会让调用方的输入/输出 zip 出错位一位，那是本工具最不
  该制造的错。拒绝对象不带 `version`/`status`，一眼与报告区分
- **必须直写 stdout**：`println` 是块缓冲的，一条报告几百字节填不满缓冲，于是
  「流式」变成「批量」——写完第一条要等缓冲满或进程退出才看得见。流式路径走
  `@stdio.stdout.write`（async 的 Output 直写 fd），且不与 `println` 混用（混用
  还会乱序）
- 请求两种形态：裸 JSON 字符串，或 `{"id":…,"command":…}`。带 id 时**应答是信封**
  （`{"id":…,"report":…}`），报告本身一字不变——把 id 塞进报告会让「两种模式对同一
  条命令给出同一份报告」这条性质失效。拒绝也回显可读到的 id（worker 池需要知道
  是哪个请求被拒）；不认识的键拒绝而不是忽略
- 验收：`tools/probe/stream.sh`（真流式 + 裸形态逐字节等价 + 信封里的报告与单条
  模式一致 + 形态约定），lib 侧的帧逻辑
  在 `lib/stream_test.mbt`；两个工作流都跑这道
- 收益的量级要看调用方：只跑 preshell 的批处理快约 10 倍；差分 harness 里 oracle
  （`zsh -n` 3.19 ms/份、`bash -n` 1.35 ms）才是大头，流式只拿掉其中一份

## MoonBit 坑

项目里会撞到的语言级坑（`is` 右侧写变量会永远匹配、`unused_mut` 是 Error、
按码元切片 `s[a:b]` 静默改边界等）已合入 `clyzhi-moonwell-spring` skill 的
「静默错解」一节，动手前先读那一节。

另外本项目自己的教训：**别在 JS/node 脚本里拼带反引号的 MoonBit 代码做批量替换**，
转义会咬人；改动落成文件再拼。还有 `Array<T>` 是错的，MoonBit 是 `Array[T]`
（我在这个项目里写错三次）。
