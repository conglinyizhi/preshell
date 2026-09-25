# PreShell 库 API

这份文档是可执行的 MoonBit Markdown 文档。它展示 PreShell 的核心库如何直接分析命令文本。

命令行用户请看仓库根目录的 [中文 README](../README.zh-CN.md) 或 [English README](../README.md)。

## 一条命令的事实报告

`@lib.analyze` 不执行命令，只把命令文本解析成报告。下面这个示例会在 `moon test` 和安装了 MoonBit 插件的 VS Code 中获得检查支持。

```mbt check
///|
test "analyze a command without executing it" {
  let report = @lib.analyze("rm -rf build")
  debug_inspect(report.status, content="Complete")
  inspect(report.impact.uncertain, content="false")
  inspect(report.impact.effects.length(), content="2")
}
```

报告中的效果是事实，不是 allow/deny 判断：

```mbt check
///|
test "inspect effects" {
  let report = @lib.analyze("cat input.txt > output.txt")
  inspect(report.impact.effects.length(), content="3")
  inspect(report.impact.effects[0].target, content="output.txt")
  inspect(report.impact.effects[1].target, content="cat")
  inspect(report.impact.effects[2].target, content="input.txt")
}
```

## 不确定性必须被保留

当命令交给没有建模的外部程序时，报告会明确标记不确定性：

```mbt check
///|
test "unmodelled programs force uncertainty" {
  let report = @lib.analyze("python3 build.py")
  debug_inspect(report.status, content="Complete")
  inspect(report.impact.uncertain, content="true")
  inspect(report.impact.effects.length(), content="1")
}
```

`uncertain: true` 时，空的或部分的效果列表不能被解释成“没有影响”。

## Bash、zsh 和 probe

可以明确选择语法方言：

```mbt check
///|
test "select a dialect explicitly" {
  let bash_report = @lib.analyze_dialect(
    "[[ -f input.txt ]]",
    @lib.Dialect::Bash,
  )
  let zsh_report = @lib.analyze_dialect("echo =(printf hi)", @lib.Dialect::Zsh)
  debug_inspect(bash_report.status, content="Complete")
  debug_inspect(zsh_report.status, content="Complete")
}
```

`[[ ... ]]` 的条件表达式本身是 opaque 的；条件中的命令替换仍然会被分析，因为它会执行：

```mbt check
///|
test "command substitutions inside conditions still count" {
  let report = @lib.analyze("[[ -f \\\"$(cat secret.txt)\\\" ]]")
  inspect(report.impact.uncertain, content="false")
  inspect(report.impact.effects.length(), content="2")
}
```

## 运行这份文档

在仓库根目录：

```bash
moon test lib/README.mbt.md --target native
```

在 VS Code 中安装 MoonBit 插件后，打开本文件可以看到 MoonBit 代码块的诊断、跳转、格式化和 Test CodeLens。这里的示例直接调用 `@lib`，没有启动 `preshell` 子进程，也没有修改 PreShell 的公共 API。
