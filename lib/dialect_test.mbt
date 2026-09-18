///|
/// The zsh dialect.
///
/// zsh is a different grammar, not a set of extensions on top of bash, so these
/// tests are about the places where the two genuinely disagree: a parenthesis in
/// word position is a glob there, `}` closes a group without a separator, and
/// `always` has no bash equivalent at all. The bash side of each pair is checked
/// too, because the whole point is that one shell's syntax must not silently be
/// read with the other's rules.
///
/// Codes as in commands_test.mbt: R read, W write, D delete, N network,
/// S spawn, U unknown.
fn ztouched(src : String) -> String {
  let r = analyze_dialect(src, Zsh)
  let parts : Array[String] = []
  for e in r.impact.effects {
    let tag = match e.kind {
      Exec => ""
      Read => "R"
      Write => "W"
      Delete => "D"
      Net => "N"
      Spawn => "S"
      Unknown => "U"
    }
    if tag != "" {
      parts.push(tag + ":" + e.target)
    }
  }
  parts.join(" ")
}

///|
fn zstatus(src : String) -> ParseStatus {
  analyze_dialect(src, Zsh).status
}

///|
test "a shell name maps to a dialect, or to nothing we can read" {
  debug_inspect(Dialect::from_shell_name("zsh"), content="Some(Zsh)")
  debug_inspect(Dialect::from_shell_name("bash"), content="Some(Bash)")
  debug_inspect(Dialect::from_shell_name("dash"), content="Some(Bash)")
  // Not "bash by default": an unmodelled shell is its own answer.
  debug_inspect(Dialect::from_shell_name("fish"), content="None")
  debug_inspect(Dialect::from_shell_name("python3"), content="None")
}

///|
test "a parenthesis in word position is a glob in zsh and an error in bash" {
  // Measured against zsh 5.9.2: every one of these runs, and the parentheses
  // are a glob qualifier or pattern group rather than a subshell.
  let cases : Array[String] = [
    "echo *(.)", "echo a(b)", "echo foo(N)", "echo *(N:P)", "echo foo(A|B)", "echo (#i)bar",
    "echo x(.)y",
  ]
  for c in cases {
    debug_inspect(zstatus(c), content="Complete")
    // bash refuses all of them, so reading them as bash must say so.
    debug_inspect(analyze(c).status, content="Unsupported")
  }
}

///|
test "a group is word content, so its parens do not split the word" {
  // zsh: `(a b)` and `(a|b)` are single words, which is why a blank or a pipe
  // inside the group does not end it.
  debug_inspect(zstatus("echo (a b)"), content="Complete")
  debug_inspect(zstatus("echo (a|b)"), content="Complete")
  debug_inspect(zstatus("echo ((a))"), content="Complete")
  debug_inspect(zstatus("echo 3( )"), content="Complete")
  // `;` still ends the word, so this is unbalanced in zsh too.
  debug_inspect(zstatus("echo (a;b)"), content="Unsupported")
  // An unclosed group parses (zsh only fails at glob time), so it must not be
  // reported as a syntax error.
  debug_inspect(zstatus("echo (b"), content="Complete")
}

///|
test "a paren group is reported as a pattern, not as a literal path" {
  // `rm (a|b)` deletes the files matching a or b. Reporting the text as a
  // literal path would be a wrong answer rather than a missing one.
  inspect(ztouched("rm (a|b)"), content="D:(a|b) U:(a|b)")
  let r = analyze_dialect("rm (a|b)", Zsh)
  inspect(r.impact.uncertain, content="true")
}

///|
test "a subshell is still a subshell" {
  // Command position is unchanged: the `(` there opens a subshell in zsh too,
  // and its contents are audited as commands rather than as a word.
  debug_inspect(zstatus("(echo x)"), content="Complete")
  inspect(ztouched("(cd /tmp && rm x)"), content="D:/tmp/x")
}

///|
test "zsh closes a group without a separator before the brace" {
  // Measured: `{ echo a }` runs in zsh and is a syntax error in bash, because
  // zsh reads `}` as a reserved word even in argument position.
  debug_inspect(zstatus("{ echo a }"), content="Complete")
  debug_inspect(analyze("{ echo a }").status, content="Unsupported")
  debug_inspect(zstatus("{ echo a; }"), content="Complete")
  debug_inspect(
    zstatus("if x && { y || z }; then\n  e\nfi"),
    content="Complete",
  )
  // Consequence of the same rule: a stray `}` outside a group is an error in
  // zsh, so it must not pass as an argument either.
  debug_inspect(zstatus("echo }"), content="Unsupported")
}

