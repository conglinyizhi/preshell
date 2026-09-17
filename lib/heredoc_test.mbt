///|
/// Here-document regressions. Two of these guard against bugs that were worse
/// than a wrong answer: a missing terminator that silently turns the rest of
/// the input into body, which would make the audit report a clean result for a
/// region it never looked at.
fn seq_of(src : String) -> Seq {
  parse(src).0
}

///|
test "`<<-` strips tabs from the delimiter as well as the body" {
  // bash: `cat <<-'<tab>END'` is closed by a `<tab>END` line. Comparing the
  // terminator against an unstripped delimiter means never matching, and the
  // rest of the file silently becomes here-document body.
  let src = "cat <<-'\tEND'\n\thello\n\tEND\necho done\n"
  let seq = seq_of(src)
  inspect(seq.items.length(), content="2")
  match first_cmd(src) {
    Cmd::Simple(s) =>
      debug_inspect(s.redirects[0].body, content="Some(\"hello\\n\")")
    _ => fail("expected a simple command")
  }
}

///|
test "a command substitution may close the delimiter line" {
  // `x=$(cat <<EOF ... EOF)` -- the `)` belongs to the substitution.
  let src = "foo=$(cat <<EOF\nhi\nEOF)\necho $foo\n"
  debug_inspect(status_of_construct(src), content="Complete")
  inspect(seq_of(src).items.length(), content="2")
  // Same with a space before the close.
  debug_inspect(
    status_of_construct("foo=$(cat <<EOF\nhi\nEOF )\n"),
    content="Complete",
  )
}

///|
test "a here-document that runs into end of input matches bash" {
  debug_inspect(status_of_construct("cat <<EOF\nhi"), content="Complete")
}

///|
test "unclosed constructs are not silently accepted" {
  // bash rejects all of these; before this was fixed the parser treated end of
  // input as a valid closer for every construct.
  let cases = [
    "(echo a", "{ echo a;", "if true; then echo x", "while true; do echo x", "for i in a; do echo x",
    "case x in a) echo y", "f() { echo x;", "echo $(date",
  ]
  for src in cases {
    let r = analyze(src)
    if r.status is Complete {
      fail("accepted an unclosed construct: \{src}")
    }
    if r.issues.length() == 0 {
      fail("no issue reported for an unclosed construct: \{src}")
    }
  }
}
