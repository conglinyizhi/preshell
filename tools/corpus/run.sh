#!/usr/bin/env bash
# 对比 preshell 与 `bash -n`，产出四象限表并强制一条不变量。
#
# 为什么需要它：preshell 只有在**有证据**时才允许把一条报错标成 "bash 也会拒绝"
# （ParseStatus::Invalid）。没有证据时一律算自己的缺口（Unsupported）。
# 这个脚本就是产证据的地方，并强制：
#
#   凡是工具（--evidence）列为「已佐证语法错」的报错原文，
#   在「我们的缺口」象限里必须出现 0 次。
#
# 同一条原文可能两种情形都有（实测 known 的 unterminated here-document 就是），
# 所以按原文升级只有在它彻底退出缺口象限之后才成立。语料不是全集，
# 这条保证的强度上限就是语料本身。
#
# 用法：
#   tools/corpus/run.sh                      # 默认拿仓库内的 tools/corpus/bash-tests
#   tools/corpus/run.sh <目录>                # 该目录下的 *.sub
#   tools/corpus/run.sh --list <文件列表>      # 任意脚本列表（见 find_scripts.sh）
#
# 输入一律走 stdin，不走 argv：那是 CLI 推荐的入口，没有 ARG_MAX 限制
# （libtool、configure 这类几百 KB 的脚本用 argv 传会直接 E2BIG），
# 也不会像命令替换那样吃掉文件末尾的换行。

set -uo pipefail

# oracle 可换：默认 bash -n；做 zsh 方言时用 ORACLE="zsh -n"。
ORACLE="${ORACLE:-bash -n}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bin="$root/_build/native/release/build/cmd/preshell/preshell.exe"

mode="dir"
target=""
if [ "${1:-}" = "--list" ]; then
  mode="list"
  target="${2:?--list 需要文件列表}"
elif [ -n "${1:-}" ]; then
  target="$1"
else
  # 语料随仓库分发，默认就用它：CI 和本地跑的是同一份，结果可比。
  # 也可以传别的目录，或用 BASH_TESTS 指向解开的 bash 源码。
  for cand in "${BASH_TESTS:-}" "$root/tools/corpus/bash-tests" "$HOME/Downloads"/bash-*/tests; do
    [ -d "$cand" ] && target="$cand" && break
  done
fi

if [ "$mode" = "dir" ] && [ ! -d "$target" ]; then
  echo "找不到语料目录，用法：tools/corpus/run.sh [目录|--list 文件]" >&2
  exit 2
fi
if [ "$mode" = "list" ] && [ ! -f "$target" ]; then
  echo "找不到文件列表：$target" >&2
  exit 2
fi

if [ ! -x "$bin" ]; then
  ( cd "$root" && moon build --release --target native >/dev/null ) || exit 1
fi

max_line=20   # 每个象限最多打印多少条文件名

# 已佐证的原文清单问工具本身要，不从源码 grep：那张表现在按方言分支，
# 而 grep 出来的东西跟工具实际用的规则可能悄悄分叉。
table_msgs="$(mktemp)"
# shellcheck disable=SC2086
"$bin" ${PFLAGS:-} --evidence >"$table_msgs"

both_ok=0
we_gap=0
we_permissive=0
corroborated=0
gap_msgs="$(mktemp)"
ok_msgs="$(mktemp)"
permissive_files="$(mktemp)"
gap_files="$(mktemp)"
crash_files="$(mktemp)"
t0=$(date +%s%N)

list_files() {
  case "$mode" in
    dir) find "$target" -maxdepth 1 -name "*.sub" -type f | sort ;;
    list) grep -v '^[[:space:]]*$' "$target" ;;
  esac
}

