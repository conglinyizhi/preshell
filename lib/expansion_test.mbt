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

///|
/// 变量提取：把名字交出去，值由知道它的调用方替换。
///
/// 依据 bash 5.3 手册 "Expansion"：参数的值按原样使用，所以工具能提供的不是
/// 路径，而是「这条路径依赖哪些名字」。
fn vars_of(src : String) -> Array[String] {
  expansion_impact(src).vars
}

///|
/// 每条路径效果各自带的变量，按效果顺序拼起来（Exec/Net 这些不是路径，跳过）。
fn effect_vars_of(src : String) -> Array[String] {
  let out : Array[String] = []
  for e in expansion_impact(src).effects {
    if e.kind == @lib.EffectKind::Read ||
      e.kind == @lib.EffectKind::Write ||
      e.kind == @lib.EffectKind::Delete {
      for v in e.vars {
        out.push(v)
      }
    }
  }
  out
}

///|
test "a path reports the variable it reads" {
  debug_inspect(vars_of("rm -rf \"$HOME/x\""), content="[\"HOME\"]")
  debug_inspect(effect_vars_of("rm -rf \"$HOME/x\""), content="[\"HOME\"]")
}

///|
test "the report lists each variable once" {
  // 两个路径读同一个名字，汇总里只出现一次。
  debug_inspect(vars_of("rm -rf $HOME/a $HOME/b"), content="[\"HOME\"]")
  debug_inspect(vars_of("rm -rf $A/x $B/y"), content="[\"A\", \"B\"]")
}

///|
test "a tilde names the variable it stands for" {
  debug_inspect(vars_of("rm -rf ~/x"), content="[\"HOME\"]")
  debug_inspect(vars_of("rm -rf ~+"), content="[\"PWD\"]")
  debug_inspect(vars_of("rm -rf ~-"), content="[\"OLDPWD\"]")
}

///|
test "a ~user prefix names nothing a caller could look up" {
  // 它走的是口令库，不是环境；而且登录名无效时 bash 原样保留前缀。
  debug_inspect(vars_of("rm -rf ~someone/x"), content="[]")
}

///|
test "a derived name keeps the variables of the operand" {
  // `gzip $F` 写的是 `$F.gz`：名字由操作数推导，变量还是 F。
  debug_inspect(vars_of("gzip $F"), content="[\"F\"]")
  // 三个路径效果各带一份 F：读 $F、写 $F.gz、删 $F。
  debug_inspect(effect_vars_of("gzip $F"), content="[\"F\", \"F\", \"F\"]")
}

///|
test "a directory target carries its own variable into the derived path" {
  let im = expansion_impact("cp -t $D a.txt")
  debug_inspect(im.vars, content="[\"D\"]")
  // 目标目录是洞时，派生出来的写路径也不能锚定。
  let written : Array[String] = []
  for e in im.effects {
    if e.kind == @lib.EffectKind::Write {
      written.push(e.target)
    }
  }
  debug_inspect(written, content="[\"$D/a.txt\"]")
}

///|
test "no variables means no noise" {
  debug_inspect(vars_of("rm -rf dist"), content="[]")
  let im = expansion_impact("rm -rf dist")
  for e in im.effects {
    debug_inspect(e.vars, content="[]")
  }
}

///|
test "a positional parameter is a hole without a name" {
  // `$1`/`$@` 没有环境可查，列出来只会让调用方去找一个不存在的变量。
  debug_inspect(vars_of("rm -rf $1/x $@"), content="[]")
}
