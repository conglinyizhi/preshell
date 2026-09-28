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
  let r = @lib.analyze_dialect(src, Zsh)
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
fn zstatus(src : String) -> @lib.ParseStatus {
  @lib.analyze_dialect(src, Zsh).status
}

///|
test "a shell name maps to a dialect, or to nothing we can read" {
  debug_inspect(@lib.Dialect::from_shell_name("zsh"), content="Some(Zsh)")
  debug_inspect(@lib.Dialect::from_shell_name("bash"), content="Some(Bash)")
  debug_inspect(@lib.Dialect::from_shell_name("dash"), content="Some(Bash)")
  // Not "bash by default": an unmodelled shell is its own answer.
  debug_inspect(@lib.Dialect::from_shell_name("fish"), content="None")
  debug_inspect(@lib.Dialect::from_shell_name("python3"), content="None")
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
    debug_inspect(@lib.analyze(c).status, content="Unsupported")
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
  let r = @lib.analyze_dialect("rm (a|b)", Zsh)
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
  debug_inspect(@lib.analyze("{ echo a }").status, content="Unsupported")
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
    @lib.analyze_dialect("foo() { echo x; }", Zsh).status,
    content="Complete",
  )
  // `echo foo()` is a parse error in zsh as well, so it is a gap for us, not a
  // claim that the input is invalid.
  debug_inspect(zstatus("echo foo()"), content="Unsupported")
}

///|
test "naming the dialect we are already reading is not a caveat" {
  // The shebang says zsh and we are reading zsh: nothing to warn about.
  let same = @lib.analyze_dialect("#!/bin/zsh\necho hi", Zsh)
  inspect(same.issues.length(), content="0")
  // Reading the same file as bash still warns: that is the claim the note is
  // there to bound.
  let other = @lib.analyze_dialect("#!/bin/zsh\necho hi", Bash)
  debug_inspect(other.status, content="Unsupported")
  inspect(other.issues.length(), content="1")
  // A shell nobody models stays a caveat in either dialect.
  let fish = @lib.analyze_dialect("#!/usr/bin/fish\necho hi", Zsh)
  debug_inspect(fish.status, content="Unsupported")
}

///|
test "syntax evidence is per dialect" {
  // Both corroborated messages were measured against bash: an unclosed `${`,
  // and a seventeenth here-document on one line. zsh accepts files that produce
  // the first, and has no here-document limit at all, so under zsh the table is
  // empty and nothing may be upgraded to Invalid.
  inspect(@lib.syntax_evidence(Bash).length(), content="2")
  inspect(@lib.syntax_evidence(Zsh).length(), content="0")
}

