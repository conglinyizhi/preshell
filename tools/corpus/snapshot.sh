#!/usr/bin/env bash
# 对列表里每个文件记录一行「status TAB 路径」，用于改动前后做全量状态对比。
#
# 为什么必须全量：run.sh 打印的文件清单有上限（每个象限 20 条），只看总数会漏掉
# 「一个文件修好、另一个同时退化」这种净变化为零的情况。这个坑真踩过：一次 zsh
# 改动后缺口总数没变，全量对比才发现是一修一退。
#
# 用法：tools/corpus/snapshot.sh <preshell 可执行文件> <文件列表> <输出文件>
#   diff before after        看哪些行的状态变了
#   awk 统计第一列计数        看每个状态各有多少
set -uo pipefail
bin="${1:?用法：snapshot.sh <bin> <列表> <输出>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
list="${2:?用法：snapshot.sh <bin> <列表> <输出>}"
out="${3:?用法：snapshot.sh <bin> <列表> <输出>}"
[ -f "$list" ] || { echo "找不到列表：$list" >&2; exit 2; }

: >"$out"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # shellcheck disable=SC2086
  s="$("$bin" --cwd="$root" ${PFLAGS:-} --scan <"$f" 2>/dev/null | head -1 | sed 's/^status=//; s/ .*//')"
  printf '%s\t%s\n' "${s:-CRASH}" "$f" >>"$out"
done <"$list"
wc -l <"$out" >&2
