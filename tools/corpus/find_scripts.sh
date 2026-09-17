#!/usr/bin/env bash
# 采集真实 shell 脚本，输出路径列表（每行一个）。
#
# 只收 sh / bash / dash 的脚本：zsh、fish、ksh 的语法本来就不同，拿来和
# `bash -n` 对照只会得到噪音。这一点很重要——语料脏了，四象限就没意义。
#
# 用法：tools/corpus/find_scripts.sh [目录...] > /tmp/scripts.list
# 默认扫 /usr/bin /usr/sbin /etc /usr/share /opt 以及本仓库（自测）
set -uo pipefail

roots=("$@")
if [ ${#roots[@]} -eq 0 ]; then
  roots=(/usr/bin /usr/sbin /etc /usr/share /opt)
fi

shebang='^#!([[:space:]]*)(/usr)?/bin/(env[[:space:]]+)?(bash|sh|dash)([[:space:]]|$)'

for root in "${roots[@]}" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth 4 -type f \( -name "*.sh" -o -name "*.bash" -o -perm -u+x \) 2>/dev/null
done | sort -u | while IFS= read -r f; do
  # 只认脚本，不认二进制；shebang 必须是我们支持的那几种 shell
  if head -c 256 "$f" 2>/dev/null | grep -qE "$shebang"; then
    echo "$f"
  fi
done