///|
test "always runs both blocks" {
  debug_inspect(
    zstatus("{ touch one; } always { touch two; }"),
    content="Complete",
  )
  inspect(
    ztouched("{ touch one; } always { touch two; }"),
    content="W:one W:two",
  )
  // The short form takes a command, not a block.
  debug_inspect(zstatus("{ touch one; } always touch two"), content="Complete")
  inspect(ztouched("{ touch one; } always touch two"), content="W:one W:two")
}

///|
test "function definitions keep working, and only where zsh allows them" {
  debug_inspect(zstatus("foo() { echo x; }"), content="Complete")
  debug_inspect(
    analyze_dialect("foo() { echo x; }", Zsh).status,
    content="Complete",
  )
  // `echo foo()` is a parse error in zsh as well, so it is a gap for us, not a
  // claim that the input is invalid.
  debug_inspect(zstatus("echo foo()"), content="Unsupported")
}

///|
test "naming the dialect we are already reading is not a caveat" {
  // The shebang says zsh and we are reading zsh: nothing to warn about.
  let same = analyze_dialect("#!/bin/zsh\necho hi", Zsh)
  inspect(same.issues.length(), content="0")
  // Reading the same file as bash still warns: that is the claim the note is
  // there to bound.
  let other = analyze_dialect("#!/bin/zsh\necho hi", Bash)
  debug_inspect(other.status, content="Unsupported")
  inspect(other.issues.length(), content="1")
  // A shell nobody models stays a caveat in either dialect.
  let fish = analyze_dialect("#!/usr/bin/fish\necho hi", Zsh)
  debug_inspect(fish.status, content="Unsupported")
}

///|
test "syntax evidence is per dialect" {
  // The one corroborated message was measured against bash. zsh accepts two of
  // the files that produced it, so under zsh the table is empty and nothing may
  // be upgraded to Invalid.
  inspect(syntax_evidence(Bash).length(), content="1")
  inspect(syntax_evidence(Zsh).length(), content="0")
}

///|
test "zsh's =() writes a temporary file, and its command still runs" {
  // Measured: `cat =(echo hi)` runs echo, leaves a real file under /tmp named
  // zshXXXXXX, and passes that path to cat. The name cannot be known in
  // advance, so the template is reported and flagged uncertain.
  debug_inspect(zstatus("cat =(echo hi)"), content="Complete")
  inspect(ztouched("cat =(echo hi)"), content="W:/tmp/zshXXXXXX R:=() U:=()")
  inspect(
    analyze_dialect("cat =(echo hi)", Zsh).impact.write_roots.join(" "),
    content="/tmp",
  )
  // An assignment takes the same path: the file is created either way.
  inspect(ztouched("x==(echo hi)"), content="W:/tmp/zshXXXXXX")
  // `name=(a b)` is an array, not a process substitution, so nothing is written.
  inspect(ztouched("a=(1 2)"), content="")
  debug_inspect(zstatus("a=(1 2)"), content="Complete")
  // Quoted, it is literal text in zsh too.
  inspect(ztouched("echo \"=(echo hi)\""), content="")
  // A pipe is not a file, so `<( )` reports the shape and no write.
  inspect(ztouched("cat <(echo hi)"), content="R:<() U:<()")
  // bash has no construct here at all.
  debug_inspect(analyze("cat =(echo hi)").status, content="Unsupported")
}

