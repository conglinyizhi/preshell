#!/usr/bin/env bash
# 方言判断的对照：我们报的 bashism，真 POSIX sh 的解析器认不认。
#
# 为什么需要它：`#!/bin/sh` 的脚本里用了 bash 专有语法，我们只在**解析期**才会断言
# 「在那个 shell 下跑不起来」。这个断言必须拿真 sh 验，而 `bash -n` 不是那个 oracle。
#
# 只把「解析期会被拒绝」那一级算作 claim：dash -n 是解析级 oracle，测不了
# 「能解析但语义不同」（[[ ]]、(( ))）那一级，那一级只记「我们标注了语义差异」。
#
# 用法：tools/corpus/posix_oracle.sh [--strict] [文件列表|目录]
#
# --strict：误报（我们声称解析期会被 sh 拒绝，而 sh 接受了）不为零就退出非零。
# 漏报不挡：我们的归因本来就粗糙，那是有记录的已知弱点。断言错才是真问题。
#
# 并行：按核数把文件列表切片，每片一个后台 shell。单文件的判定只起两个进程
# （preshell 一次、oracle 一次），中间不再为 `grep`/`head` 各 fork 一次——实测
# 那两种写法在 1132 个文件上差 16 秒，而两次真调用加起来才 9 秒。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bin="$root/_build/native/release/build/cmd/preshell/preshell.exe"

strict=0
if [ "${1:-}" = "--strict" ]; then
  strict=1
  shift
fi
target="${1:-}"
if [ -z "$target" ]; then
  target="$(mktemp)"
  "$root/tools/corpus/find_scripts.sh" >"$target"
fi

oracle="${SH_ORACLE:-}"
if [ -z "$oracle" ]; then
  if command -v dash >/dev/null 2>&1; then
    oracle="dash -n"
  else
    oracle="busybox ash -n"
  fi
fi

# 声明了 sh/dash 的才算。正则交给 `[[ =~ ]]`，不为每个文件起一个 grep。
shebang_re='^#![[:space:]]*(/usr)?/bin/(env[[:space:]]+)?(sh|dash)([[:space:]]|$)'
# polyglot 启动器的特征：正文其实是别的语言。全文找，不看前几行——Netpbm 那批把
# 说明写在长注释里，exec 在 60 行之后。同样用内建匹配。
poly_re='exec .*(perl|tclsh|guile|wish|awk|python|ruby|Rscript|swipl|java)|-\*- (perl|tcl|guile)|^[[:space:]]*eval "q \(\)'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 把输入归一到一份纯文件列表：目录取一层，文件去掉空行。
list="$tmp/list"
if [ -d "$target" ]; then
  find "$target" -maxdepth 1 -type f | sort >"$list"
else
  grep -v '^[[:space:]]*$' "$target" >"$list"
fi

# 每个文件一行：<flagged><oracle_ok>\t<我们的 status>\t<是否标注了语义差异>\t<路径>
classify_one() {
  local f="$1" firstline="" scan rest ours flagged=0 odiff=0 key oracle_ok=1
  [ -f "$f" ] || return 0
  IFS= read -r firstline <"$f" || firstline=""
  [[ "$firstline" =~ $shebang_re ]] || return 0
  scan="$("$bin" --cwd="$root" --scan <"$f" 2>/dev/null)"
  # 去掉第一行（`status=…`），其余是我们报的原文。用参数展开而不是管道加 tail。
  ours="${scan%% *}"
  ours="${ours#status=}"
  rest="${scan#*$'\n'}"
  case "$rest" in
    *"would not run under"*) flagged=1 ;;
  esac
  case "$rest" in
    *"reads differently"*) odiff=1 ;;
  esac
  $oracle "$f" >/dev/null 2>&1 || oracle_ok=0
  key="$flagged$oracle_ok"
  printf '%s\t%s\t%s\t%s\n' "$key" "$ours" "$odiff" "$f"
}

