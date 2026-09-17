# shaudit 项目规约（给 agent）

静态 bash 指令审核器：只解析、不执行。主语言 MoonBit，native target。

## 目录

- `lib/` — 核心库（纯解析 + 判定，无副作用）
  - `ast.mbt` 语法树；`word.mbt` word 分类；`lexer.mbt` 词法；`parser.mbt` 递归下降
  - `audit.mbt` 规则引擎；`effects.mbt` 影响面提取；`status.mbt` 解析状态与对外 Report
- `cmd/shaudit/` — CLI，唯一会碰进程/环境的地方
- `tools/corpus/` — 与 `bash -n` 的差分证据生成器

## 三条不可退让的设计不变量

1. **`Invalid` 需要证据**。声称「bash 也会拒绝」是对一个没运行的程序下断言，判错就是放行。
   新原文只有在 `tools/corpus/run.sh` 显示它落在「两边都报错」象限、且在「我们的缺口」
   象限出现 0 次之后，才能加进 `corroborated_syntax_messages()`。默认一律 `Gap`。
2. **`risk: null` 是弃权，不是放行**。调用方拿到 null 应该转发 bash 自己的报错。
   任何把「反正跑不起来」当无害的推断都要挡掉。
3. **带洞的必须标出来**。`Param`/`CmdSub`/`Glob`/`Tilde` 一律 `dynamic: true`；
   `Unsupported` 状态下 `uncertain` 强制为 true。宁可让调用方多处理一个不确定，
   也不要给一个看起来干净的假集合。

## 改解析器时的顺序

1. 先加语料或最小复现（`tools/corpus/` 或 `*_test.mbt`），再改代码
2. `moon test --target native` 全绿
3. `tools/corpus/run.sh` 看四象限有没有移动，尤其是「我们太宽松」那一格
4. 改完跑 `moon fmt` + `moon check --target native`

## 已知缺口（P1 待啃）

- here-doc × 命令替换：`text=$(cat <<EOF ... EOF)` 里 here-doc 正文要在 `)` 处截断
- `here-doc 定界符` 里带命令替换：``cat <<EO`true`F``
- 数组下标里的引号：`foo=(["k"]=v)`、`myarray["a]a"]=x`
- `${}` 内的引号规则：`${x//"'"/y}`
- `[[ ]]` 里 `=~` 右侧的正则
- 嵌套进程替换：`$(< <(trap ...))`
- 模式开关：`shopt -s extglob` 会让 `+(a|b)` 从语法错变成合法。
  审核器必须显式声明假设（当前按已启用处理），并知道这是个分歧点

## 已知的「我们太宽松」

- `(` 出现在非命令位置时被当成 subshell 接受（`printf '%s\n' a=(a b)`、
  `switch foo in foo) ...`），bash 会拒绝。这是危险方向，优先修
- here-doc 数量超出 bash 上限（`exportfunc1.sub`）我们放行；属于 bash 实现限制，不打算追

## MoonBit 坑

项目里会撞到的语言级坑（`is` 右侧写变量会永远匹配、`unused_mut` 是 Error、
按码元切片 `s[a:b]` 静默改边界等）已合入 `clyzhi-moonwell-spring` skill 的
「静默错解」一节，动手前先读那一节。

## 边界

核心库保持纯函数：不读文件系统、不起子进程、不发网络请求。
`bash -n` 只在开发期由 `tools/corpus` 调用，不进 `lib/`。
