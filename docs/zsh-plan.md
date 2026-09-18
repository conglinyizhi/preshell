# zsh 支持计划

目标：**按 zsh 语义解析 zsh**，不是遇到 `#!/bin/zsh` 就报一句「没建模」。

## 一、口径（先说清什么算「完美」）

- 审核层（effects / paths / facts）**与方言无关**，不重复实现。命令是什么、碰了哪些文件，
  这一点 bash 与 zsh 是一样的
- 方言差异只落在**词法与语法**：`Dialect { Bash, Zsh }`，CLI 用 `--shell=auto|bash|zsh`，
  `auto` 按 shebang 判定，无 shebang 默认 bash
- 「完美」的口径是**记分牌**：拿 `zsh -n` 当 oracle，在 131,822 行真实 zsh 代码上算四象限。
  目标是把「我们的缺口」压到零，并保证「我们太宽松」不增加

## 二、侦察结论（zsh 5.9.2 源码实测）

- 解析器是**手写递归下降**：`Src/parse.c` 4059 行（`par_cmd` / `par_pline` / `par_sublist` /
  `par_if` / `par_for` / `par_case` / `par_while` / `par_repeat` / `par_subsh` / `par_funcdef` /
  `par_dinbrack` / `par_simple` / `par_redir`），`Src/lex.c` 2234 行。**没有 yacc**，
  结构上比 bash 的 `parse.y` 更接近现有实现，重写不用跟着生成的 LALR 表走
- 保留字表与 bash 不同：`{ } case coproc declare do done elif else end esac export float for
  foreach function if integer local nocorrect readonly repeat select then time typeset until while`
  （多了 `foreach` / `end`（csh 风格）、`repeat`、`nocorrect`；`declare/export/integer/float/local/
  readonly/typeset` 都归 TYPESET）
- **有一批选项会改变解析**（`isset(...)` 出现在 lex.c/parse.c）：
  `SHGLOB` `KSHGLOB` `IGNOREBRACES` `RC_QUOTES` `CSHJUNKIEQUOTES` `CSHJUNKIELOOPS`
  `ALIASESOPT` `ALIASFUNCDEF` `POSIXALIASES` `SHORTLOOPS` `SHORTREPEAT` `MULTIFUNCDEF`
  `INTERACTIVECOMMENTS` `SHINSTDIN` `KSHAUTOLOAD` `HISTALLOWCLOBBER`
  这是 bash 侧 extglob 问题的放大版：**无法从文本知道运行时的 setopt 状态**
- 处理办法照 bash 侧的成例：按 **zsh 默认值**假设，并在输入里出现
  `setopt` / `unsetopt` 时会改变解析的选项时加 Note + `uncertain`

## 三、语料与基线

语料（`tools/corpus/zsh_corpus.sh` 采集，来自 zsh 源码树）：
`Completion/` 1043 文件 111,445 行 + `Functions/` 265 文件 20,377 行 = **1244 文件 131,822 行
真实 zsh 代码**（不是测试片段）。

基线演进（`ORACLE="zsh -n" PFLAGS="--shell=zsh" tools/corpus/run.sh --list ...`）：

| 阶段 | 两边通过 | 我们的缺口 | 太宽松 | 两边报错 | 崩溃 |
|---|---|---|---|---|---|
| 起点（按 bash 解析） | 886 | 353 | 2 | 3 | 0 |
| 方言分派 + `always` | 894 | 345 | 2 | 3 | 0 |
| 词位置的 `(` 归入词 | 955 | 284 | 2 | 3 | 0 |
| `}` 不需要前置分隔符 | 975 | 264 | 2 | 3 | 0 |
| 数字范围 glob `<1->` | 983 | 256 | 2 | 3 | 0 |
| 展开里的花括号规则 | 984 | 255 | 2 | 3 | 0 |
| 数组元素里的括号 | 1058 | 181 | 2 | 3 | 0 |
| case 模式分组、多循环变量、`;|` | 1189 | 50 | 5 | 3 | 0 |
| csh 风格 `for` 与 `repeat` | 1192 | 47 | 5 | 3 | 0 |
| `>!` 重定向变体与 `>& 文件` | 1194 | 45 | 5 | 3 | 0 |
| 匿名函数 `() { body }` | 1213 | 26 | 5 | 3 | 0 |
| 命令位置的 `[[` 是关键字 | 1216 | 23 | 5 | 3 | 0 |
| 算术里的 `#` 是操作数 | 1218 | 21 | 5 | 3 | 0 |
| 引号内的 `[[` 不是关键字 | 1222 | 17 | 5 | 3 | 0 |
| 子解析沿用方言（反引号/下标/eval） | 1224 | 15 | 5 | 3 | 0 |
| 引号内的进程替换与 glob 是字面量 | 1227 | 12 | 5 | 3 | 0 |
| if/while 花括号体 | 1231 | 8 | 5 | 3 | 0 |
| 算术里的每个括号都计数 | 1234 | 5 | 5 | 3 | 0 |
| 右花括号的 pushback | **1235** | **4** | 5 | 3 | 0 |

