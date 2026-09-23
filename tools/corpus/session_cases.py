#!/usr/bin/env python3
"""拿真实会话里跑过的命令当语料，量这个工具在真实输入上的表现。

语料来源是 pi 的会话记录（~/.pi/agent/sessions/**/*.jsonl）：里面记着agent
实际执行过的每条 bash 命令和每次 sandbox-allow 请求。这些命令不是为测试写的，
所以它们回答的是「这工具在实际用起来的时候好不好用」，而不是「它能不能过我们的用例」。

量的三件事：
  1. 读通率 —— Complete 占多少，读不通的那些命令本身是否也坏
  2. 信息量 —— 有多少条给出了「跑了个程序」之外的路径结论
  3. 危险方向 —— 报出来的目标里有没有明显不是路径的东西；
     「声称懂却什么都没说」有多少条（那是最坏的形状：调用方以为有结论）

注意：会话记录是私人的，脚本只读不写，报告里也只打印命令的首行与统计。

用法：
  tools/corpus/session_cases.py [--sessions DIR] [--n 800] [--bin PATH]
"""
import argparse, collections, glob, json, os, random, re, subprocess, sys

def parse_args():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser()
    p.add_argument("--sessions", default=os.path.expanduser("~/.pi/agent/sessions"))
    p.add_argument("--n", type=int, default=800, help="每类抽多少条（0 = 全部）")
    p.add_argument("--bin", default=os.path.join(
        here, "../../_build/native/release/build/cmd/preshell/preshell.exe"))
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--dump", default="", help="把有问题的样例写到这个目录")
    return p.parse_args()

def collect(sessions):
    """把会话记录里的 bash 命令与 sandbox-allow 请求捞出来。"""
    bash, allow = [], []
    files = glob.glob(os.path.join(sessions, "**", "*.jsonl"), recursive=True)
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"toolCall"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    for c in (d.get("message") or {}).get("content") or []:
                        if not isinstance(c, dict) or c.get("type") != "toolCall":
                            continue
                        cmd = (c.get("arguments") or {}).get("command")
                        if not isinstance(cmd, str) or not cmd.strip():
                            continue
                        name = c.get("name")
                        if name == "bash":
                            bash.append(cmd)
                        elif name == "sandbox-allow":
                            allow.append(cmd)
        except Exception as e:
            print(f"跳过 {f}: {e}", file=sys.stderr)
    return len(files), bash, allow

def make_runner(binary):
    def run(cmd):
        try:
            r = subprocess.run([binary, "--shell=probe"], input=cmd,
                               capture_output=True, text=True, timeout=10)
            return json.loads(r.stdout) if r.returncode == 0 else None
        except Exception:
            return None
    return run

def shell_rejects(cmd):
    """两条 shell 都拒的话，读不通不是我们的错，而是命令本身坏了。"""
    def bad(sh):
        try:
            r = subprocess.run([sh, "-n", "-c", cmd], capture_output=True, timeout=10)
            return r.returncode != 0
        except Exception:
            return False
    return bad("bash") and bad("zsh")

def survey(label, cmds, run, dump_dir, limit):
    counts = collections.Counter()
    kinds = collections.Counter()
    shell_broken = our_gap = 0
    silent, bad_target = [], []
    total = informative = 0
    for c in cmds:
        rep = run(c)
        if rep is None:
            counts["crash-or-timeout"] += 1
            continue
        total += 1
        counts[rep["status"]] += 1
        effs = rep["impact"]["effects"]
        seen = {e["kind"] for e in effs}
        if seen - {"Exec"}:
            informative += 1
        for e in effs:
            kinds[e["kind"]] += 1
            t = e.get("target", "")
            if e["kind"] in ("Read", "Write", "Delete") and isinstance(t, str) \
                    and (t == "" or t.startswith("-")):
                bad_target.append((c, e["kind"], t))
        if rep["status"] != "Complete":
            # 两条 shell 也拒的，是命令本身坏了；shell 接受而我们拒的，才是我们的缺口
            if shell_rejects(c):
                shell_broken += 1
            else:
                our_gap += 1
        # 声称懂却什么都没说：调用方会以为有结论
        if seen == {"Exec"} and all(e.get("modeled", True) for e in effs):
            silent.append(c)
    print(f"### {label}（{total} 条）")
    for k, v in counts.most_common():
        print(f"  {k:16s} {v:5d}  {v * 100 // max(1, total)}%")
    print(f"  有超越 Exec 的结论：{informative}（{informative * 100 // max(1, total)}%）")
    print(f"  读不通但两条 shell 也拒（命令本身坏）：{shell_broken}")
    print(f"  读不通而 shell 接受（我们的缺口）：{our_gap}")
    print(f"  声称懂却什么都没说：{len(silent)}")
    print(f"  目标不像路径：{len(bad_target)}")
    print(f"  效果分布：{dict(kinds.most_common(6))}")
    if dump_dir:
        os.makedirs(dump_dir, exist_ok=True)
        with open(os.path.join(dump_dir, label.replace(" ", "_") + ".txt"), "w",
                  encoding="utf-8") as fh:
            for c in silent[:20]:
                fh.write("声称懂却没说：" + c.strip().split("\n")[0][:120] + "\n")
    return total, informative, silent

def main():
    args = parse_args()
    run = make_runner(args.bin)
    nfiles, bash, allow = collect(args.sessions)
    print(f"会话文件 {nfiles} 个")
    print(f"bash 命令 {len(bash)} 条（去重 {len(set(bash))}）")
    print(f"sandbox-allow 请求 {len(allow)} 次（去重 {len(set(allow))}）\n")

    random.seed(args.seed)
    a = list(dict.fromkeys(bash)); random.shuffle(a)
    b = list(dict.fromkeys(allow)); random.shuffle(b)
    n = args.n if args.n > 0 else len(a)
    survey("bash 命令", a[:n], run, args.dump, n)
    print()
    survey("sandbox-allow 请求", b[:n], run, args.dump, n)

if __name__ == "__main__":
    main()
