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

基线（`ORACLE="zsh -n" tools/corpus/run.sh --list ...`）：

- 两边都通过：886
- 我们的缺口：353 ← 要啃的
- 我们太宽松：2
- 两边都报错：3
- 崩溃：0

那 2 个「太宽松」是 **oracle 的局限**，不是我们的漏判：`zsh -n` 不是纯语法检查，
它仍会做部分求值（`Functions/Example/randline` 报除零、`Functions/TCP/tcp_point` 报 fd 号）。
记在案，遇到时人工看。

## 四、切片清单（按实测缺口排序）

| # | 构造 | 例子 | 状态 |
|---|---|---|---|
| 1 | `} always { ... }` | `_call_program` `_main_complete` `_approximate` | **已做**（缺口 353→345）|
| 2 | glob 限定符与 zsh 词法 | `*(...)` `(N:P)` `(I)` `^` `<1->` `$^` | 待做，估计是最大一块 |
| 3 | `=(...)` 进程替换 | `zf_ln -fn =(<<<'') $tmp` | 待做。**注意：它会写临时文件**，effects 层要体现 |
| 4 | `{ [[ ... ]] \|\| ... }` 组命令 | `_expand` `_match` `_multi_parts` | 待做 |
| 5 | 数组下标带标志 | `$argv[(I)--]`、`${a[1,3]}` | 待做 |
| 6 | `${...}` 的 zsh 修饰 | `${^x}`、`${(f)x}`、`${x:#pat}` | 待做 |
| 7 | csh 风格循环 | `foreach x (...) ... end`、`repeat n { }` | 待做 |

先把 2 做完再看数字，因为词法这一刀会影响很多文件。

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

## 六、风险

- **选项依赖**：`setopt` 能改词法，和 bash 的 extglob 同类。按默认值假设是唯一可行解，
  但要把假设写进报告，不能让调用方以为这是 zsh 的全貌
- **`zsh -n` 不是纯语法 oracle**：它会做部分求值（见第三节），四象限里会出现假的
  「我们太宽松」，需要人工过一遍
- **无 shebang 的 zsh 代码**（补全系统全是这种，靠 `autoload` 加载）只能靠
  `--shell=zsh` 显式指定，或按语料场景默认；`auto` 判定在这里帮不上忙
- **完成系统的代码大量依赖运行时状态**（`$compstate` 之类），解析对了不等于审核得准，
  这一条属 effects 层的既有局限，与本计划无关但要一起说