while IFS= read -r f; do
  [ -f "$f" ] || continue
  # PFLAGS lets a caller pick the dialect: zsh code in this tree carries no
  # shebang (it is sourced), so auto-detection cannot see it.
  # shellcheck disable=SC2086
  out="$(timeout 20 "$bin" ${PFLAGS:-} --scan <"$f" 2>/dev/null)" || out=""
  line="$(printf '%s\n' "$out" | head -1)"
  ours="${line%% *}"
  ours="${ours#status=}"
  if [ -z "$ours" ]; then
    # 没有输出 = 崩了或超时。这类必须单独记账：不是「判定错了」，是工具没了
    ours="CRASH"
    echo "$f" >>"$crash_files"
  fi
  msgs="$(printf '%s\n' "$out" | tail -n +2 | sed 's/^issue: //; s/ (line [0-9]*)$//')"

  # The verdict is the exit code; the message is for the reader. Some inputs
  # make the oracle exit non-zero without printing anything at all.
  oracle_msg="$($ORACLE "$f" 2>&1 >/dev/null)"
  oracle_rc=$?
  if [ "$oracle_rc" = "0" ]; then bash_ok=1; else bash_ok=0; fi

  if [ "$ours" = "Complete" ]; then
    if [ "$bash_ok" = "1" ]; then
      both_ok=$((both_ok + 1))
    else
      we_permissive=$((we_permissive + 1))
      # Keep the oracle's own words: most of this quadrant is the oracle doing
      # partial evaluation (`zsh -n` reports division by zero, fd numbers and
      # indirect assignments), and that has to be visible without a rerun.
      printf '%s\n  oracle: %s\n' "$f" "$(printf '%s' "${oracle_msg:-（无原文，退出码非零）}" | head -1)" >>"$permissive_files"
    fi
  else
    if [ "$bash_ok" = "1" ]; then
      we_gap=$((we_gap + 1))
      echo "$f" >>"$gap_files"
      printf '%s\n' "$msgs" >>"$gap_msgs"
    else
      corroborated=$((corroborated + 1))
      printf '%s\n' "$msgs" >>"$ok_msgs"
    fi
  fi
done < <(list_files)
t1=$(date +%s%N)

total=$((both_ok + we_gap + we_permissive + corroborated))
secs=$(( (t1 - t0) / 1000000000 ))
crashes=$(wc -l <"$crash_files")

print_capped() {
  local file="$1"
  if [ -s "$file" ]; then
    head -"$max_line" "$file" | sed 's|^|  - |'
    local n
    n=$(wc -l <"$file")
    [ "$n" -gt "$max_line" ] && echo "  … 另有 $((n - max_line)) 个"
  else
    echo "  （无）"
  fi
}

cat <<EOF
# preshell × $ORACLE 差分（默认 bash -n）

语料：$target（模式 $mode）
文件数：$total
耗时：${secs}s

oracle：$ORACLE
- 两边都通过：$both_ok
- 我们的缺口（我们报错，oracle 通过）：$we_gap  ← 解析器要补的
- 我们太宽松（我们通过，oracle 拒绝）：$we_permissive  ← 危险方向，优先查
- 两边都报错：$corroborated
- 崩溃或超时：$crashes  ← 必须为零

## 报错原文分布

只在「两边都报错」出现（可升级为 Invalid）：

EOF
if [ -s "$ok_msgs" ]; then
  sort "$ok_msgs" | grep -v '^$' | uniq -c | sort -rn | sed 's/^/  /'
else
  echo "  （无）"
fi

echo
echo "同时在「我们的缺口」出现（不可升级为 Invalid，必须先填缺口）："
echo
if [ -s "$gap_msgs" ]; then
  sort "$gap_msgs" | grep -v '^$' | uniq -c | sort -rn | sed 's/^/  /'
else
  echo "  （无）"
fi

echo
echo "## 不变量检查"
echo
violations=0
while IFS= read -r m; do
  [ -z "$m" ] && continue
  n="$(grep -Fxc "$m" "$gap_msgs" || true)"
  if [ "$n" != "0" ]; then
    echo "  - 违反：\"$m\" 被列为已佐证，但在缺口象限出现 $n 次"
    violations=$((violations + 1))
  fi
done <"$table_msgs"
if [ "$violations" = "0" ]; then
  if [ -s "$table_msgs" ]; then
    echo "  - 通过：工具报的 $(wc -l <"$table_msgs") 条已佐证原文在缺口象限出现 0 次"
  else
    echo "  - 表为空：当前不允许任何报错升级为 Invalid（默认即诚实态）"
  fi
else
  echo "  - 共 $violations 条违反"
fi

echo
echo "## 崩溃 / 超时（必须为零）"
echo
print_capped "$crash_files"
echo
echo "## 我们太宽松的文件"
echo
print_capped "$permissive_files"
echo
echo "## 我们缺口的文件"
echo
print_capped "$gap_files"

rm -f "$gap_msgs" "$ok_msgs" "$permissive_files" "$gap_files" "$table_msgs" "$crash_files"
[ "$violations" = "0" ] || exit 1
[ "$crashes" = "0" ] || exit 1
