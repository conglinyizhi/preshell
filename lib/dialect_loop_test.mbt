///|
/// Loops in zsh: several loop names, the csh spellings, and the brace body that
/// stands in for `do ... done`.
///
/// What the body runs matters more than how it is spelled — `repeat 3 { rm -rf
/// x }` has to report the delete — so each shape here is checked for its effects
/// and not only for whether it parses.

///|
test "zsh takes more than one loop name" {
  // Measured: bash refuses both spellings; zsh splits the list two at a time.
  let cases : Array[String] = [
    "for a b in x y; do echo $a; done", "for a b c in x y z; do echo $a; done", "for a b; do echo $a; done",
    "for pattern arg in \\\n  a b c; do\n  echo $pattern\ndone",
  ]
  for c in cases {
    debug_inspect(zstatus(c), content="Complete")
    debug_inspect(@lib.analyze(c).status, content="Unsupported")
  }
  // One name stays common ground.
  debug_inspect(zstatus("for a in x y; do echo $a; done"), content="Complete")
  debug_inspect(
    @lib.analyze("for a in x y; do echo $a; done").status,
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
  // A spelled-out list is a closed set, so the loop name holds each word in
  // turn and the body is audited once per word.
  inspect(ztouched("for x ( a b ); do rm -rf $x; done"), content="D:a D:b")
  // bash has neither form.
  debug_inspect(
    @lib.analyze("for x ( a b ); do :; done").status,
    content="Unsupported",
  )
  // In zsh the csh spelling may also take its body with no `do` at all, and the
  // body ends at the first `;` or newline that is not inside a nested construct.
  // Measured against zsh 5.9.2 for every line here.
  debug_inspect(zstatus("for x (a b) echo $x"), content="Complete")
  inspect(ztouched("for x (a b) rm $x"), content="D:a D:b")
  debug_inspect(zstatus("for x (a b)\nrm $x"), content="Complete")
  // The `;` after the word list belongs to the loop, not to the caller: zsh
  // prints `two` twice for `for x (a b); echo two`.
  inspect(ztouched("for x (a b); rm $x"), content="D:a D:b")
  // What follows the body runs once, so the second `rm $x` is outside the loop
  // and names nothing (the loop name is dropped after it).
  inspect(ztouched("for x (a b) rm $x; rm $x"), content="D:a D:b D:$x U:$x")
  // A chain is part of the body, while `&` ends it and backgrounds the loop.
  inspect(ztouched("for x (a b) rm f && rm $x"), content="D:f D:a D:b")
  inspect(ztouched("for x (a b) rm f & rm g"), content="D:f D:g")
  // A nested construct keeps its own separators: zsh runs `if` per word.
  inspect(ztouched("for x (a b) if true; then rm $x; fi"), content="D:a D:b")
  // No body at all is legal there and runs nothing.
  debug_inspect(zstatus("for x (a b)"), content="Complete")
  // bash refuses every one of those shapes.
  debug_inspect(@lib.analyze("for x (a b) rm $x").status, content="Unsupported")
  debug_inspect(@lib.analyze("for x (a b)").status, content="Unsupported")
  // bash has no `repeat`, so this is only a command named repeat followed by a
  // group -- which it accepts (bash -n rc=0), so Complete is the honest answer.
  debug_inspect(@lib.analyze("repeat 3 { echo hi }").status, content="Complete")
  // The classic shapes stay common ground.
  debug_inspect(zstatus("for x in a b; do echo $x; done"), content="Complete")
  debug_inspect(zstatus("for ((i=0;i<3;i++)); do :; done"), content="Complete")
  debug_inspect(
    @lib.analyze("for x in a b; do echo $x; done").status,
    content="Complete",
  )
}

///|
test "a brace body belongs to an if, a while or an until" {
  // Measured against zsh 5.9.2. The judge is zsh's `incmdpos`: the `{` counts
  // only at a command position -- after a compound command, after an assignment
  // or at the start -- and the condition list has to stop and hand it over.
  // Accepting `if true { : }` by mistake would be the same class of error as
  // the corpus's "too lenient" quadrant, so the rejects are pinned too.
  let accepts : Array[String] = [
    "if [[ x ]] { : }", "if (( 1 )) { : }", "if x=1 { : }", "while (true) { : }",
    "while { true } {}", "while true; { : }", "for i in a; { : }", "for x (a b) { : }",
  ]
  for c in accepts {
    debug_inspect(zstatus(c), content="Complete")
    // bash refuses every one of these: there `{ : }` needs a separator before
    // the closing brace (`{ :; }`), so reading them as bash must say so.
    debug_inspect(@lib.analyze(c).status, content="Unsupported")
  }
  // The body is audited, not merely accepted.
  inspect(ztouched("if [[ x ]] { rm -rf /tmp/ifx }"), content="D:/tmp/ifx")
  inspect(ztouched("if x=1 { rm -rf /tmp/asx }"), content="D:/tmp/asx")
  inspect(ztouched("while { true } { rm -f /tmp/whx }"), content="D:/tmp/whx")
  inspect(ztouched("for i in a; { rm -f /tmp/forx }"), content="D:/tmp/forx")
  // The body runs once per word, and both runs say the same thing on the same
  // line, so the report holds that fact once.
  inspect(ztouched("for x (a b) { rm -f /tmp/forf }"), content="D:/tmp/forf")
  inspect(
    ztouched("if [[ x ]] { : } else { rm -f /tmp/elx }"),
    content="D:/tmp/elx",
  )
  // With a brace body the `fi` of the ordinary spelling is not required, and
  // an `if` chain may mix the two.
  debug_inspect(zstatus("if [[ x ]] { : } fi"), content="Complete")
  debug_inspect(
    zstatus("if [[ x ]] { : } elif [[ y ]] { : }"),
    content="Complete",
  )
  debug_inspect(zstatus("if [[ x ]] { : } else { : }"), content="Complete")
  debug_inspect(zstatus("if x; then :; else { : }; fi"), content="Complete")
  // The empty group: zsh closes the brackets and is at a command position
  // again, so `{}` there is two tokens and not one word.
  debug_inspect(zstatus("if [[ x ]] {}"), content="Complete")
  debug_inspect(zstatus("while { true } {}"), content="Complete")
  // The rejects: every one of these is a syntax error in zsh as well.
  let rejects : Array[String] = [
    // A plain word leaves the parser outside a command position, so the `{`
    // there is a word and not a body.
    "if true { : }", "while true { : }", "until false { : }",
    // `}` ends the `in` word list, and what follows has to be a separator.
     "for i in a { : }",
    // A separator lets the condition list keep going, so here the group joins
    // the condition and the `if` is then missing its `fi`.
     "if true; { : }",
  ]
  for c in rejects {
    debug_inspect(zstatus(c), content="Unsupported")
  }
  // The words keep their meaning away from a command position.
  debug_inspect(zstatus("echo {a,b}"), content="Complete")
  inspect(ztouched("echo {a,b}"), content="")
  debug_inspect(zstatus("for i in {a,b}; do :; done"), content="Complete")
}

///|
test "zsh wants a separator after a keyword-closed construct" {
  // Measured: zsh 5.9.2 refuses `if for i in a; do :; done then :; fi` while
  // bash 5.3 runs it, so this is the zsh side only. `{ ... }` and `( ... )` need
  // no separator there — neither closes on a keyword — and a `;` fixes the
  // refused shape in both shells.
  debug_inspect(
    zstatus("if for i in a; do :; done then :; fi"),
    content="Unsupported",
  )
  debug_inspect(zstatus("if while :; do :; done then :; fi"), content="Unsupported")
  debug_inspect(zstatus("if if :; then :; fi then :; fi"), content="Unsupported")
  // A redirect after the construct does not change the answer: it is the
  // construct that ends there, and the diagnostic from the differential run was
  // exactly this shape.
  debug_inspect(
    zstatus("if for i in a; do :; done > /tmp/o then :; fi"),
    content="Unsupported",
  )
  debug_inspect(zstatus("if { :; } then :; fi"), content="Complete")
  debug_inspect(zstatus("if ( : ) then :; fi"), content="Complete")
  debug_inspect(zstatus("if for i in a; do :; done; then :; fi"), content="Complete")
}