///|
test "zsh's numeric glob is a pattern, not a redirection" {
  // Measured: `echo <1->` prints a glob error in zsh rather than redirecting,
  // and the rule in zsh's isnumglob() is `<` digits `-` digits `>`, with both
  // digit runs allowed to be empty. It applies anywhere in a word.
  debug_inspect(zstatus("echo <1->"), content="Complete")
  inspect(ztouched("echo <1->"), content="U:<1->")
  inspect(ztouched("echo a<1->b"), content="U:a<1->b")
  debug_inspect(zstatus("echo <->"), content="Complete")
  // No closing `>` means it is an ordinary redirection and the target is a
  // literal file name.
  inspect(ztouched("cat <1-3"), content="R:1-3")
  inspect(ztouched("cat <x-y"), content="R:x-y")
  // In a case pattern, which is where it shows up in real scripts.
  debug_inspect(
    zstatus("case $x in\n  (<1->|\\*) a[1]=$1;;\nesac"),
    content="Complete",
  )
  // bash reads the same text as a redirection and refuses it.
  debug_inspect(
    analyze("case 1 in <1-10>) echo y;; esac").status,
    content="Unsupported",
  )
}

///|
test "a brace inside an expansion nests only when zsh is not quoting" {
  // Measured, same text in both shells and both quotings:
  //   zsh  ${a//b/X{Y}/Z}     the expansion runs to the last }
  //   zsh  "${a//b/X{Y}/Z}"   it ends at the first one
  //   bash both spellings     it ends at the first one
  // Getting this wrong is not cosmetic: the wrong branch swallows the closing
  // quote and turns a working script into a reported gap.
  debug_inspect(zstatus("echo \"${a//b/X{Y}/Z}\""), content="Complete")
  debug_inspect(zstatus("echo ${a//b/X{Y}/Z}"), content="Complete")
  debug_inspect(zstatus("echo ${a:-{}}"), content="Complete")
  debug_inspect(analyze("echo ${a//b/X{Y}/Z}").status, content="Complete")
  // Both branches are pinned by a line from the corpus: this one comes from
  // Completion/Base/Completer/_expand, is unquoted, and has an escaped brace
  // inside a pattern group. Without the brace counting it ends early and the
  // rest of the pattern is read as shell syntax.
  debug_inspect(
    zstatus(
      "tmp=${tmp//(#b)\\\\\\$\\\\\\{(([^\\{\\}]|\\\\\\\\{|\\\\\\\\})#)([^\\\\])\\\\\\}/\\\\$\\\\\\\\{${match[1]}${match[3]}\\\\\\\\}}",
    ),
    content="Complete",
  )
}

///|
test "an array element may start with a parenthesis" {
  // The elements of `name=( ... )` are words, so a `(` inside one is a pattern.
  // Measured: without that, `argv+=( (a|b) )` read the element as a subshell and
  // then choked on the closing paren. 127 files in the corpus died this way,
  // always reported at a line holding a lone `)`.
  debug_inspect(zstatus("true; argv+=( (a|b) )"), content="Complete")
  debug_inspect(
    zstatus("if true; then\n  argv+=(\n    (a)\n  )\nfi"),
    content="Complete",
  )
  debug_inspect(zstatus("argv+=( (a|b) )"), content="Complete")
  debug_inspect(zstatus("a=(1 2)"), content="Complete")
  debug_inspect(zstatus("a=()"), content="Complete")
  // A plain word before a pattern must not look like an array head: this is
  // what the trailing `=` check in the shape test is for.
  debug_inspect(zstatus("echo a(b)"), content="Complete")
  inspect(ztouched("echo a(b)"), content="U:a(b)")
  // And the array opener still leaves the following commands alone.
  debug_inspect(zstatus("a=(1 2); echo (x)"), content="Complete")
}

///|
test "zsh spells case fallthrough ;| and refuses bash's ;;&" {
  // Measured: `;|` keeps testing the following patterns (zsh's
  // WC_CASE_TESTAND, the same job as bash's `;;&`), `;&` falls through without
  // testing, and zsh rejects `;;&` outright.
  debug_inspect(
    zstatus("case gnu in\ngnu) echo A ;| linux) echo B ;;\nesac"),
    content="Complete",
  )
  debug_inspect(
    zstatus("case gnu in\ngnu) echo A ;& linux) echo B ;;\nesac"),
    content="Complete",
  )
  debug_inspect(
    zstatus("case gnu in\ngnu) echo A ;;& linux) echo B ;;\nesac"),
    content="Unsupported",
  )
  // bash takes `;;&` and has no `;|`.
  debug_inspect(
    analyze("case gnu in\ngnu) echo A ;;& linux) echo B ;;\nesac").status,
    content="Complete",
  )
  debug_inspect(
    analyze("case gnu in\ngnu) echo A ;| linux) echo B ;;\nesac").status,
    content="Unsupported",
  )
}

