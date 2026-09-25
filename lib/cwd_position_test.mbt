///|
/// 相对路径的解析起点：`--cwd` 给的基准，与命令内部 `cd` 的先后关系。
///
/// 这一层出错的样子是静默的：报告照样是 `Complete`，调用方按自己的 pwd 拼出来
/// 的却是另一个路径，所以「删的是哪个路径」必须逐条钉死。这些用例同时锁住两次
/// 修复：相对 `cd` 在基准未知时必须报不确定，以及连续 `..` 不能互相抵消。
fn impact_from(base : String?, src : String) -> @lib.Impact {
  @lib.analyze(src, base_cwd=base).impact
}

///|
fn deleted_paths(im : @lib.Impact) -> Array[String] {
  let out : Array[String] = []
  for e in im.effects {
    if e.kind is Delete {
      out.push(e.target)
    }
  }
  out
}

///|
fn mentions_unknown_cd(im : @lib.Impact) -> Bool {
  im.effects.any(fn(e) { e.kind is Unknown && e.target.contains("cd") })
}

///|
test "no base and no cd leaves the path as written" {
  // 库这一层不猜基准：`base_cwd=None` 时原样返回。命令行入口不会走到这里，
  // 它要么用 --cwd，要么用本进程当前目录推演（见下面的 CLI 契约与 probe）。
  let im = impact_from(None, "rm -rf dist")
  debug_inspect(im.cwd, content="None")
  debug_inspect(deleted_paths(im), content="[\"dist\"]")
  debug_inspect(im.write_roots, content="[\".\"]")
  inspect(im.uncertain, content="false")
}

///|
test "a caller-supplied base turns relative paths absolute" {
  let im = impact_from(Some("/a/b"), "rm -rf dist")
  debug_inspect(im.cwd, content="Some(\"/a/b\")")
  debug_inspect(deleted_paths(im), content="[\"/a/b/dist\"]")
  debug_inspect(im.write_roots, content="[\"/a/b\"]")
  inspect(im.uncertain, content="false")
}

///|
test "a supplied base is not a cd and produces no effect" {
  let im = impact_from(Some("/a/b"), "rm -rf dist")
  let cds = im.effects.filter(fn(e) { e.target == "cd" })
  inspect(cds.length(), content="0")
}

///|
test "a cd inside the command line overrides the supplied base" {
  let im = impact_from(Some("/a/b"), "cd /tmp && rm -rf dist")
  debug_inspect(im.cwd, content="Some(\"/tmp\")")
  debug_inspect(deleted_paths(im), content="[\"/tmp/dist\"]")
}

///|
test "a relative cd resolves against the supplied base" {
  let im = impact_from(Some("/a/b"), "cd ../c && rm -rf dist")
  debug_inspect(im.cwd, content="Some(\"/a/c\")")
  debug_inspect(deleted_paths(im), content="[\"/a/c/dist\"]")
}

///|
test "consecutive cds accumulate in order" {
  let im = impact_from(Some("/base"), "cd /a && cd b && cd ../c && rm -rf dist")
  debug_inspect(im.cwd, content="Some(\"/a/c\")")
  debug_inspect(deleted_paths(im), content="[\"/a/c/dist\"]")
}

///|
test "repeated cd .. cannot climb above the root" {
  // 回归：`..` 在根上仍然是根，两个 `..` 也曾互相抵消，把 `/` 报成 `/..`。
  let im = impact_from(None, "cd /a && cd .. && cd .. && rm x")
  debug_inspect(im.cwd, content="Some(\"/\")")
  debug_inspect(deleted_paths(im), content="[\"/x\"]")
  inspect(im.uncertain, content="false")
}

///|
test "a relative cd with no known base is uncertainty, not silence" {
  // 回归：这条分支曾经只把 cwd 置空，`uncertain` 仍是 false。调用方按契约把缺失
  // 的 cwd 读成「用我自己的 pwd」，`cd .. && rm -rf dist` 就会算到别的路径上，
  // 而且没有任何提示。
  let im = impact_from(None, "cd .. && rm -rf dist")
  debug_inspect(im.cwd, content="None")
  inspect(im.uncertain, content="true")
  inspect(mentions_unknown_cd(im), content="true")
}

