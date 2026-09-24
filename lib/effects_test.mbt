///|
fn impact_of(src : String) -> @lib.Impact {
  let (seq, _) = @lib.parse(src)
  @lib.impact(seq)
}

///|
fn targets_of(im : @lib.Impact, kind : @lib.EffectKind) -> Array[String] {
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
  inspect(@lib.parent_dir("build/out.o"), content="build")
  inspect(@lib.parent_dir("a/b/"), content="a/b")
  inspect(@lib.parent_dir("x"), content=".")
  inspect(@lib.parent_dir("/etc/passwd"), content="/etc")
  inspect(@lib.parent_dir("./a/../b/c"), content="b")
}

///|
test "a program we do not model is reported instead of ignored" {
  // `rustc`'s writes are decided at run time. The answer is not "no writes":
  // it is "this ran, and everything below is a lower bound". (`make` used to
  // serve as this example; it now has a branch of its own in lib/tools.mbt.)
  let im = impact_of("rustc -O x.rs")
  debug_inspect(im.uncertain, content="true")
  debug_inspect(targets_of(im, Exec), content="[\"rustc\"]")
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

///|
test "a hash inside arithmetic is an operand, not a comment" {
  // Measured: both bash and zsh parse `(( 1 + 2 # c ))` and `(( #x == 97 ))`
  // (zsh reads `#x` as the character code of the first character). Reading the
  // `#` as a comment left the arithmetic open, so both dialects reported a gap.
  debug_inspect(@lib.analyze("(( 1 + 2 # c ))").status, content="Complete")
  inspect(ztouched("x=abc; (( #x == 97 ))"), content="")
  debug_inspect(@lib.analyze("(( ##$chr ))").status, content="Complete")
  // Outside arithmetic the comment still hides what follows, which is what
  // keeps the flag from leaking past the closing parens.
  inspect(touched("echo a # > /tmp/x"), content="")
  inspect(touched("(( i++ )) ; echo a # > /tmp/x"), content="")
  inspect(touched("echo a > /tmp/x # so what"), content="W:/tmp/x")
}

///|
test "a quoted double bracket is a string, not a condition" {
  // The `[[` keyword rule is positional and quote-sensitive: inside quotes it
  // is ordinary text. Missing the quote guard made `x="[[y]"` a parse failure
  // in both dialects, which zsh accepts.
  debug_inspect(@lib.analyze("x=\"[[y]\"").status, content="Complete")
  debug_inspect(
    @lib.analyze_dialect("x=\"[[y]\"", Zsh).status,
    content="Complete",
  )
  debug_inspect(@lib.analyze("echo \"[[y]\"").status, content="Complete")
  // The keyword itself still works, and a bracket expression still globs.
  debug_inspect(
    @lib.analyze("if [[ \"$x\" == a ]] then :; fi").status,
    content="Complete",
  )
  inspect(touched("rm [[:alpha:]]"), content="D:[[:alpha:]] U:[[:alpha:]]")
}

///|
test "a command substitution inside [[ ]] still runs" {
  // The condition text is opaque, but `$(...)` in it is a real command. This
  // used to report Complete with no effects at all.
  inspect(
    touched("[[ -f \"$(cat /tmp/secret.txt)\" ]]"),
    content="R:/tmp/secret.txt",
  )
  inspect(touched("[[ -n $(cat a) && $(cat b) ]]"), content="R:a R:b")
  // A condition with no substitution stays quiet.
  inspect(touched("[[ -f x ]]"), content="")
  debug_inspect(@lib.analyze("[[ -f x ]]").status, content="Complete")
}

///|
test "quotes make process substitution and globs literal" {
  // Measured: inside double quotes a `<( )` and a `*`/`[` are ordinary text.
  // We used to see a process substitution and a glob there, which invented a
  // command (`echo "<(a)"` reported Exec a) and turned `rm "*"` into a pattern.
  inspect(touched("echo \"<(a)\""), content="")
  inspect(touched("rm \"*\""), content="D:*")
  debug_inspect(
    @lib.analyze_dialect("local a=\"<({[\" b=\">)}]\"", Zsh).status,
    content="Complete",
  )
  // Unquoted, both are what they look like.
  inspect(touched("rm *"), content="D:* U:*")
  inspect(touched("cat <(echo hi)"), content="R:<() U:<()")
  inspect(touched("echo \"$(cat x)\""), content="R:x U:$()")
}
