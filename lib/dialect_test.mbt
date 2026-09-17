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
