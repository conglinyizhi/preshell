# shaudit

静态 bash 指令审核器。**只解析，不执行。**

给一段 bash 命令文本，它回答两件事：

- 这段命令**会做什么**：启动了哪些程序、读写删除哪些路径、连了哪里
- 这段命令**该不该放行**：按策略给出 Allow / Ask / Deny

它不运行命令，不发网络请求，不读文件内容。用完即走，单条命令微秒级。

## 它明确不是

- **不是沙箱**。它不拦任何东西，只给判断。真正的护栏在执行侧。
- **不是 linter**。它不关心代码风格，只关心影响面。
- **不保证 100% 保真**。bash 的语义里有一部分静态不可判定（`eval $X`、
  `$CMD`、`base64 -d | sh`）。对这部分它的回答是「不知道」，不是猜。

## 三种结果状态，先看状态再看判决

```text
status: Complete     解析到底，下面的 risk 有效
status: Unsupported  这是合法 bash，但本解析器还没覆盖；审计不完整，risk 最低为 Ask
status: Invalid      有证据说明 bash 自己也会拒绝；risk 为 null，我们弃权
```

`risk: null` 是**弃权**，不是放行。解析不了的东西没被审计过，调用方应该把 bash
自己的报错转出去，而不是把「反正跑不起来」当成无害——正是这个推断被设计成不可用。

`Unsupported` 走保守下限：一棵残缺的语法树不允许给出 Allow。

## 用法

```bash
shaudit 'rm -rf /'                 # 完整报告（JSON）
shaudit --impact 'make -j8'        # 只要影响面
shaudit --shadow 'cat <<EOF'       # 打印语法树
shaudit --scan "$(cat script.sh)"  # 一行：解析状态 + 问题数
shaudit --bench=2000               # 压测
```

报告形状：

```json
{
  "status": "Complete",
  "risk": "Ask",
  "findings": [{"rule": "write-outside", "risk": "Ask", "detail": "…", "line": 1}],
  "issues": [],
  "impact": {
    "effects": [{"kind": "Write", "target": "/etc/motd", "dynamic": false, "line": 1}],
    "write_roots": ["/etc"],
    "uncertain": false
  }
}
```

`dynamic` 和 `uncertain` 不是噪音，是这套东西唯一能保证诚实的地方：`$DIR/*.log`
这种带洞的目标，只能标成「不确定集合」，不能给一个看起来干净的假集合。
调用方信任这个 JSON 之前，先看这两个字段。

## 证据而不是品味

`Invalid` 这个状态是有门槛的：声称「bash 也会拒绝」等于对一个我们没运行的程序下断言，
判错就意味着放行一条真能执行的命令。所以它需要证据，证据来自差分：

```bash
tools/corpus/run.sh [bash 源码 tests 目录]
```

把本解析器与 `bash -n` 在 bash 自带语法语料上逐文件对比，产出四象限表，并强制一条不变量：

> 凡是被 `lib/status.mbt` 列为已佐证的报错原文，在「我们的缺口」象限必须出现 0 次。

这条不变量已经被实测打脸过一次：`unterminated here-document` 同时出现在两个象限，
所以它**不能**按原文升级——同一个文件里，bash 能解析而我们报错的情形是存在的。
按语义猜哪条能升级，正是这套装置存在的意义所反对的做法。

## 构建与测试

```bash
moon test --target native          # 单元测试
moon build --release --target native
moon fmt && moon check --target native
```

## 许可

GPL-3.0-or-later。实现是原创重写，但设计上大量参考了 bash 源码（`parse.y` 的
词法与文法）与 `bash -n` 的行为，见 LICENSE。
