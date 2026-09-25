#!/usr/bin/env bash
# 用 POSIX sh 的判定来审计我们的方言判断。
#
# 背景：preshell 解析的是 bash 语义。脚本声明 `#!/bin/sh` 或 `#!/bin/dash` 时，
# 我们会自己判断「它用了 bash 专有语法」并给出 Note。但那是**我们的判断**，
# 没有外部依据。这个脚本拿真正的 POSIX sh 去跑同一个文件，把两边对齐：
#
#   一致：我们报 bashism，sh 也拒绝
#   误报：我们报 bashism，sh 接受（我们的检测器过宽）
#   漏报：我们没报，sh 拒绝（过窄，或者文件根本不是 shell）
#   一致放行：我们没报，sh 也接受
#
# 漏报那一栏要人工看一眼：`#!/bin/sh` 开头、正文是 Perl/Tcl/二进制（polyglot
# 启动器）的文件也会被 sh 拒绝，那类不是 bashism 漏报，而是「这个文件不是 shell」
# 这个另外的结论。脚本会把疑似 polyglot 单独标出来。
#
# oracle 的选择：$SH_ORACLE，否则 dash，否则 busybox ash。
# 用法：tools/corpus/posix_oracle.sh [--strict] [文件列表|目录]
#
# --strict：误报（我们声称解析期会被 sh 拒绝，而 sh 接受了）不为零就退出非零。
# 漏报不挡：我们的归因本来就粗糙，那是有记录的已知弱点。断言错才是真问题。
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
  elif command -v busybox >/dev/null 2>&1; then
    oracle="busybox ash -n"
  else
    echo "找不到 POSIX sh：装一个 dash，或设 SH_ORACLE" >&2
    exit 2
  fi
fi

[ -x "$bin" ] || ( cd "$root" && moon build --release --target native >/dev/null ) || exit 1

# 只取**真正**声明 sh 或 dash 的：`(sh|dash)` 会误配 bash，因为 bash 里含 sh
shebang='^#!([[:space:]]*)(/usr)?/bin/(env[[:space:]]+)?(sh|dash)([[:space:]]|$)'

files() {
  if [ -d "$target" ]; then
    find "$target" -maxdepth 1 -type f | sort
  else
    grep -v '^[[:space:]]*$' "$target"
  fi
}

n=0
differs=0
agree_flag=0
agree_pass=0
false_alarm=0
miss=0
fa_list="$(mktemp)"
miss_real_list="$(mktemp)"
miss_poly_list="$(mktemp)"
miss_real=0
miss_poly=0
both_reject=0

while IFS= read -r f; do
  [ -f "$f" ] || continue
  head -1 "$f" 2>/dev/null | grep -qE "$shebang" || continue
  n=$((n + 1))

  # 只把「解析期会被拒绝」那一级算作 claim：dash -n 是解析级 oracle，
  # 测不了「能解析但语义不同」（[[ ]]、(( ))）那一级。
  scan="$("$bin" --cwd="$root" --scan <"$f" 2>/dev/null)"
  out="$(printf '%s\n' "$scan" | tail -n +2)"
  # 我们自己也没解析成功的话，就不是「漏报 bashism」：两边都认为这个文件有问题
  ours="${scan%% *}"
  ours="${ours#status=}"
  flagged=0
  printf '%s\n' "$out" | grep -q "would not run under" && flagged=1
  printf '%s\n' "$out" | grep -q "reads differently" && differs=$((differs + 1))

  oracle_ok=1
  $oracle "$f" >/dev/null 2>&1 || oracle_ok=0

  case "$flagged$oracle_ok" in
    # 注意：计数器与临时文件路径必须分开命名，混用一个变量会让 bash 算术报错并终止整个循环
    10) agree_flag=$((agree_flag + 1)) ;;
    11) false_alarm=$((false_alarm + 1)); echo "$f" >>"$fa_list" ;;
    01) agree_pass=$((agree_pass + 1)) ;;
    00)
      # sh 拒绝而我们没报：polyglot 启动器（正文是别的语言）不算 bashism 漏报。
      # 只看文件本身，不看 oracle 报错的措辞：之前用报错格式当条件，换 oracle
      # 就从「漏报 12」变成「polyglot 23」，那说明这个判据量的是 oracle 不是文件。
      # 全文找，不看前几行：Netpbm 那批把说明写在长注释里，exec 在 60 行之后
      if [ "$ours" != "Complete" ]; then
        # 我们也拒绝了，和 oracle 一致，不算漏报
        both_reject=$((both_reject + 1))
      elif grep -qE "exec .*(perl|tclsh|guile|wish|awk|python|ruby|Rscript|swipl|java)|-\\*- (perl|tcl|guile)|^\\s*eval \"q \\(\\)" "$f" 2>/dev/null; then
        miss_poly=$((miss_poly + 1))
        echo "$f" >>"$miss_poly_list"
      else
        miss=$((miss + 1))
        echo "$f" >>"$miss_real_list"
      fi
      ;;
  esac
done < <(files)

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
sed 's|^|  - |' "$fa_list" | head -20
[ -s "$fa_list" ] || echo "  （无）"
echo
echo "## 漏报（待查）"
echo
sed 's|^|  - |' "$miss_real_list" | head -20
[ -s "$miss_real_list" ] || echo "  （无）"
echo
echo "## 疑似 polyglot（不是 bashism 问题）"
echo
sed 's|^|  - |' "$miss_poly_list" | head -20
[ -s "$miss_poly_list" ] || echo "  （无）"

rm -f "$fa_list" "$miss_real_list" "$miss_poly_list"

if [ "$strict" = "1" ] && [ "$false_alarm" != "0" ]; then
  echo
  echo "误报不为零：我们声称解析期会被拒绝的写法，oracle 却接受了" >&2
  exit 1
fi
