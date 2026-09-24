#!/usr/bin/env python3
"""在本地按 .github/workflows/check.yml 跑一遍，推之前就知道 CI 会不会绿。

步骤直接读那份工作流，不在这里另抄一份：抄一份就有两处定义，改了一边忘另一边，
那正是这个仓库一直在防的那种错。只有 runner 上才需要的两步（安装 MoonBit、
moon update）跳过，它们的名字写在 CI_ONLY 里。

用法：tools/ci_local.py [步骤名片段…]（给了片段就只跑匹配的步骤）
"""
import os
import subprocess
import sys

import yaml

CI_ONLY = {"Install MoonBit", "Update registry"}


def steps_of(path=".github/workflows/check.yml"):
    with open(path, encoding="utf-8") as fh:
        wf = yaml.safe_load(fh)
    job = next(iter(wf["jobs"].values()))
    out = []
    for s in job["steps"]:
        name = s.get("name", s.get("uses", "?"))
        run = s.get("run")
        if run is None:
            # actions/checkout 之类：本地已经在仓库里，跳过
            continue
        out.append((name, run))
    return out


def main():
    wanted = sys.argv[1:]
    failures = []
    for name, run in steps_of():
        if name in CI_ONLY:
            print(f"--- {name}：跳过（只有 CI 的新环境需要）")
            continue
        if wanted and not any(w in name for w in wanted):
            continue
        print(f"--- {name}")
        t0 = __import__("time").perf_counter()
        r = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", run],
                           capture_output=True, text=True)
        took = __import__("time").perf_counter() - t0
        tail = [l for l in (r.stdout or "").splitlines() if l.strip()][-3:]
        if r.returncode == 0:
            print(f"    通过（{took:.0f}s）")
        else:
            print(f"    失败（退出码 {r.returncode}，{took:.0f}s）")
            failures.append(name)
            tail = [l for l in ((r.stdout or "") + (r.stderr or "")).splitlines() if l.strip()][-25:]
        for l in tail:
            print(f"      {l}")
    print()
    if failures:
        print(f"本地 CI：{len(failures)} 步失败 — {', '.join(failures)}")
        return 1
    print("本地 CI：全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
