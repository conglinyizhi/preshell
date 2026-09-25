///|
/// 词首未解析的路径不拼基准。
///
/// 依据是 bash 5.3 手册 "Expansion"：参数的**值按原样使用**，它是不是绝对路径
/// 只有运行时知道。把基准拼在 `$HOME/x` 前面会得到 `<cwd>/$HOME/x`，看着已经解析，
/// 其实算错——调用方拿 `HOME=/home/u` 替换后是 `/home/u/x`。所以文本照原样报出，
/// 由知道值的调用方收尾。
///
/// `~` 同属这一类：手册 "Tilde Expansion" 里 `~` 就是 `HOME`，`~user` 是那个用户
/// 的家目录；而且**登录名无效时前缀原样保留**，那时它反倒是相对路径。两种可能都
/// 存在，所以它只能是洞。
fn expansion_impact(src : String) -> @lib.Impact {
  @lib.analyze(src, base_cwd=Some("/base")).impact
}

///|
fn paths_of(im : @lib.Impact, kind : @lib.EffectKind) -> Array[String] {
  let out : Array[String] = []
  for e in im.effects {
    if e.kind == kind {
      out.push(e.target)
    }
  }
  out
}

///|
fn has_unknown(im : @lib.Impact) -> Bool {
  im.effects.any(fn(e) { e.kind == @lib.EffectKind::Unknown })
}

///|
test "a variable at the head is not anchored to the base" {
  let im = expansion_impact("rm -rf $HOME/x")
  debug_inspect(paths_of(im, Delete), content="[\"$HOME/x\"]")
  inspect(has_unknown(im), content="true")
  inspect(im.uncertain, content="true")
  debug_inspect(im.write_roots, content="[\"$HOME\"]")
}

///|
test "a tilde at the head is a hole, not a directory called ~" {
  // 回归：`~/x` 曾经报成 `/base/~/x`，既锚错又没有任何不确定标记——一个假事实。
  let im = expansion_impact("rm -rf ~/x")
  debug_inspect(paths_of(im, Delete), content="[\"~/x\"]")
  inspect(has_unknown(im), content="true")
  inspect(im.uncertain, content="true")
}

///|
test "a ~user prefix is a hole too" {
  // 用户存在时它是绝对路径，不存在时 bash 原样保留前缀，于是它相对。
  let im = expansion_impact("rm -rf ~someone/x")
  debug_inspect(paths_of(im, Delete), content="[\"~someone/x\"]")
  inspect(im.uncertain, content="true")
}

///|
test "a quoted tilde stays a literal relative path" {
  // 手册：只有词首**未加引号**的波浪号才展开，所以这里锚定是对的。
  let im = expansion_impact("rm -rf \"~\"/x")
  debug_inspect(paths_of(im, Delete), content="[\"/base/~/x\"]")
  inspect(has_unknown(im), content="false")
  inspect(im.uncertain, content="false")
}

///|
test "a quoted dollar is literal text, so it is anchored" {
  // `'$X/y'` 是一个真的叫 `$X` 的目录，没有洞，锚定正确。
  let im = expansion_impact("rm -rf '$X/y'")
  debug_inspect(paths_of(im, Delete), content="[\"/base/$X/y\"]")
  inspect(has_unknown(im), content="false")
  inspect(im.uncertain, content="false")
}

///|
test "a hole after a literal head keeps the base" {
  // 头部是字面量，路径确定是相对的，基准该拼。
  let im = expansion_impact("rm -rf dir/$X/y")
  debug_inspect(paths_of(im, Delete), content="[\"/base/dir/$X/y\"]")
  inspect(im.uncertain, content="true")
}

///|
test "an absolute head is left alone whatever follows" {
  let im = expansion_impact("rm -rf /a/$X")
  debug_inspect(paths_of(im, Delete), content="[\"/a/$X\"]")
}

///|
test "braces survive when dropping them would run into a name" {
  // `${X}y` 与 `$Xy` 是两个不同的展开，报告不能把前者写成后者。
  debug_inspect(
    paths_of(expansion_impact("rm -rf ${X}y"), Delete),
    content="[\"${X}y\"]",
  )
  // 后面不是名字字符时，去掉花括号是等价的。
  debug_inspect(
    paths_of(expansion_impact("rm -rf ${X}/y"), Delete),
    content="[\"$X/y\"]",
  )
}

///|
test "a parameter with an operator keeps its spelling" {
  debug_inspect(
    paths_of(expansion_impact("rm -rf ${X:-/tmp}/y"), Delete),
    content="[\"${X:-/tmp}/y\"]",
  )
}
