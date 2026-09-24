#!/bin/sh
# Generate a compact, folded GitHub Release changelog from commit subjects.
set -eu

from=
to=HEAD
assets=
repo=
usage() {
  echo "usage: $0 [--from TAG] [--to TAG] [--assets DIR] [--repo URL]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)
      [ "$#" -ge 2 ] || usage
      from=$2
      shift 2
      ;;
    --to)
      [ "$#" -ge 2 ] || usage
      to=$2
      shift 2
      ;;
    --assets)
      [ "$#" -ge 2 ] || usage
      assets=$2
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || usage
      repo=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

# Validate the target and optional range endpoints before writing any output.
git rev-parse --verify "$to^{commit}" >/dev/null 2>&1 || {
  echo "release-notes: unknown target tag: $to" >&2
  exit 1
}
if [ -n "$from" ]; then
  git rev-parse --verify "$from^{commit}" >/dev/null 2>&1 || {
    echo "release-notes: unknown source tag: $from" >&2
    exit 1
  }
  range="$from..$to"
else
  range="$to"
fi

user_visible=
 docs=
 compatibility=
 maintenance=
 other=

append() {
  bucket=$1
  subject=$2
  case "$bucket" in
    user_visible) user_visible="${user_visible}${subject}
" ;;
    docs) docs="${docs}${subject}
" ;;
    compatibility) compatibility="${compatibility}${subject}
" ;;
    maintenance) maintenance="${maintenance}${subject}
" ;;
    other) other="${other}${subject}
" ;;
  esac
}

# Keep the original subject for traceability, but remove only its routing prefix
# from the displayed bullet. The commit itself remains linked by GitHub's text.
while IFS="$(printf '\t')" read -r commit subject; do
  [ -n "$commit" ] || continue
  body=$(git show -s --format='%b' "$commit")
  display=$(printf '%s' "$subject" | sed -E 's/^[a-zA-Z]+(\([^)]*\))?(!)?: *//')
  type=$(printf '%s' "$subject" | sed -nE 's/^([a-zA-Z]+)(\([^)]*\))?(!)?: .*/\1/p' | tr '[:upper:]' '[:lower:]')
  breaking=false
  case "$subject" in
    *'!'\:*) breaking=true ;;
  esac
  printf '%s\n' "$body" | grep -q '^BREAKING CHANGE' && breaking=true || true

  if [ "$breaking" = true ]; then
    append compatibility "$display"
  else
    case "$type" in
      feat|fix|perf|refactor) append user_visible "$display" ;;
      docs) append docs "$display" ;;
      ci|test|chore|build) append maintenance "$display" ;;
      *) append other "$display" ;;
    esac
  fi
done <<EOF
$(git log --no-merges --format='%H%x09%s' "$range")
EOF

count_lines() {
  # Empty strings are deliberately counted as zero without relying on wc's
  # platform-specific treatment of an empty final line.
  [ -n "$1" ] || { echo 0; return; }
  printf '%s' "$1" | awk 'END { print NR }'
}

section() {
  title=$1
  contents=$2
  count=$(count_lines "$contents")
  [ "$count" -gt 0 ] || return 0
  echo "### $title"
  echo
  echo "<details>"
  echo "<summary>${count} 项提交</summary>"
  echo
  printf '%s' "$contents" | sed 's/^/- /'
  echo
  echo "</details>"
  echo
}

echo "## 变更"
echo
if [ -z "$user_visible" ]; then
  echo "本版本没有用户可见变更。"
  echo
else
  section "用户可见变更" "$user_visible"
fi
section "文档" "$docs"
section "兼容性" "$compatibility"
section "工程维护" "$maintenance"
section "其他变更" "$other"

body=$(git for-each-ref "refs/tags/$to" --format='%(contents:body)' 2>/dev/null || true)
if [ -n "$body" ]; then
  echo "## 发布者备注"
  echo
  printf '%s\n\n' "$body"
fi

echo "## 下载"
echo
if [ -n "$assets" ] && [ -d "$assets" ]; then
  echo "| 文件 | 用途 |"
  echo "|---|---|"
  found=false
  for file in "$assets"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    found=true
    case "$name" in
      SHA256SUMS) purpose="SHA-256 校验和" ;;
      *.1) purpose="man 手册" ;;
      *) purpose="Linux 发布产物" ;;
    esac
    printf '| `%s` | %s |\n' "$name" "$purpose"
  done
  [ "$found" = true ] || echo "| （暂无附件） | 构建产物尚未生成 |"
else
  echo "构建产物见本 Release 的附件。"
fi
echo
echo '校验下载的文件：'
echo
printf '%s\n' '```bash'
echo 'sha256sum -c SHA256SUMS'
echo '```'
echo
if [ -n "$repo" ]; then
  echo "源码与本版本对应的 tag：[$to]($repo/releases/tag/$to)"
  echo
  echo "许可证：GPL-3.0-or-later。"
fi