那 5 个「太宽松」全是 **oracle 的局限**，差分脚本现在会把 oracle 的原文一并打出来
（`zsh -n` 会做部分求值：除零、fd 号、`${(P)x::=}` 的间接赋值、`eval` 的字面量都算）。
更根本的一条：**语料里的文件是函数体**（`autoload`/`source` 用），`zsh -n file` 按顶层脚本
解析，顶层没有位置参数，于是 `$5` 这类引用被判错。这个象限的条目要先怀疑 oracle，再怀疑自己。

早期那 2 个「太宽松」是 **oracle 的局限**，不是我们的漏判：`zsh -n` 不是纯语法检查，
它仍会做部分求值（`Functions/Example/randline` 报除零、`Functions/TCP/tcp_point` 报 fd 号）。
记在案，遇到时人工看。

## 四、切片清单（按实测缺口排序）

| # | 构造 | 例子 | 状态 |
|---|---|---|---|
| 1 | `} always { ... }` | `_call_program` `_main_complete` `_approximate` | **已做**（缺口 353→345）|
| 2 | 词位置的 `(` 是模式分组 | `echo *(.)` `a(b)` `(a\|b)` `(#i)x` | **已做**（缺口 345→284）|
| 3 | `}` 不需要前置分隔符 | `{ echo a }`、`{ y \|\| z }; then` | **已做**（缺口 284→264）|
| 4 | `=(...)` 进程替换 | `zf_ln -fn =(<<<'') $tmp` | **已做**，报一条 Write 且标 uncertain |
| 5 | case 模式里的 `<1->` 数字范围 | `(<1->\|\*) amap[1]="$1";;` | **已做** |
| 6 | `${x//[^\\}]/}` 这类展开 | 花括号是否嵌套按方言与引号分 | **已做** |
| 7 | 数组元素里的括号 | `argv+=( (a\|b) )`，127 个文件 | **已做**（缺口 255→181）|
| 8 | 数组下标带标志 | `$argv[(I)--]`、`${a[1,3]}` | **已做**（词法与展开扫描覆盖后自动可用）|
| 9 | `${...}` 的 zsh 修饰 | `${(f)x}`、`${(s<,>)y}`、`${(P)n}` | **已做**（同上）|
| 10 | csh 风格循环 | `for x ( ... )`、`repeat n { }` | **已做**（循环体现在真的被审计）|
| 11 | case 模式里的括号分组 | `(net\|open)bsd*)`、`(un\|)install)` | **已做**（zsh 的 `incasepat`）|
| 12 | `;|` 终止符与多循环变量 | `for a b in x y` | **已做** |
| 13 | 匿名函数 | `() { body } arg...`，19 个文件 | **已做** |
| 14 | `>!` 等 clobber 变体与 `>& 文件` | 表外漏报，见下 | **已做** |
| 15 | 命令位置的 `[[` 被当 glob 括号 | `if [[ "$x" == a ]] then` | **已做** |
| 16 | 算术里的 `#` | `(( #x == 97 ))`、`(( 1 + 2 # c ))` | **已做** |

先把 2 做完再看数字，因为词法这一刀会影响很多文件。

## 四之二、已落地的结构改动

- `lib/dialect.mbt`：`Dialect { Bash, Zsh }` 与 `Dialect::from_shell_name`
- `Lexer` 多了两个字段：`dialect` 与 `cmd_pos`（对应 zsh 的 `incmdpos`）。`next()` 里按
  「词法单元是否可能开启一条命令」维护它，`(` 是否元字符就看这个加方言
- `read_parts` 里带一个括号深度 `pct`：组内的括号并进词、空格不断词、`|` 不断词，
  `;` `&` `<` `>` 换行照断。测出来的是这些，不是猜的
- 模式分组按 `Glob` 词元记账，不按字面量：否则 `rm (a|b)` 会报成删除一个叫 `(a|b)` 的文件
- 解析器里 zsh 分支：`}` 在词中间也停止取词（zsh 把 `}` 当保留字记号）
- 已佐证语法错的表按方言分：zsh 下为空，所以 zsh 解析不会升级成 `Invalid`
- CLI 新增 `--shell=auto|bash|zsh` 与 `--evidence`（后者给差分脚本读证据表，不再 grep 源码）

## 五、工作量估计（以 bash 侧为基准）

bash 侧现有：lexer 895 行 + parser 738 行，是整个项目的大头。zsh 侧按侦察结论估：