# 核数；拿不到就按 1 算，行为退回串行。
procs="$( (getconf _NPROCESSORS_ONLN || nproc || echo 1) 2>/dev/null | head -1)"
case "$procs" in
  '' | *[!0-9]*) procs=1 ;;
esac
[ "$procs" -lt 1 ] && procs=1

# 分片：`split -n l/N` 按行均分，每片一个后台 shell。
if [ "$procs" -gt 1 ]; then
  split -n "l/$procs" -d -a 3 "$list" "$tmp/part." 2>/dev/null || :
else
  cp "$list" "$tmp/part.000"
fi

pids=()
for part in "$tmp"/part.*; do
  (
    while IFS= read -r f; do
      classify_one "$f"
    done <"$part"
  ) >"$part.out" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done

cat "$tmp"/part.*.out >"$tmp/rows" 2>/dev/null || :

n=0
agree_flag=0
false_alarm=0
agree_pass=0
miss=0
miss_poly=0
both_reject=0
differs=0
: >"$tmp/fa_list"
: >"$tmp/miss_real_list"
: >"$tmp/miss_poly_list"

while IFS=$'\t' read -r key ours odiff f; do
  n=$((n + 1))
  [ "$odiff" = "1" ] && differs=$((differs + 1))
  case "$key" in
    10) agree_flag=$((agree_flag + 1)) ;;
    11) false_alarm=$((false_alarm + 1)); echo "$f" >>"$tmp/fa_list" ;;
    01) agree_pass=$((agree_pass + 1)) ;;
    00)
      # sh 拒绝而我们没报：polyglot 启动器（正文是别的语言）不算 bashism 漏报。
      # 只看文件本身，不看 oracle 报错的措辞：之前用报错格式当条件，换 oracle
      # 就从「漏报 12」变成「polyglot 23」，那说明这个判据量的是 oracle 不是文件。
      if [ "$ours" != "Complete" ]; then
        # 我们也拒绝了，和 oracle 一致，不算漏报
        both_reject=$((both_reject + 1))
      elif grep -qE "$poly_re" "$f" 2>/dev/null; then
        miss_poly=$((miss_poly + 1))
        echo "$f" >>"$tmp/miss_poly_list"
      else
        miss=$((miss + 1))
        echo "$f" >>"$tmp/miss_real_list"
      fi
      ;;
  esac
done <"$tmp/rows"

echo "# 方言判断 × POSIX sh 判定"
echo
echo "oracle：$oracle"
echo "声明 sh/dash 的脚本：$n"
echo
echo "- 一致（我们报 bashism，sh 也拒绝）：$agree_flag"
echo "- 误报（我们报 bashism，sh 接受）：$false_alarm"
echo "- 漏报（我们没报，sh 拒绝，且像是 shell 文件）：$miss"
echo "- 疑似 polyglot（sh 拒绝但正文是别的语言）：$miss_poly"
echo "- 两边都拒绝（我们也没解析成功，不算漏报）：$both_reject"
echo "- 一致放行：$agree_pass"
echo "- 我们标注了语义差异（能解析但行为不同，-n 测不了）：$differs"
echo
echo "## 误报"
echo
sed 's|^|  - |' "$tmp/fa_list" | head -20
[ -s "$tmp/fa_list" ] || echo "  （无）"
echo
echo "## 漏报（待查）"
echo
sed 's|^|  - |' "$tmp/miss_real_list" | head -20
[ -s "$tmp/miss_real_list" ] || echo "  （无）"
echo
echo "## 疑似 polyglot（不是 bashism 问题）"
echo
sed 's|^|  - |' "$tmp/miss_poly_list" | head -20
[ -s "$tmp/miss_poly_list" ] || echo "  （无）"

if [ "$strict" = "1" ] && [ "$false_alarm" != "0" ]; then
  echo
  echo "误报不为零：我们声称解析期会被拒绝的写法，oracle 却接受了" >&2
  exit 1
fi
