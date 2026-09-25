#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
GEN="$ROOT/tools/release_notes.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

repo="$TMP/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name Tester
git -C "$repo" config user.email tester@example.invalid
commit() {
  printf '%s\n' "$1" > "$repo/file"
  git -C "$repo" add file
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$repo" commit -q -m "$1"
}
commit 'chore: initial repository'
git -C "$repo" tag v0.1
commit 'feat(cli): add stream mode'
commit 'fix: preserve refusal ids'
commit 'perf: reduce startup cost'
commit 'refactor(parser)!: change parser boundary'
commit 'docs: explain client obligations'
commit 'ci: upgrade checkout'
commit 'test: add stream corpus'
commit 'chore: refresh metadata'
commit 'build: package man page'
commit 'miscellaneous maintenance'
git -C "$repo" tag -a v0.2 -m 'preshell v0.2' -m '重点：流式接口有变化' >/dev/null

assets="$TMP/assets"
mkdir "$assets"
printf checksum > "$assets/SHA256SUMS"
printf man > "$assets/preshell.1"
printf binary > "$assets/preshell-v0.2-x86_64-linux"

out="$TMP/notes.md"
(
  cd "$repo"
  "$GEN" --from v0.1 --to v0.2 --assets "$assets" --repo https://example.invalid/preshell
) > "$out"

fail() { echo "release-notes test: $*" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$out" || fail "缺少: $1"; }
contains '## 变更'
contains '### 用户可见变更'
contains '### 文档'
contains '### 兼容性'
contains '### 工程维护'
contains '### 其他变更'
contains '## 发布者备注'
contains '## 下载'
contains '<details>'
contains '重点：流式接口有变化'
contains 'preshell.1'
contains 'preshell.md'
contains 'sha256sum -c SHA256SUMS'

# Every detailed category is folded, and the visible categories stay ordered.
line() { grep -n -F -- "$1" "$out" | head -1 | cut -d: -f1; }
[ "$(line '### 用户可见变更')" -lt "$(line '### 文档')" ] || fail '用户变更没有排在文档前'
[ "$(line '### 文档')" -lt "$(line '### 兼容性')" ] || fail '文档没有排在兼容性前'
[ "$(line '### 兼容性')" -lt "$(line '### 工程维护')" ] || fail '兼容性没有排在工程维护前'
[ "$(line '### 工程维护')" -lt "$(line '### 其他变更')" ] || fail '工程维护没有排在其他变更前'
[ "$(grep -c '<details>' "$out")" -eq 5 ] || fail '详细分类没有各自折叠'
contains '- add stream mode'
contains '- preserve refusal ids'
contains '- reduce startup cost'
contains '- change parser boundary'
contains '- explain client obligations'
contains '- upgrade checkout'
contains '- add stream corpus'
contains '- refresh metadata'
contains '- package man page'
contains '- miscellaneous maintenance'

# With no user-facing entries, the generator states that explicitly.
empty="$TMP/empty"
git -C "$repo" checkout -q -b maintenance v0.1
commit 'ci: only maintenance'
(
  cd "$repo"
  "$GEN" --from v0.1 --to HEAD
) > "$empty"
grep -Fq '本版本没有用户可见变更。' "$empty" || fail '空用户分类没有明确说明'

# Unknown tags and malformed options fail without a misleading report.
if (cd "$repo" && "$GEN" --from missing --to v0.2 >/dev/null 2>&1); then
  fail '不存在的 source tag 没有失败'
fi

echo 'release-notes: PASS'
