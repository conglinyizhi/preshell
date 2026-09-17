#!/usr/bin/env bash
# 对比 shaudit 与 `bash -n` 在 bash 自带语法语料上的表现，产出四象限表。
#
# 为什么需要它：shaudit 只有在**有证据**时才允许把一条报错标成 "bash 也会拒绝"
# （ParseStatus::Invalid）。没有证据时一律算自己的缺口（Unsupported）。
# 这个脚本就是产证据的地方，并强制一条不变量：
#
#   凡是被 lib/status.mbt 列为「已佐证语法错」的报错原文，
#   在「我们的缺口」象限里必须出现 0 次。
#
# 为什么是原文级别而不是别的：同一条原文可能两种情形都有。实测中
# `unterminated here-document` 既出现在「bash 也报错」的文件里，也出现在
# 「bash 能解析、我们不能」的文件里（here-doc 套命令替换）。所以按原文升级
# 只有在它彻底退出缺口象限之后才成立——这条不变量就是这个意思。
# 语料不是全集，因此这条保证的强度上限就是语料本身。
#
# 用法：tools/corpus/run.sh [语料目录]
# 默认：$BASH_TESTS，或 ~/Downloads、/tmp 里解开的 bash-*/tests
#
# 已知口径偏差：命令行传参走 `$(cat f)`，会吃掉文件末尾的换行，
# 因此以 EOF 结尾的 here-doc 用例（comsub-eof*.sub）两边都可能被误判。

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bin="$root/_build/native/release/build/cmd/shaudit/shaudit.exe"

corpus="${1:-${BASH_TESTS:-}}"
if [ -z "$corpus" ]; then
  for cand in "$HOME/Downloads"/bash-*/tests /tmp/*/bash-src/bash-*/tests; do
    [ -d "$cand" ] && corpus="$cand" && break
  done
fi
if [ ! -d "$corpus" ]; then
  echo "找不到语料目录，用法：tools/corpus/run.sh <bash 源码 tests 目录>" >&2
  exit 2
fi

if [ ! -x "$bin" ]; then
  ( cd "$root" && moon build --release --target native >/dev/null ) || exit 1
fi

# 从 lib/status.mbt 里抽出已佐证的原文清单，作为不变量的一端。
table_msgs="$(mktemp)"
awk '/fn corroborated_syntax_messages/,/^}/' "$root/lib/status.mbt" |
  sed -n 's/^ *"\(.*\)",$/\1/p' >"$table_msgs"

both_ok=0
we_gap=0
we_permissive=0
corroborated=0
gap_msgs="$(mktemp)"
ok_msgs="$(mktemp)"
permissive_files="$(mktemp)"
gap_files="$(mktemp)"

for f in "$corpus"/*.sub; do
  [ -f "$f" ] || continue
  src="$(cat "$f")"

  line="$("$bin" --scan "$src" 2>/dev/null | head -1)"
  ours="${line%% *}"
  ours="${ours#status=}"
  msgs="$("$bin" --scan "$src" 2>/dev/null | tail -n +2 | sed 's/^issue: //')"

  if bash -n "$f" 2>/dev/null; then bash_ok=1; else bash_ok=0; fi

  if [ "$ours" = "Complete" ]; then
    if [ "$bash_ok" = "1" ]; then
      both_ok=$((both_ok + 1))
    else
      # 危险方向：我们解析通过，bash 拒绝。
      we_permissive=$((we_permissive + 1))
      echo "$f" >>"$permissive_files"
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
done

total=$((both_ok + we_gap + we_permissive + corroborated))

cat <<EOF
# shaudit × bash -n 差分

语料：$corpus
文件数：$total

- 两边都通过：$both_ok
- 我们的缺口（我们报错，bash 通过）：$we_gap  ← P1 要啃的
- 我们太宽松（我们通过，bash 拒绝）：$we_permissive  ← 危险方向，优先查
- 两边都报错：$corroborated

## 报错原文分布

只在「两边都报错」出现（可升级为 Invalid）：

EOF

if [ -s "$ok_msgs" ]; then
  sort "$ok_msgs" | uniq -c | sort -rn | sed 's/^/  /'
else
  echo "  （无）"
fi

echo
echo "同时在「我们的缺口」出现（**不可**升级为 Invalid，必须先填缺口）："
echo
if [ -s "$gap_msgs" ]; then
  sort "$gap_msgs" | uniq -c | sort -rn | sed 's/^/  /'
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
    echo "  - 通过：status.mbt 里的 $(wc -l <"$table_msgs") 条已佐证原文均未出现在缺口象限"
  else
    echo "  - 表为空：当前不允许任何报错升级为 Invalid（默认即诚实态）"
  fi
else
  echo "  - 共 $violations 条违反"
fi

echo
echo "## 我们太宽松的文件（按危险方向优先查）"
echo
if [ -s "$permissive_files" ]; then sed 's|^|  - |' "$permissive_files"; else echo "  （无）"; fi
echo
echo "## 我们缺口的文件"
echo
if [ -s "$gap_files" ]; then sed 's|^|  - |' "$gap_files"; else echo "  （无）"; fi

rm -f "$gap_msgs" "$ok_msgs" "$permissive_files" "$gap_files" "$table_msgs"
[ "$violations" = "0" ] || exit 1