| 模块 | 估计 |
|---|---|
| 方言分派与 CLI（不改审核层） | 150–250 行 |
| zsh 词法（引号/展开/数组/glob 限定符/进程替换三种） | 1100–1500 行 |
| zsh 语法（递归下降，构造比 bash 少但形态不同） | 600–900 行 |
| 选项假设与 Note | 120–200 行 |
| effects 层的 zsh 增量（`=( )` 的临时文件等） | 100–200 行 |
| **合计** | **约 2100–3000 行**，另加大量语料驱动的回归 |

## 四之三、两类「表外」缺陷

语料四象限只看得到「我们拒绝而 shell 接受」。有两类问题它在结构上看不见，得靠手工探：

1. **报错方向**：`echo a >! out` 在 zsh 里写 `out`，我们曾报成写一个叫 `!` 的文件。
   `zsh -n` 通过、我们也报 Complete，于是四象限表里什么异常都没有。
2. **整段被吞**：`repeat 3 { rm -rf /tmp/x }` 曾只报一个 `Exec: repeat`，循环体完全没审计到；
   `[[` 被当成 glob 括号时，整条条件变成一个词（状态仍是 Complete）。状态码看不出这类问题。

所以每次动词法/语法，除了看两套语料，还要抽查**效果表**本身：拿几个真实构造看
effects 与 roots 是否符合预期。

## 五之二、oracle 的环境敏感性与噪声底

`zsh -n` 不是纯语法检查。它会在解析期做一部分求值，于是同一份代码在不同环境下
可以给出不同判定，而这些判定与语法无关：

- `=( )` 要在临时目录下建文件。受限环境里会失败：先是
  `process substitution failed: 权限不够`，接着 zsh 自己 `free(): invalid pointer`
  崩掉（SIGABRT）。`Functions/Calendar/calendar` 第 258 行就是这个形态。
- 除零、fd 号、`${(P)x::=}` 的间接赋值、`eval` 里的字面量都会被报出来
  （`randline`、`tcp_point`、`_pick_variant`、`regexp-replace`）。
- 语料里的文件是**函数体**（`autoload` 与 `source` 用），而 `zsh -n 文件` 按顶层
  脚本解析。顶层没有位置参数，于是 `$5` 这类引用被判错——`regexp-replace` 第 91 行
  就是这条。把那段单独放进函数里跑，zsh 是接受的。

同一个提交、同一台机器，两次运行的记分牌可以差一两个文件（授权不同的 sandbox 里
实测到 1192 通过、47 缺口、5 太宽松 与 1191 通过、46 缺口、6 太宽松两种）。所以：

- 「我们太宽松」这一栏先怀疑 oracle，差分脚本会把 oracle 的原文一并打出来
- 改动前后必须用 `tools/corpus/snapshot.sh` 做全量状态对比，不能只看总数
- 只有我们自己解析器的判定才是稳定的那一半

## 四之四、并行调查查到的静默漏报（已修一部分）

大规模实测（37 个程序、76 条调用，用 LD_PRELOAD 拦截 + 文件系统前后快照）暴露出
一批「状态是 Complete、uncertain 是 false、效果表却是空的」的漏报。已修：

- `[[ -f "$(cat secret.txt)" ]]` 原来一条效果都没有。`Cond` 现在带上条件内部的命令替换
  并照常审计。这是最严重的一条：调用方会把它读成「什么都不做」。
- 命令位置的 `do`/`done`/`then`/`fi` 原来被当成命令，而两个 shell 都拒绝这些写法。

尚未修、已经定位的同类（按严重度）：

- `repeat N; do body; done` 曾经丢循环体（已修）。同类还有 `$${x<y}` 报假 `Read y}`
  与 `echo "<(a)"` 报假进程替换效果。
- `gunzip` 在 `is_path_modeled` 里却没有任何 classify 分支：报 Complete、uncertain=false、
  零效果，而它实际解压写文件并删源。
- `grep --file=`、`chmod --reference=`、`tar --create --file=` 三种「连操作数都没识别」的写法。
- 选项值语义整体缺失：`sort -o`、`cp -t`、`mv -t`、`install -t`、`sed -f`、`awk -f`
  等把值当成普通操作数，同时造成漏报与误报。**已修**：`lib/opts.mbt` 一张表 + 三种
  写法（短选项、连写、`--long=值`），值按读路径/写路径/非路径/目标目录分流；
  `-t DIR` 的目标按 basename 拼进目录。压缩器的 `-c` 归入只读。
- 还没做进表的：tar 的档案名与模式字母、压缩器的产物名推导（`gzip f.txt` 实际写
  `f.txt.gz`）、`cp -S/--backup` 的备份文件、`unzip -d`、`curl -o`、`dd of=`。

## 四之六、算术括号：两个计数器不一致（家族 C 的根因）

`(( a + (b > c) ))` 被拒的原因**不是** `>` 被当重定向（那是无害的，实测 effects=0）。
真因是两个括号计数器读的东西不一样：