///|
test "a case pattern is a word, so its parens are a glob group" {
  // zsh's `incasepat`: `(net|open)bsd*)` is one pattern. Reading the leading
  // `(` as the pattern list's own paren split it in two and choked.
  let cases : Array[String] = [
    "case $x in\n  (net|open)bsd*) echo hi ;;\nesac", "case $x in\n  (un|)install) echo hi ;;\nesac",
    "case $x in\n  (gnu) echo hi ;;\nesac", "case $x in\n  user:add:(^solaris2.<-10>)) echo hi ;;\nesac",
  ]
  for c in cases {
    debug_inspect(zstatus(c), content="Complete")
  }
  // The body is a command list again, so a subshell there still parses.
  debug_inspect(
    zstatus("case $x in\n  gnu) (echo hi) ;;\nesac"),
    content="Complete",
  )
  debug_inspect(
    zstatus("(echo a); case $x in a) echo b;; esac"),
    content="Complete",
  )
}

///|
test "zsh takes more than one loop name" {
  // Measured: bash refuses both spellings; zsh splits the list two at a time.
  let cases : Array[String] = [
    "for a b in x y; do echo $a; done", "for a b c in x y z; do echo $a; done", "for a b; do echo $a; done",
    "for pattern arg in \\\n  a b c; do\n  echo $pattern\ndone",
  ]
  for c in cases {
    debug_inspect(zstatus(c), content="Complete")
    debug_inspect(analyze(c).status, content="Unsupported")
  }
  // One name stays common ground.
  debug_inspect(zstatus("for a in x y; do echo $a; done"), content="Complete")
  debug_inspect(
    analyze("for a in x y; do echo $a; done").status,
    content="Complete",
  )
}

///|
test "zsh's csh forms for and repeat run their body for real" {
  // `for x ( a b ) body` and `repeat N body` are zsh only; bash refuses both.
  // The point of these assertions is that the body is *audited*: before this,
  // `repeat 3 { rm -rf /tmp/x }` reported the word `repeat` and nothing else.
  debug_inspect(zstatus("for x ( a b ); do echo $x; done"), content="Complete")
  debug_inspect(zstatus("for x (a b) { echo $x }"), content="Complete")
  debug_inspect(zstatus("repeat 3 { echo hi }"), content="Complete")
  debug_inspect(zstatus("repeat $n do echo hi done"), content="Unsupported")
  inspect(ztouched("repeat 3 { rm -rf /tmp/x }"), content="D:/tmp/x")
  inspect(ztouched("for x ( a b ); do rm -rf $x; done"), content="D:$x U:$x")
  // bash has neither form.
  debug_inspect(
    analyze("for x ( a b ); do :; done").status,
    content="Unsupported",
  )
  // bash has no `repeat`, so this is only a command named repeat followed by a
  // group -- which it accepts (bash -n rc=0), so Complete is the honest answer.
  debug_inspect(analyze("repeat 3 { echo hi }").status, content="Complete")
  // The classic shapes stay common ground.
  debug_inspect(zstatus("for x in a b; do echo $x; done"), content="Complete")
  debug_inspect(zstatus("for ((i=0;i<3;i++)); do :; done"), content="Complete")
  debug_inspect(
    analyze("for x in a b; do echo $x; done").status,
    content="Complete",
  )
}

///|
test "zsh spells the clobber redirect with a bang, bash does not" {
  // Measured: every one of these writes the file `out` in zsh and a file called
  // `!` in bash. Reporting zsh's `>!` as a write to a file named `!` is a wrong
  // answer in the Complete quadrant, which the corpus cannot see at all.
  for
    c in ["echo a >! out", "echo a >>! out", "echo a >&! out", "echo a &>! out"] {
    inspect(ztouched(c), content="W:out")
    inspect(touched(c), content="W:!")
  }
  // The suffix sits after the fd prefix as well.
  inspect(ztouched("echo a 2>! out"), content="W:out")
  // Plain redirects are unaffected in both dialects.
  inspect(ztouched("echo a > out"), content="W:out")
  inspect(touched("echo a > out"), content="W:out")
}

