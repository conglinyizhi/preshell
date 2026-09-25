# PreShell 的第三方材料与许可

这份说明列出仓库中随源代码分发、或只在外部使用的第三方材料。它不改变
PreShell 本身的 GPL-3.0-or-later 许可，也不把外部 oracle 的许可写成 PreShell 的许可。

## GNU Bash 测试语料

`tools/corpus/bash-tests/` 包含从 GNU Bash 5.3 源码树 `tests/` 目录取得的
451 个 `.sub` 测试文件，以及上游的 `run-minimal` 辅助脚本。它们是差分测试语料，
不是 PreShell 的实现代码；文件内容没有修改。

- 上游来源：[GNU Bash 5.3](https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz)
- 取用范围：`tests/*.sub` 与 `run-minimal`
- 版权所有：Free Software Foundation, Inc.
- 许可：GNU GPL-3.0-or-later
- 文件中的上游版权和许可头应保留

该目录的 `README.md` 也记录了来源、取用范围和许可。仓库分发这些语料时，
相应的 GPL 条件适用于这些第三方文件；PreShell 本身同样采用 GPL-3.0-or-later，
所以当前许可选择与这部分语料相容。

## Z shell 语料与 oracle

PreShell 不把 zsh 源码树复制进仓库，也不把它打进 release 产物。运行
`tools/corpus/zsh_corpus.sh` 时，调用方提供一个外部 zsh 源码目录；当前记录的
基线来自 zsh 5.9.2 的 `Completion/` 与 `Functions/`，另可选地抽取 `Test/*.ztst`
中的可验证代码块。

zsh 的源码发行树以项目自己的许可为基础，个别文件还可能带有 GPL、BSD 或其他单独许可；
上游明确要求以具体文件头为准。参见 [zsh 的 `LICENCE`](https://www.zsh.org/)，以及
[官方源码归档](https://www.zsh.org/pub/)。这里只把它作为外部测试输入和 `zsh -n`
oracle 使用，不把 zsh 统一描述成 GPL，也不声称仓库分发了 zsh 源码。需要重新获取
或分发 zsh 源码时，应同时保留 zsh 上游的 `LICENCE` 文件和各文件的版权头。

## MoonBit 依赖

MoonBit 的 `moonbitlang/async` 通过 `moon.mod` 声明并由工具链 registry 获取，
没有将依赖源码复制进 PreShell 仓库或 release 附件。依赖的许可证以其上游发行内容
为准；本项目的 `LICENSE` 只覆盖 PreShell 自身代码。

## PreShell 本身

PreShell 的许可证文本在仓库根目录 `LICENSE`，第三方归属摘要在根目录 `NOTICE`，
模块元数据在 `moon.mod` 中声明为 `GPL-3.0-or-later`。发布二进制时，对应源码仍由
同一个仓库和 tag 提供。
