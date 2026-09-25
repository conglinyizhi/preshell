# bash 语法测试语料（来自 bash 5.3）

这里的 `.sub` 文件取自 GNU bash 5.3 的 `tests/` 目录。

- 上游：https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz （`tests/*.sub`）
- 版权：Free Software Foundation, Inc.
- 许可：GPL-3.0-or-later（与本项目相同）

## 为什么放在仓库里

它们是本项目的主要语法对照语料，`tools/corpus/run.sh` 拿它们做与 `bash -n` 的
四象限差分，`tools/fuzz/mutate.js` 拿它们当变异种子。放在仓库里有两个好处：

- CI 不需要下载 bash 源码，跑的东西和本地完全一致
- 语料版本固定，差分结果可复现（上游更新时这里的数字会变化，需要显式更新）

## 出处与改动

- 取了 `*.sub` 和上游的 `run-minimal`；没有取 `.tests` / `.right` / 其他 `run-*` 驱动（那是执行侧的东西，本项目不执行）
- 内容未做任何修改
- `run-minimal` 是上游用来跑最小语法集的辅助脚本，作为参考保留

## 如果将来要改本项目的许可

这份语料是按 GPL-3.0-or-later 提供的第三方内容，分发这些文件时要遵守它们自身的
GPL 条件。本项目本来就选了 GPL-3.0-or-later，所以当前许可组合相容；但如果将来想把
PreShell 改为宽松许可，需要先删掉这个目录并把差分脚本改成从外部路径读语料
（`run.sh` 的目录参数就是这个用途）。
