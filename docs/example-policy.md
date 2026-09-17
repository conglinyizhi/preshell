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

## 3. 给人看的审查清单

```bash
preshell --pretty < cmd.sh | jq -r '
  "命令数: \(.impact.effects | map(select(.kind=="Exec")) | length)",
  "会改:   \(.impact.effects | map(select(.kind=="Write" or .kind=="Delete") | .target) | join(", "))",
  "会读:   \(.impact.effects | map(select(.kind=="Read") | .target) | join(", "))",
  "出网:   \(.impact.effects | map(select(.kind=="Net") | .target) | join(", "))",
  "看不懂: \(.impact.effects | map(select(.kind=="Unknown") | .target) | join(", "))",
  (if .impact.uncertain then "⚠ 影响面不封闭" else "影响面封闭" end)'
```

## 4. 别把理由透给模型

如果你把这份 JSON 转述给模型，**只说结果，别说依据**。告诉它「因为你指向了 /etc
所以被拒」，它下一轮就会绕开那个理由。这是审阅者设计里的老问题：模型会针对理由优化，
而不是针对意图。

同样地，`impact` 里的路径列表本身可能包含敏感位置（比如某个密钥目录的名字），
转发前想想该不该带上。

## 5. 什么时候该信它

- `status: "Complete"` + `uncertain: false`：影响面是封闭集合，可以按它做判定
- `status: "Unsupported"`：有合法 shell 语法它没解析；`uncertain` 一定是 true，
  这份影响面**不完整**，不能当「没写任何东西」读
- `status: "Invalid"`：有证据说明 bash 自己也会拒绝这条命令。此时 `effects` 为空，
  但那是因为命令跑不起来，不是因为它是安全的