///|
test "an unmodellable cd is reported, not guessed" {
  let im = impact_from(None, "cd $DIR && rm x")
  debug_inspect(im.cwd, content="None")
  inspect(im.uncertain, content="true")
  inspect(mentions_unknown_cd(im), content="true")
}

///|
test "a relative cd with no base is certain once a base is supplied" {
  let im = impact_from(Some("/a/b"), "cd .. && rm -rf dist")
  debug_inspect(im.cwd, content="Some(\"/a\")")
  debug_inspect(deleted_paths(im), content="[\"/a/dist\"]")
  inspect(im.uncertain, content="false")
}

///|
test "a subshell cd does not move the surrounding base" {
  let im = impact_from(Some("/a/b"), "(cd /tmp && rm x); rm y")
  debug_inspect(im.cwd, content="Some(\"/a/b\")")
  debug_inspect(deleted_paths(im), content="[\"/tmp/x\", \"/a/b/y\"]")
}

///|
test "a command substitution cd does not move the surrounding base" {
  let im = impact_from(Some("/a/b"), "x=$(cd /tmp && rm y); rm z")
  debug_inspect(im.cwd, content="Some(\"/a/b\")")
  debug_inspect(deleted_paths(im), content="[\"/tmp/y\", \"/a/b/z\"]")
}

///|
test "a pipeline element cd does not move the next element" {
  let im = impact_from(Some("/a/b"), "cd /tmp | rm x")
  debug_inspect(im.cwd, content="Some(\"/a/b\")")
  debug_inspect(deleted_paths(im), content="[\"/a/b/x\"]")
}

///|
test "a script handed to another shell has its own base scope" {
  let im = impact_from(Some("/a/b"), "bash -c \"cd /tmp; rm x\"; rm y")
  debug_inspect(im.cwd, content="Some(\"/a/b\")")
  debug_inspect(deleted_paths(im), content="[\"/tmp/x\", \"/a/b/y\"]")
}

///|
test "an absolute path ignores the base" {
  let im = impact_from(Some("/a/b"), "rm -rf /abs/y")
  debug_inspect(deleted_paths(im), content="[\"/abs/y\"]")
  debug_inspect(im.write_roots, content="[\"/abs\"]")
  debug_inspect(im.cwd, content="Some(\"/a/b\")")
}

///|
test "normalize keeps the root as the ceiling" {
  inspect(@lib.normalize_path("/.."), content="/")
  inspect(@lib.normalize_path("/a/../../.."), content="/")
  inspect(@lib.normalize_path("/a/b/../c"), content="/a/c")
  inspect(@lib.normalize_path("/"), content="/")
  inspect(@lib.normalize_path("/a/"), content="/a")
}

///|
test "normalize sums leading .. in a relative path" {
  // 两个 `..` 是两层，曾经被折叠成一层，目录因此算错。
  inspect(@lib.normalize_path("../.."), content="../..")
  inspect(@lib.normalize_path("a/../../.."), content="../..")
  inspect(@lib.normalize_path("../x"), content="../x")
}

///|
test "a caveat keeps the status and marks the impact uncertain" {
  // 警告必须让调用方看见：带 kind，并且强制 uncertain，
  // 而不是只留一条可以被忽略的文字。
  let plain = @lib.analyze_dialect(
    "rm -rf x",
    @lib.Dialect::Bash,
    base_cwd=Some("/a"),
  )
  inspect(plain.issues.length(), content="0")
  inspect(plain.impact.uncertain, content="false")
  let warned = @lib.add_note(plain, "no --cwd given")
  debug_inspect(warned.status, content="Complete")
  inspect(warned.issues.length(), content="1")
  debug_inspect(warned.issues[0].kind, content="Note")
  inspect(warned.issues[0].message, content="no --cwd given")
  inspect(warned.impact.uncertain, content="true")
  // 路径本身不受警告影响。
  debug_inspect(deleted_paths(warned.impact), content="[\"/a/x\"]")
}