///|
test "zsh's anonymous function runs its body with its arguments" {
  // Measured: `() { echo $# } one two three` prints 3 in zsh, and bash refuses
  // every one of these forms. The body is audited because it runs right there.
  debug_inspect(zstatus("() { echo hi }"), content="Complete")
  debug_inspect(zstatus("(){ echo hi }"), content="Complete")
  debug_inspect(zstatus("() { echo $1 $2 } a b"), content="Complete")
  debug_inspect(zstatus("() if true; then echo yes; fi"), content="Complete")
  debug_inspect(zstatus("() (echo sub)"), content="Complete")
  inspect(ztouched("() { rm -rf /tmp/anonx } one two"), content="D:/tmp/anonx")
  // A command substitution in the arguments is a command that runs.
  inspect(ztouched("() { echo $1 } $(rm -rf /tmp/y)"), content="U:$1 D:/tmp/y")
  inspect(ztouched("() { cat a } > /tmp/o"), content="R:a W:/tmp/o")
  // `( )` with a space is an empty subshell, and zsh refuses the word after it.
  debug_inspect(zstatus("( ) { echo hi }"), content="Unsupported")
  // No body at all is refused by zsh as well.
  debug_inspect(zstatus("()"), content="Unsupported")
  // bash has no anonymous function: every form above is a syntax error there.
  for c in ["() { echo hi }", "(){ echo hi }", "() (echo sub)"] {
    debug_inspect(analyze(c).status, content="Unsupported")
  }
  // An empty subshell with a body word is still fine where the shells agree.
  debug_inspect(zstatus("( : )"), content="Complete")
}

///|
test "the conditional keyword is a word, not a bracket expression" {
  // `[[` at command position was read as a glob bracket, so the whole
  // condition became a single command word and `if [[ ... ]] then` fell apart.
  // Measured: bash and zsh agree on all of these.
  debug_inspect(zstatus("if [[ \"$x\" == a ]] then :; fi"), content="Complete")
  debug_inspect(
    analyze("if [[ \"$x\" == a ]] then :; fi").status,
    content="Complete",
  )
  debug_inspect(zstatus("if [[ -f x ]] then :; fi"), content="Complete")
  debug_inspect(zstatus("if [[ $x == a ]] then :; fi"), content="Complete")
  debug_inspect(zstatus("[[ \"$x\" == a ]] && echo y"), content="Complete")
  // A bracket expression in an argument is still a pattern, so the fix must not
  // reach outside command position.
  inspect(ztouched("rm [[:alpha:]]"), content="D:[[:alpha:]] U:[[:alpha:]]")
  debug_inspect(
    zstatus("case x in [[:alpha:]]) echo;; esac"),
    content="Complete",
  )
  // A simple command still needs its separator before `then`.
  debug_inspect(zstatus("if true then :; fi"), content="Unsupported")
}

///|
/// Probe mode: try a chain of grammars and say which one answered.
///
/// The rule these tests pin down is when the dialect counts as an assumption.
/// A script that declares its shell and is read that way is not a caveat; a
/// bare command the two grammars read the same way is not one either; a
/// fallback, or a reading the other grammar disagrees with, is.
test "probe reads a declared zsh script as zsh, quietly" {
  let r = analyze_probe("#!/bin/zsh\necho hi")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="0")
  inspect(r.impact.uncertain, content="false")
  debug_inspect(probe_dialect("#!/bin/zsh\necho hi"), content="Zsh")
}

///|
test "probe falls back to zsh only when bash cannot read the input" {
  // `{ echo a }` is a zsh group and a bash syntax error, so this is the
  // fallback path. The note names the grammar that answered.
  let r = analyze_probe("{ echo a }")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Note")
  inspect(r.issues[0].message.contains("zsh"), content="true")
  inspect(r.impact.uncertain, content="true")
  debug_inspect(probe_dialect("{ echo a }"), content="Zsh")
}

///|
test "probe is quiet when bash is already the grammar" {
  let r = analyze_probe("echo hi")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="0")
  inspect(r.impact.uncertain, content="false")
  debug_inspect(probe_dialect("echo hi"), content="Bash")
}

