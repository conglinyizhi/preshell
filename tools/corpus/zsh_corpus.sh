#!/usr/bin/env bash
# 采集 zsh 语料，输出路径列表（每行一个）。
#
# 主料是 zsh 源码树里的真实 zsh 代码，不是测试片段：
#   Completion/  完成系统，1043 个文件、11 万行，全是真的 zsh
#   Functions/   265 个文件、2 万行
# 这两处的文件没有 shebang（它们是被 source 的），所以不能按 shebang 过滤，
# 直接全收，用 `zsh -n` 当 oracle。
#
# 另外从 Test/*.ztst 里尽力抽出代码块。那个格式里代码是**缩进块**，
# `>` 开头的是期望输出而不是输入，抽错了会把输出当代码，所以只做尽力而为，
# 并且抽出来的每条都先过一遍 `zsh -n`，不通过的丢弃（那多半是抽错了）。
#
# 用法：tools/corpus/zsh_corpus.sh <zsh 源码目录> [输出目录]
set -uo pipefail

src="${1:?用法：zsh_corpus.sh <zsh 源码目录>}"
out="${2:-}"

for d in Completion Functions; do
  [ -d "$src/$d" ] || continue
  find "$src/$d" -type f | sort
done

# .ztst 的代码块：%test 之后的缩进行，排除期望输出与元数据行
if [ -d "$src/Test" ]; then
  tmp="$(mktemp -d)"
  for f in "$src"/Test/*.ztst; do
    [ -f "$f" ] || continue
    awk -v out="$tmp" '
      /^%test/ { intest = 1; n++; file = out "/" FILENAME "_" n ".zsh"; next }
      /^%(prep|clean)/ { intest = 0; next }
      intest {
        # 缩进的行才是代码；`>` `<` `?` `*` 开头是期望输出；数字冒号是测试名
        if ($0 ~ /^  / && $0 !~ /^[ \t]*[<>?*]/ ) print substr($0, 3) > file
      }
    ' FILENAME="$(basename "$f")" "$f"
  done
  # 抽出来再验一遍，不通过的丢掉：抽错的概率比解析器错的高
  for c in "$tmp"/*.zsh; do
    [ -s "$c" ] || continue
    if zsh -n "$c" >/dev/null 2>&1; then
      if [ -n "$out" ]; then
        cp "$c" "$out/"
        echo "$out/$(basename "$c")"
      else
        echo "$c"
      fi
    fi
  done
fi