- `Lexer::is_arith_at` 读**原文**数括号（引号与转义都跳过），是对的。解析器靠它决定「这是算术」。
- 解析器 `((` 分支的深度循环按 **token** 数 `TOp("(")`/`TOp(")")`。而 zsh 方言下 `read_parts` 会把
  `+` 后面的 `(` 收成模式分组（`cmd_pos=false`），一旦这个组在 `; & < >` 前被截断，
  `(` 就永远没变成 token → token 计数少一层 → 提前闭合 → 尾部多出一个 `)` → 报错。

修法：`in_arith` 期间不让 `(` 走模式分组（一行），并给 `for ((...))` 的头部也设上这个状态
（那里有第二个同样的深度循环，原先没设）。两个 shell 都不 token 化算术正文：
zsh 是 `cmd_or_math` 抓原文交给 math.c，bash 是 `parse_dparen`。

教训：**同一个结构有两个来源的计数时，先看它们是不是读同一份东西。**

## 四之五、家族 B（if/while 的花括号体）的实测规则与卡点

规则已经量死，照抄即可。zsh 的判据是 `incmdpos`：**分隔符之后、复合命令之后、赋值命令之后**
处于命令位置，普通词之后不是。

- 接受：`if [[ x ]] { : }`、`if (( 1 )) { : }`、`if x=1 { : }`、`while (true) { : }`、
  `while { true } {}`、`while true; { : }`、`for i in a; { : }`、`for x (a b) { : }`
- 拒绝（zsh 自己也拒，实现时不能放进来）：`if true { : }`、`while true { : }`、
  `until false { : }`、`for i in a { : }`

卡点（两次尝试都在这里翻车，记下来免得重走）：

- 不能简单把 `{` 加进 if/while 条件的停止词：`while { true } {}` 的第一个 `{` 是条件的
  开头，会被当成停止词而把条件清空。
- 也不能只在条件序列解析完之后判断：序列循环会在判断之前就把下一个 `{` 当命令吃掉
  （`parse_pipeline` 已经把它解成 Group），而且它与 token 预取（`la`）交互后，
  `parse_if`/`parse_loop` 里看到的 `cur` 未必还是那个 `{`。
- `for` 还有一处独立细节：`in` 的词表会把单独的 `{` 当词收进去，得先在那里停住，
  否则 `for i in a { : }` 会被静默当成完整命令。
- 建议的实现路子：给 `parse_seq_in` 加一个「命令位置上的 `{` 就停下并留给调用者」的
  显式开关，由 if/while/until 的调用点打开，而不是让序列循环自己猜。

## 四之七、右花括号的 pushback（已做）

zsh 词法器在词尾遇到未配对的 `}` 会把它退回重读（`Src/lex.c` 里那段标注为
「hack to get {foo} command syntax work」的代码），判据是词内 `bct` 是否配平。
我们没有这条规则时，四个方向都有偏差，现在都对了：

| 输入 | 修前 | 修后 | zsh |
|---|---|---|---|
| `echo {a,b}` | Unsupported | Complete | 接受 |
| `echo a}` | Complete | Unsupported | 拒绝 |
| `f () {echo x}` | Unsupported | Complete | 接受 |
| `echo $${x<y}` | 假 Read y} | Unknown（保守）| 输出字面量 |

顺带一条：zsh 里重定向的目标不算命令位置（`<{a,b}` 是展开而不是组），这条也照着实测改了。
护栏：`for i in {1..3}`、`a=({1..3})`、引号内的 `"{a,b}"`、`case x in {a,b})` 都进测试。

已知残留（不在语料里，方向保守）：bash 方言下 `f () {echo x}` 我们报 Complete 而 bash 拒绝，
这是这条规则之前就有的小过松。

## 六、风险

- **选项依赖**：`setopt` 能改词法，和 bash 的 extglob 同类。按默认值假设是唯一可行解，
  但要把假设写进报告，不能让调用方以为这是 zsh 的全貌
- **`zsh -n` 不是纯语法 oracle**：它会做部分求值（见第三节），四象限里会出现假的
  「我们太宽松」，需要人工过一遍
- **无 shebang 的 zsh 代码**（补全系统全是这种，靠 `autoload` 加载）只能靠
  `--shell=zsh` 显式指定，或按语料场景默认；`auto` 判定在这里帮不上忙
- **两个 shell 的差异要靠实测**：`echo (b)` 在 zsh 里是「模式 + 限定符」，在 bash 里是语法错；
  `{ echo a }` 在 zsh 里跑得动，在 bash 里也报错。这类的判定不能靠读文档，只能对着两个 shell 跑
- **完成系统的代码大量依赖运行时状态**（`$compstate` 之类），解析对了不等于审核得准，
  这一条属 effects 层的既有局限，与本计划无关但要一起说