///|
test "zsh's =() writes a temporary file, and its command still runs" {
  // Measured: `cat =(echo hi)` runs echo, leaves a real file under /tmp named
  // zshXXXXXX, and passes that path to cat. The name cannot be known in
  // advance, so the template is reported and flagged uncertain.
  debug_inspect(zstatus("cat =(echo hi)"), content="Complete")
  inspect(ztouched("cat =(echo hi)"), content="W:/tmp/zshXXXXXX R:=() U:=()")
  inspect(
    @lib.analyze_dialect("cat =(echo hi)", Zsh).impact.write_roots.join(" "),
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
  debug_inspect(@lib.analyze("cat =(echo hi)").status, content="Unsupported")
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
    @lib.analyze("case 1 in <1-10>) echo y;; esac").status,
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
  debug_inspect(@lib.analyze("echo ${a//b/X{Y}/Z}").status, content="Complete")
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
test "a lone quote inside an expansion does not eat the closing brace" {
  // The expansion scanner treated every `'` as the start of a quoted string,
  // and a `"` as one that a backslash cannot escape, so an unmatched quote ran
  // past the `}` and turned text zsh accepts into a reported gap. Measured
  // against zsh 5.9.2 and bash 5.3, same text:
  //   zsh   x="${a:-'}"    accepted, the `'` is text inside a quoted expansion
  //   zsh   x=${a:-'}      unmatched '
  //   both  x=${a"b\"c"}   accepted, `\"` does not close the nested quote
  //   both  x=${a"b\"}     unmatched "
  // Two corpus files need this: compinstall line 19 has the lone `'` in a
  // backquoted `q'`, _perforce line 1255 the escaped quote.
  debug_inspect(zstatus("x=\"${a:-'}\""), content="Complete")
  debug_inspect(zstatus("x=\"${a'b}\""), content="Complete")
  debug_inspect(
    zstatus("read -k key\"${1:---- Hit newline or \\`q' to exit --- }\""),
    content="Complete",
  )
  debug_inspect(zstatus("x=${a\"b\\\"c\"}"), content="Complete")
  debug_inspect(zstatus("x=\"${a\"b\\\"c\"}\""), content="Complete")
  // bash has no such rule for `'`: there it opens a quote and the file ends
  // inside it, so the same text read as bash must keep saying so.
  debug_inspect(@lib.analyze("x=\"${a:-'}\"").status, content="Invalid")
  debug_inspect(@lib.analyze("x=${a\"b\\\"c\"}").status, content="Complete")
  // Both shells refuse these, and the scanner must not round them off.
  debug_inspect(zstatus("x=${a:-'}"), content="Unsupported")
  debug_inspect(zstatus("x=${a\"b\\\"}"), content="Unsupported")
  // Guards: the quoting that was already right stays as it was.
  debug_inspect(zstatus("echo \"${a:-'b'}\""), content="Complete")
  debug_inspect(zstatus("echo \"a'b\""), content="Complete")
  debug_inspect(zstatus("echo \"${a:-{}}\""), content="Complete")
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
    debug_inspect(@lib.analyze(c).status, content="Unsupported")
  }
  // An empty subshell with a body word is still fine where the shells agree.
  debug_inspect(zstatus("( : )"), content="Complete")
}

///|
test "zsh's function keyword also spells the anonymous function" {
  // Measured with zsh 5.9.2: `function { echo $1 } extra` prints `extra`, and
  // `function () { echo $1 } extra` does the same, so both are the anonymous
  // function that runs right there -- the same construct as `() { body }`.
  debug_inspect(zstatus("function { echo x }"), content="Complete")
  debug_inspect(zstatus("function { echo $1 } a b"), content="Complete")
  debug_inspect(zstatus("function () { : }"), content="Complete")
  // The body runs and the words after it are the arguments it is called with,
  // so a command substitution in either place is a command that runs.
  inspect(
    ztouched("function { rm -rf /tmp/fnx } one two"),
    content="D:/tmp/fnx",
  )
  inspect(
    ztouched("function { echo $1 } $(rm -rf /tmp/fy)"),
    content="U:$1 D:/tmp/fy",
  )
  inspect(ztouched("function { cat a } > /tmp/fo"), content="R:a W:/tmp/fo")
  // bash refuses the keyword form (`syntax error near 'echo'`), while our bash
  // reading takes the `{` for the name and never sees the `}`. That leniency is
  // older than this form, and it is not what this change is about.
  // A *named* definition takes no argument list: `function foo { : } extra`
  // is a parse error in zsh, and so is a stray `}` where an argument stands.
  debug_inspect(zstatus("function foo { : }"), content="Complete")
  debug_inspect(zstatus("function foo() { : }"), content="Complete")
  debug_inspect(zstatus("foo() { : }"), content="Complete")
  debug_inspect(zstatus("function foo { : } extra"), content="Unsupported")
  debug_inspect(zstatus("function { : } { echo y }"), content="Unsupported")
  debug_inspect(zstatus("() { : } }"), content="Unsupported")
}

///|
test "the conditional keyword is a word, not a bracket expression" {
  // `[[` at command position was read as a glob bracket, so the whole
  // condition became a single command word and `if [[ ... ]] then` fell apart.
  // Measured: bash and zsh agree on all of these.
  debug_inspect(zstatus("if [[ \"$x\" == a ]] then :; fi"), content="Complete")
  debug_inspect(
    @lib.analyze("if [[ \"$x\" == a ]] then :; fi").status,
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
    @lib.analyze("repeat 2; do rm -rf /tmp/rp; done").status,
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
    @lib.analyze("x=`for i j in a b; do :; done`").status,
    content="Unsupported",
  )
  // Word-position `(` is zsh's glob qualifier and a bash syntax error.
  debug_inspect(zstatus("x=`echo *(.)`"), content="Complete")
  debug_inspect(@lib.analyze("x=`echo *(.)`").status, content="Unsupported")
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

///|
test "every sub-parse inherits the dialect it was opened in" {
  // Three entry points re-read a piece of text as shell, and each one used to
  // fall back to bash: a subscript, `eval`, and the backquote form (that one is
  // covered above). `zsh -c '...'` is the exception -- the program named on the
  // command line decides, so it stays zsh even from a bash command line.
  inspect(ztouched("a[`echo >! f`]=1"), content="W:f")
  inspect(touched("a[`echo >! f`]=1"), content="W:!")
  inspect(ztouched("eval 'echo >! f'"), content="W:f")
  inspect(touched("eval 'echo >! f'"), content="W:!")
  inspect(ztouched("zsh -c 'echo >! f'"), content="W:f")
  inspect(touched("zsh -c 'echo >! f'"), content="W:f")
  inspect(ztouched("sh -c 'echo >! f'"), content="W:!")
  inspect(touched("sh -c 'echo >! f'"), content="W:!")
  // Plain sub-commands keep their effects either way.
  inspect(ztouched("a[`cat x`]=1"), content="R:x")
  debug_inspect(
    zstatus("eval 'for i j in a b; do :; done'"),
    content="Complete",
  )
}

///|
test "arithmetic keeps counting every paren, not just the leading ones" {
  // The zsh lexer treated a `(` inside `(( ))` as a pattern group, so the
  // parser's token-based depth count came up short, the expression closed
  // early and the leftover `)` errored. zsh and bash both hand the whole
  // expression to an arithmetic parser, so paren counting has to line up.
  for
    c in [
      "(( a + (b > c) ))", "(( hash += (hash << 5) + ##$chr ))", "(( a + (b & c) ))",
      "(( a + (b | c) ))", "(( a + (b) > (c) ))", "for (( i = (a > b) ? 1 : 2; i < 3; i++ )); do :; done",
    ] {
    debug_inspect(zstatus(c), content="Complete")
    debug_inspect(@lib.analyze(c).status, content="Complete")
  }
  // The failure used to swallow the whole conditional: no Delete at all.
  inspect(
    ztouched("if (( a + (b > c) )); then rm -rf /tmp/x; fi"),
    content="D:/tmp/x",
  )
  inspect(
    ztouched("while (( i + (j > k) )); do rm -rf /tmp/y; i=0; done"),
    content="D:/tmp/y",
  )
}

///|
test "an unmatched right brace is pushed back the way zsh does" {
  // zsh's lexer pushes an unmatched `}` back into the stream (Src/lex.c, the
  // `{foo}` hack), so the brace does not end the word. That is why
  // `f () {echo x}` runs there and `echo a}` is refused, and why a word-ending
  // `}` keeps its literal meaning instead of opening a group.
  debug_inspect(zstatus("f () {echo x}"), content="Complete")
  debug_inspect(zstatus("echo {a,b}"), content="Complete")
  debug_inspect(zstatus("echo {"), content="Complete")
  debug_inspect(zstatus("echo a}"), content="Unsupported")
  debug_inspect(zstatus("echo }"), content="Unsupported")
  // bash has no such rule: there all of these are ordinary text.
  debug_inspect(@lib.analyze("echo a}").status, content="Complete")
  debug_inspect(@lib.analyze("echo {a,b}").status, content="Complete")
  // Guards: brace expansion, the zsh brace parameters and quoting stay intact.
  debug_inspect(zstatus("for i in {1..3}; do :; done"), content="Complete")
  debug_inspect(zstatus("a=({1..3})"), content="Complete")
  debug_inspect(zstatus("echo \"{a,b}\""), content="Complete")
  debug_inspect(zstatus("case x in {a,b}) : ;; esac"), content="Complete")
  inspect(ztouched("echo $${x<y}"), content="U:$${x<y}")
}

///|
test "a function body has to be what the shell wants" {
  // Measured against bash 5.3 and zsh 5.9.2: both refuse `f()` with nothing
  // after it, and bash also refuses a simple command as the body while zsh runs
  // one. Every expectation below is that pair of answers.
  debug_inspect(@lib.analyze("f()").status, content="Unsupported")
  debug_inspect(zstatus("f()"), content="Unsupported")
  debug_inspect(@lib.analyze("f() echo hi").status, content="Unsupported")
  debug_inspect(zstatus("f() echo hi"), content="Complete")
  debug_inspect(
    @lib.analyze("function f echo hi").status,
    content="Unsupported",
  )
  debug_inspect(zstatus("function f echo hi"), content="Complete")
  debug_inspect(
    @lib.analyze("f() cat <<EOF\nbody\nEOF").status,
    content="Unsupported",
  )
  // A compound body is common ground, and the body is audited.
  debug_inspect(@lib.analyze("f() { echo hi; }").status, content="Complete")
  debug_inspect(zstatus("f() { echo hi; }"), content="Complete")
  debug_inspect(@lib.analyze("f() ( echo hi )").status, content="Complete")
  debug_inspect(zstatus("f() ( echo hi )"), content="Complete")
  debug_inspect(
    @lib.analyze("f() if true; then :; fi").status,
    content="Complete",
  )
  debug_inspect(zstatus("f() if true; then :; fi"), content="Complete")
  inspect(touched("f() { rm -rf /tmp/fx; }"), content="D:/tmp/fx")
}
