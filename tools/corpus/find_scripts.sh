#!/usr/bin/env bash
# 采集真实 shell 脚本，输出路径列表（每行一个）。
#
# 只收 sh / bash / dash 的脚本：zsh、fish、ksh 的语法本来就不同，拿来和
# `bash -n` 对照只会得到噪音。这一点很重要——语料脏了，四象限就没意义。
#
# 用法：tools/corpus/find_scripts.sh [目录...] > /tmp/scripts.list
# 默认扫 /usr/bin /usr/sbin /etc /usr/share /opt 以及本仓库（自测）
#
# 原来这一步要 10 秒，全在「每个候选起两个进程」上：`-perm -u+x` 会把几万个
# 可执行文件都选进来（真正的脚本只占一小部分），而每个候选都要开一次文件看
# 开头。改成 `read -N 256` 读开头、`[[ =~ ]]` 判正则，两个都是 shell 内建，
# 一个进程都不起。分片并行是次要的：成本在文件打开，不在 CPU。
set -uo pipefail

roots=("$@")
if [ ${#roots[@]} -eq 0 ]; then
  roots=(/usr/bin /usr/sbin /etc /usr/share /opt)
fi

# 这条正则交给 node 用，所以是 JS 语法：`\s` 而不是 POSIX 的 `[[:space:]]`
# （JS 里后者是字符集合字面量，写成 `/bin/[[:space:]]/` 会匹配不上而静默少收）。
shebang='^#!\s*(/usr)?/bin/(env\s+)?(bash|sh|dash)(\s|$)'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

{
  for root in "${roots[@]}" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 4 -type f \( -name "*.sh" -o -name "*.bash" -o -perm -u+x \) 2>/dev/null
  done
} | sort -u >"$tmp/candidates"

# 过滤交给 node：候选几万个，每个都要读开头 256 字节，而 shell 里那一步是
# `head -c 256 | grep -qE`（两个进程一个候选）。字节语义不能换成 `read -N`
# （那数是字符），所以这一小段用 node 做，理由写在 filter_scripts.mjs 里。
node "$(dirname "${BASH_SOURCE[0]}")/filter_scripts.mjs" "$shebang" <"$tmp/candidates"