///|
test "probe names the dialect when both grammars parse but disagree" {
  // `>!` is the measured ambiguity: bash redirects to a file called `!`, zsh
  // redirects to the file that follows. Both readings are Complete, so only the
  // note says which one this report is. The first grammar still wins.
  let r = analyze_probe("echo hi >! /tmp/out")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Note")
  inspect(r.issues[0].message.contains("bash"), content="true")
  inspect(r.issues[0].message.contains("zsh"), content="true")
  inspect(r.impact.uncertain, content="true")
  inspect(r.impact.effects.map(fn(e) { e.target }).join(" "), content="! echo")
}

///|
test "probe overrides a declaration only when that grammar fails" {
  // The file says sh, so bash is the declared grammar; it cannot parse the
  // group and zsh can. The note has to say the answer is not the grammar the
  // file asks for.
  let r = analyze_probe("#!/bin/sh\n{ echo a }")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Note")
  inspect(r.issues[0].message.contains("zsh"), content="true")
}

///|
test "probe returns the first result when nothing parses" {
  // Neither grammar accepts a dangling `then`, and the answer must stay the
  // failure bash produced rather than being dressed up as a success.
  let src = "if true; then"
  let first = analyze(src)
  let r = analyze_probe(src)
  debug_inspect(first.status, content="Unsupported")
  debug_inspect(r.status, content="Unsupported")
  inspect(r.issues.length(), content=first.issues.length().to_string())
  inspect(r.impact.uncertain, content="true")
  debug_inspect(probe_dialect(src), content="Bash")
}

///|
test "probe from bytes takes the same path as probe from text" {
  let r = analyze_bytes_probe(b"echo hi >! /tmp/out\n")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Note")
  inspect(r.impact.uncertain, content="true")
}

///|
test "repeat takes a separator before its body" {
  // zsh's par_repeat skips separators after the count. Without that, the body
  // became separate commands: `repeat 2; do rm -rf /tmp/rp; done` reported two
  // fake Execs and no Delete at all.
  debug_inspect(
    zstatus("repeat 2; do rm -rf /tmp/rp; done"),
    content="Complete",
  )
  inspect(ztouched("repeat 2; do rm -rf /tmp/rp; done"), content="D:/tmp/rp")
  inspect(ztouched("repeat 2; { rm -rf /tmp/rp; }"), content="D:/tmp/rp")
  inspect(ztouched("repeat 2 { rm -rf /tmp/rp; }"), content="D:/tmp/rp")
  inspect(ztouched("repeat 2\ndo rm -rf /tmp/rp; done"), content="D:/tmp/rp")
  // bash has no repeat at all.
  debug_inspect(
    analyze("repeat 2; do rm -rf /tmp/rp; done").status,
    content="Unsupported",
  )
}

///|
test "a backquote is read by the shell that opened it" {
  // The backquoted text was re-lexed with a fresh lexer fixed to bash, so an
  // outer zsh was read with bash words inside. Measured: zsh's `>!` clobbers
  // `f`, while bash's `>!` writes a file literally named `!`. Both parse, so a
  // wrong inner grammar is a wrong effect table under a Complete status.
  inspect(ztouched("x=`echo >! f`"), content="W:f")
  inspect(touched("x=`echo >! f`"), content="W:!")
  // A zsh-only loop is legal inside a backquote, and only for zsh.
  debug_inspect(zstatus("x=`for i j in a b; do :; done`"), content="Complete")
  debug_inspect(
    analyze("x=`for i j in a b; do :; done`").status,
    content="Unsupported",
  )
  // Word-position `(` is zsh's glob qualifier and a bash syntax error.
  debug_inspect(zstatus("x=`echo *(.)`"), content="Complete")
  debug_inspect(analyze("x=`echo *(.)`").status, content="Unsupported")
  // The dialect has to travel through nesting as well.
  inspect(ztouched("x=`cat \\`echo >! g\\``"), content="W:g R:$() U:$()")
}

///|
test "the sibling command substitution already carries the dialect" {
  // `$( )` and `<()` share the open lexer instead of starting a new one, so
  // they were right before this fix. Pin them so the backquote path cannot
  // regress them, and so the two spellings are known to agree.
  inspect(ztouched("x=$(echo >! f)"), content="W:f")
  inspect(touched("x=$(echo >! f)"), content="W:!")
  inspect(ztouched("cat <(echo >! f)"), content="W:f R:<() U:<()")
}
