#!/usr/bin/env bash
# 把一个语料列表里「我们判 Unsupported 或 Invalid」的文件，按第一条 issue 聚类。
#
# 为什么需要它：缺口数量只是总数，要动手得知道它们是哪些构造。
# 输出「首错行原文 TAB 文件路径」，交给 sort 与 uniq -c 聚类。
#
# 注意：首错行常常只是级联症状（曾经有 127 个文件同时报在一行孤立的右括号上，
# 真因是更早的数组括号）。聚类可以用它，但它不是病因。
#
# 用法：tools/corpus/classify.sh <preshell 可执行文件> < 文件列表
#   PFLAGS 同 run.sh：zsh 语料要 PFLAGS=--shell=zsh
set -uo pipefail
bin="${1:?用法：classify.sh <preshell 可执行文件> < 文件列表}"

while IFS= read -r f; do
  [ -f "$f" ] || continue
  # shellcheck disable=SC2086
  out="$("$bin" ${PFLAGS:-} --scan <"$f" 2>/dev/null)" || out=""
  case "$out" in
    *Unsupported* | *Invalid*) ;;
    *) continue ;;
  esac
  line2="$(printf '%s\n' "$out" | sed -n 2p)"
  n="$(printf '%s\n' "$line2" | sed -n 's/.*(line \([0-9]*\)).*/\1/p')"
  printf '%s\t%s\n' \
    "$(sed -n "${n}p" "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-78)" \
    "$f"
done
