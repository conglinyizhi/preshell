///|
/// Candidate sets: the paths a hole could be, when the command line left a name
/// with more than one possible value.
///
/// This is the answer to the oldest hole in the report — `if c; then x=a; else
/// x=b; fi; rm $x` deletes one of two paths — without claiming that both happen.
/// The target stays the hole it was; `candidates` is a set of *possibilities*.
///
/// Every expectation was measured against bash 5.3 first.

///|
fn kind_tag(k : @lib.EffectKind) -> String {
  match k {
    Exec => "Exec"
    Read => "Read"
    Write => "Write"
    Delete => "Delete"
    Net => "Net"
    Spawn => "Spawn"
    Unknown => "Unknown"
  }
}

///|
/// Each effect that has candidates, as `Kind:target[one|two]`.
fn candidate_list(src : String) -> String {
  let r = @lib.analyze(src)
  let parts : Array[String] = []
  for e in r.impact.effects {
    if e.candidates.length() > 0 {
      parts.push(
        kind_tag(e.kind) + ":" + e.target + "[" + e.candidates.join("|") + "]",
      )
    }
  }
  parts.join(" ")
}

///|
test "a branch leaves a set of values, not a forgotten name" {
  inspect(
    candidate_list("if c; then x=a; else x=b; fi; rm $x"),
    content="Delete:$x[a|b] Unknown:$x[a|b]",
  )
  // One branch only: not taking it is also an outcome, and an unset name names
  // no path, so only `a` is a candidate while the hole stays a hole.
  inspect(
    candidate_list("if c; then x=a; fi; rm $x"),
    content="Delete:$x[a] Unknown:$x[a]",
  )
  // The value from before the branch is one of the possibilities.
  inspect(
    candidate_list("x=old; if c; then x=new; fi; rm $x"),
    content="Delete:$x[old|new] Unknown:$x[old|new]",
  )
  inspect(
    candidate_list("case $k in a) x=1;; b) x=2;; esac; rm $x"),
    content="Delete:$x[1|2] Unknown:$x[1|2]",
  )
}

///|
test "a fact is a fact, and is not dressed up as a possibility" {
  // Both paths set the same value, so nothing is uncertain.
  inspect(candidate_list("if c; then x=a; else x=a; fi; rm $x"), content="")
  inspect(touched("if c; then x=a; else x=a; fi; rm $x"), content="D:a")
  // A plain assignment is a fact.
  inspect(candidate_list("x=a; rm $x"), content="")
  inspect(touched("x=a; rm $x"), content="D:a")
}

///|
test "a loop over a spelled-out list leaves the values its body left" {
  inspect(
    candidate_list("for i in 1 2; do x=$i; done; rm $x"),
    content="Delete:$x[1|2] Unknown:$x[1|2]",
  )
  // Every iteration sets the same thing, so that is a fact.
  inspect(touched("x=a; for i in 1 2; do x=b; done; rm $x"), content="D:b")
}

///|
test "a loop whose count is not modelled leaves an unknown, not a set" {
  // A `while` may run any number of times, so one pass would name a set that is
  // not exhaustive.
  inspect(candidate_list("while c; do x=a; done; rm $x"), content="")
  inspect(touched("while c; do x=a; done; rm $x"), content="D:$x U:$x")
  // A function body may or may not be reached when the function is called; the
  // call itself is not modelled.
  inspect(candidate_list("x=a; f() { x=b; }; rm $x"), content="")
}

///|
test "an unbound name has nothing to offer" {
  inspect(candidate_list("rm $UNSET"), content="")
}

///|
test "the possibilities travel with the value" {
  // `y=$x` copies the whole set, since the shell copies whatever `x` was.
  inspect(
    candidate_list("if c; then x=a; else x=b; fi; y=$x; rm $y"),
    content="Delete:$y[a|b] Unknown:$y[a|b]",
  )
  // The text around the name goes in with each value.
  inspect(
    candidate_list("if c; then x=a; else x=b; fi; rm $x/post"),
    content="Delete:$x/post[a/post|b/post] Unknown:$x/post[a/post|b/post]",
  )
  // An absolute value makes the candidate absolute.
  inspect(
    candidate_list("if c; then d=/tmp/a; else d=/tmp/b; fi; rm $d/x"),
    content="Delete:$d/x[/tmp/a/x|/tmp/b/x] Unknown:$d/x[/tmp/a/x|/tmp/b/x]",
  )
}

///|
test "a set that grew past the cap says nothing rather than something partial" {
  // Four combinations still fit.
  inspect(
    candidate_list(
      "if c; then x=1; else x=2; fi; if d; then y=8; else y=9; fi; rm $x$y",
    ),
    content="Delete:$x$y[18|19|28|29] Unknown:$x$y[18|19|28|29]",
  )
  // Three names of three values each is past what a caller can use, and a
  // candidate list has to be exhaustive or it is not worth having.
  let many = "if a; then x=1; elif b; then x=2; else x=3; fi; if c; then y=4; elif d; then y=5; else y=6; fi; if e; then z=7; elif f; then z=8; else z=9; fi; rm $x$y$z"
  inspect(candidate_list(many), content="")
  inspect(touched(many), content="D:$x$y$z U:$x$y$z")
}
