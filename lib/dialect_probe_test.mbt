///|
/// Probe mode: try a chain of grammars and say which one answered.
///
/// The rule these tests pin down is when the dialect counts as an assumption. A
/// script that declares its shell and is read that way is not a caveat; a bare
/// command the two grammars read the same way is not one either; a fallback, or
/// a reading the other grammar disagrees with, is.

///|
/// Probe mode: try a chain of grammars and say which one answered.
///
/// The rule these tests pin down is when the dialect counts as an assumption.
/// A script that declares its shell and is read that way is not a caveat; a
/// bare command the two grammars read the same way is not one either; a
/// fallback, or a reading the other grammar disagrees with, is.
test "probe reads a declared zsh script as zsh, quietly" {
  let r = @lib.analyze_probe("#!/bin/zsh\necho hi")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="0")
  inspect(r.impact.uncertain, content="false")
  debug_inspect(@lib.probe_dialect("#!/bin/zsh\necho hi"), content="Zsh")
}

///|
test "probe falls back to zsh only when bash cannot read the input" {
  // `{ echo a }` is a zsh group and a bash syntax error, so this is the
  // fallback path. The note names the grammar that answered.
  let r = @lib.analyze_probe("{ echo a }")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Note")
  inspect(r.issues[0].message.contains("zsh"), content="true")
  inspect(r.impact.uncertain, content="true")
  debug_inspect(@lib.probe_dialect("{ echo a }"), content="Zsh")
}

///|
test "probe is quiet when bash is already the grammar" {
  let r = @lib.analyze_probe("echo hi")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="0")
  inspect(r.impact.uncertain, content="false")
  debug_inspect(@lib.probe_dialect("echo hi"), content="Bash")
}

///|
test "probe names the dialect when both grammars parse but disagree" {
  // `>!` is the measured ambiguity: bash redirects to a file called `!`, zsh
  // redirects to the file that follows. Both readings are Complete, so only the
  // note says which one this report is. The first grammar still wins.
  let r = @lib.analyze_probe("echo hi >! /tmp/out")
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
  let r = @lib.analyze_probe("#!/bin/sh\n{ echo a }")
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
  let first = @lib.analyze(src)
  let r = @lib.analyze_probe(src)
  debug_inspect(first.status, content="Unsupported")
  debug_inspect(r.status, content="Unsupported")
  inspect(r.issues.length(), content=first.issues.length().to_string())
  inspect(r.impact.uncertain, content="true")
  debug_inspect(@lib.probe_dialect(src), content="Bash")
}

///|
test "probe from bytes takes the same path as probe from text" {
  let r = @lib.analyze_bytes_probe(b"echo hi >! /tmp/out\n")
  debug_inspect(r.status, content="Complete")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Note")
  inspect(r.impact.uncertain, content="true")
}
