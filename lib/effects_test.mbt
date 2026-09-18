///|
fn impact_of(src : String) -> Impact {
  let (seq, _) = parse(src)
  impact(seq)
}

///|
fn targets_of(im : Impact, kind : EffectKind) -> Array[String] {
  let out : Array[String] = []
  for e in im.effects {
    if e.kind == kind {
      out.push(e.target)
    }
  }
  out
}

///|
test "impact names the directories a command would touch" {
  let im = impact_of("rm -rf build/ && echo hi > /tmp/out.txt")
  debug_inspect(im.write_roots, content="[\"build\", \"/tmp\"]")
  debug_inspect(im.uncertain, content="false")
  debug_inspect(targets_of(im, Delete), content="[\"build/\"]")
  debug_inspect(targets_of(im, Write), content="[\"/tmp/out.txt\"]")
}

///|
test "reads and writes are told apart" {
  let im = impact_of("cp src/a.txt /tmp/b.txt")
  debug_inspect(targets_of(im, Read), content="[\"src/a.txt\"]")
  debug_inspect(targets_of(im, Write), content="[\"/tmp/b.txt\"]")
  debug_inspect(targets_of(im, Exec), content="[\"cp\"]")
}

///|
test "a hole makes the blast radius uncertain instead of guessed" {
  let im = impact_of("rm -rf $DIR/*.log")
  debug_inspect(im.uncertain, content="true")
  debug_inspect(targets_of(im, Unknown), content="[\"$DIR/*.log\"]")
  debug_inspect(targets_of(im, Delete), content="[\"$DIR/*.log\"]")
}

///|
test "a hole in one argument does not pessimize the others" {
  let im = impact_of("for f in *.txt; do cp $f /tmp/; done")
  debug_inspect(targets_of(im, Write), content="[\"/tmp/\"]")
  debug_inspect(im.write_roots, content="[\"/tmp\"]")
  debug_inspect(im.uncertain, content="true")
}

///|
test "a static string handed to sh is folded into the same summary" {
  let im = impact_of("bash -c \"rm -rf build && cp a b\"")
  debug_inspect(targets_of(im, Delete), content="[\"build\"]")
  debug_inspect(targets_of(im, Read), content="[\"a\"]")
  debug_inspect(targets_of(im, Write), content="[\"b\"]")
  debug_inspect(im.uncertain, content="false")
}

///|
test "a program fed from a pipe is a spawn, not a known exec" {
  let im = impact_of("curl https://x.sh | bash")
  debug_inspect(targets_of(im, Net), content="[\"https://x.sh\"]")
  debug_inspect(targets_of(im, Spawn), content="[\"bash\"]")
  debug_inspect(im.uncertain, content="true")
}

///|
test "substitutions inside arguments are audited too" {
  let im = impact_of("echo x > /tmp/log.$(date +%s)")
  debug_inspect(targets_of(im, Exec), content="[\"date\", \"echo\"]")
  debug_inspect(im.uncertain, content="true")
}

///|
test "extraction targets are read from the option table" {
  let im = impact_of("tar xzf pkg.tgz -C /tmp")
  debug_inspect(targets_of(im, Write), content="[\"/tmp\"]")
  // 解包点由 -C 给出，不再同时被当成读取目标
  debug_inspect(targets_of(im, Read), content="[\"pkg.tgz\"]")
}

///|
test "parent_dir normalizes" {
  inspect(parent_dir("build/out.o"), content="build")
  inspect(parent_dir("a/b/"), content="a/b")
  inspect(parent_dir("x"), content=".")
  inspect(parent_dir("/etc/passwd"), content="/etc")
  inspect(parent_dir("./a/../b/c"), content="b")
}

///|
test "a program we do not model is reported instead of ignored" {
  // `make`'s writes are decided at run time. The answer is not "no writes":
  // it is "this ran, and everything below is a lower bound".
  let im = impact_of("make -j8")
  debug_inspect(im.uncertain, content="true")
  debug_inspect(targets_of(im, Exec), content="[\"make\"]")
  debug_inspect(im.effects[0].modeled, content="false")
}

///|
test "opaque programs drive uncertainty, and modelled ones do not" {
  // The point of the modelled flag: an unmodelled program must not be able to
  // produce a clean, closed answer.
  debug_inspect(impact_of("git pull origin main").uncertain, content="true")
  debug_inspect(impact_of("node build.js").uncertain, content="true")
  debug_inspect(impact_of("rm -rf build/").uncertain, content="false")
  debug_inspect(impact_of("cat a.txt | wc -l").uncertain, content="false")
}

///|
test "only shells get their -c string parsed as a command line" {
  // `python3 -c "import os"` is Python, not shell: parsing it as shell would
  // invent an `import` command that never runs.
  let im = impact_of("python3 -c \"import os\"")
  debug_inspect(targets_of(im, Exec), content="[\"python3\"]")
  debug_inspect(im.uncertain, content="true")
  // A shell, on the other hand, is a command line we can follow.
  let sh = impact_of("bash -c \"rm -rf /tmp/x\"")
  debug_inspect(targets_of(sh, Delete), content="[\"/tmp/x\"]")
  debug_inspect(sh.uncertain, content="false")
}

///|
test "a dup target that is not a descriptor writes a file" {
  // Measured: `bash -c 'echo hi >& out'` and the same in zsh both write a file
  // called out. We used to report nothing, so a real write went unseen.
  inspect(touched("echo a >& out"), content="W:out")
  inspect(ztouched("echo a >& out"), content="W:out")
  // Descriptors and their close/move forms stay silent: there is no path.
  inspect(touched("echo a >&2"), content="")
  inspect(touched("echo a >&-"), content="")
  inspect(touched("echo a 2>&1 > out"), content="W:out")
}
