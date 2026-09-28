///|
/// The `case` construct in zsh: its fallthrough operators, a parenthesised
/// subject, and the pattern that is itself a glob group.
///
/// Every expectation here was measured against zsh 5.9.2 and bash 5.3. The two
/// disagree about all of it, which is why these sit with the dialect tests
/// rather than beside the parser.

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
    @lib.analyze("case gnu in\ngnu) echo A ;;& linux) echo B ;;\nesac").status,
    content="Complete",
  )
  debug_inspect(
    @lib.analyze("case gnu in\ngnu) echo A ;| linux) echo B ;;\nesac").status,
    content="Unsupported",
  )
}

///|
test "a separator may stand between the case subject and its in" {
  // Measured: zsh 5.9.2 takes a run of `;` and newlines between the subject
  // and `in`, bash 5.3 takes newlines only. Real scripts use the `;` spelling
  // (_darcs in the zsh corpus), so both dialects read it rather than giving up
  // on the file.
  let sep = "case $x; in\n  a) rm -rf /tmp/tA ;;\n  b|c) echo hi ;;\nesac"
  let classic = "case $x in\n  a) rm -rf /tmp/tA ;;\n  b|c) echo hi ;;\nesac"
  debug_inspect(zstatus(sep), content="Complete")
  debug_inspect(zstatus(classic), content="Complete")
  debug_inspect(@lib.analyze(classic).status, content="Complete")
  // Accepting the spelling is not enough: the facts have to be the same ones
  // the classic form gives, including the delete buried in a branch.
  inspect(ztouched(sep), content="U:$x D:/tmp/tA")
  inspect(ztouched(classic), content="U:$x D:/tmp/tA")
  // An empty case takes the separator too.
  debug_inspect(zstatus("case x; in esac"), content="Complete")
  // bash has no `;` form: measured, `bash -n` refuses it, so reading it as bash
  // and saying Complete would be a claim the shell does not back up.
  debug_inspect(@lib.analyze(sep).status, content="Unsupported")
  debug_inspect(@lib.analyze("case x; in esac").status, content="Unsupported")
  // `;;` is one token and no separator: zsh refuses this, and so do we.
  debug_inspect(zstatus("case x;;in a) : ;; esac"), content="Unsupported")
  debug_inspect(
    @lib.analyze("case x;;in a) : ;; esac").status,
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
