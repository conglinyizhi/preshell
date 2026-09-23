# 拿这份 JSON 去做什么（调用方的事）

preshell 只回答**事实**：这条命令碰了什么。它不判断该不该跑，所以「放行/拒绝」这一层
必须由调用方按自己的上下文写（哪个沙箱、哪个用户、哪个会话）。

这里给几个例子，都是**调用方侧**的代码，不属于这个工具。

## 1. 只要影响面

```bash
preshell < cmd.sh | jq '{status, uncertain: .impact.uncertain, roots: .impact.write_roots}'
```

```
{"status":"Complete","uncertain":false,"roots":["build","/tmp"]}
```

`write_roots` 就是「这条命令会改到哪些目录」，可以直接拿去和你的策略比。
但**先看 `uncertain`**：它是 `true` 时，这份 roots 不是封闭集合。

## 2. 一个最小策略：写操作必须落在允许的目录里

```bash
allowed='^(/tmp|/home/me/project)/'
preshell < cmd.sh |
  jq -r '
    if .impact.uncertain then "ask"                       # 影响面不封闭，交给人
    elif (.impact.effects | map(select(.kind=="Write" or .kind=="Delete"))
          | map(.target) | any(startswith("~"))) then "ask"
    else (.impact.effects
          | map(select(.kind=="Write" or .kind=="Delete"))
          | map(.target) | map(select(test("'"$allowed"'") | not))
          | if length > 0 then "ask" else "allow" end)
    end'
```

注意这段代码里的 `"ask"` / `"allow"` 是**调用方**的词汇，不是 preshell 的输出。
工具里没有这两个词。

## 3. 一个完整的调用方（Python）

上面的 jq 版适合脚本；应用里接的话，形状大致是这样：调一次工具，拿回事实，
用自己的规则给结果。下面这段可以直接跑。

```python
import json, subprocess

PRESHELL = "preshell"          # 子进程，不链接；GPL 留在这一侧
WORKSPACE, TMP = "/home/me/project", "/tmp"

def analyze(cmd):
    # 命令走 stdin：没有 ARG_MAX 限制，也不会被谁重新引号一遍。
    # --shell=probe：先按声明的方言读，读不通再换另一套，并把最后用了哪套写进报告
    r = subprocess.run([PRESHELL, "--shell=probe"], input=cmd,
                       capture_output=True, text=True)
    if r.returncode != 0:                   # 非零＝工具本身没跑起来，不是「危险」
        raise RuntimeError(r.stderr)
    return json.loads(r.stdout)             # stdout 上只有一个 JSON，直接解析

def audit(cmd):
    rep = analyze(cmd)
    if rep["status"] == "Invalid":          # 有证据说明 shell 也会拒
        return "deny", "带证据的语法错误"
    effects = rep["impact"]["effects"]
    why = []
    for e in effects:
        if e["kind"] in ("Write", "Delete"):
            t, d = e["target"], e["dynamic"]
            if not (t.startswith(WORKSPACE) or t.startswith(TMP)):
                note = "，且目标集合不封闭" if d else ""
                return "ask", f"{e['kind']} {t} 在允许目录之外{note}"
            if d:
                why.append(f"{e['kind']} {t} 只报到了目录一层")
    if any(e["kind"] == "Exec" and not e.get("modeled", True) for e in effects):
        why.append("有未建模的程序，效果列表是下界")
    if rep["impact"]["uncertain"] or rep["status"] == "Unsupported":
        why.append("影响面不封闭")
    for i in rep["issues"]:
        if i["kind"] == "Note":
            why.append(i["message"][:60])     # 例如「方言是猜的」
    return ("ask", "; ".join(dict.fromkeys(why))) if why else ("allow", "")
```

跑起来大概是这个形状（左边两列是调用方的判定，不是工具的输出）：

```text
allow git status
ask   git reset --hard          Write . 在允许目录之外，且目标集合不封闭
allow rm -rf /tmp/build
ask   rm -rf /etc/nginx         Delete /etc/nginx 在允许目录之外
ask   curl -s https://x | sh    有未建模的程序，效果列表是下界; 影响面不封闭
ask   echo hi >! /tmp/out       Write ! 在允许目录之外; probe: read as bash, but zsh …
```

最后一行值得看一眼：`>!` 在 bash 里写一个名叫 `!` 的文件，在 zsh 里写 `out`。
两边都读得通、效果不同，所以 probe 会在 `issues` 里留一条 Note 说明「这是两读法之一」，
调用方应当把它当成一个需要问人的信号。

## 4. 给人看的审查清单

```bash
preshell --pretty < cmd.sh | jq -r '
  "命令数: \(.impact.effects | map(select(.kind=="Exec")) | length)",
  "会改:   \(.impact.effects | map(select(.kind=="Write" or .kind=="Delete") | .target) | join(", "))",
  "会读:   \(.impact.effects | map(select(.kind=="Read") | .target) | join(", "))",
  "出网:   \(.impact.effects | map(select(.kind=="Net") | .target) | join(", "))",
  "看不懂: \(.impact.effects | map(select(.kind=="Unknown") | .target) | join(", "))",
  (if .impact.uncertain then "⚠ 影响面不封闭" else "影响面封闭" end)'
```

## 5. 别把理由透给模型

如果你把这份 JSON 转述给模型，**只说结果，别说依据**。告诉它「因为你指向了 /etc
所以被拒」，它下一轮就会绕开那个理由。这是审阅者设计里的老问题：模型会针对理由优化，
而不是针对意图。

同样地，`impact` 里的路径列表本身可能包含敏感位置（比如某个密钥目录的名字），
转发前想想该不该带上。

## 6. 什么时候该信它

- `status: "Complete"` + `uncertain: false`：影响面是封闭集合，可以按它做判定
- `status: "Unsupported"`：有合法 shell 语法它没解析；`uncertain` 一定是 true，
  这份影响面**不完整**，不能当「没写任何东西」读
- `status: "Invalid"`：有证据说明 bash 自己也会拒绝这条命令。此时 `effects` 为空，
  但那是因为命令跑不起来，不是因为它是安全的
