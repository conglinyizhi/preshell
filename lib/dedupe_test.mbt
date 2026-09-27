///|
/// The same fact reported once.
///
/// A loop body is walked once per word, so `for f in a b; do rm x; done` reaches
/// the report with the same deletion twice on the same line. A caller reading
/// two identical lines learns nothing the first one did not say, and the second
/// one used to eat a slot of the effect budget as well.
///
/// Codes as in commands_test.mbt: R read, W write, D delete, N network, S spawn,
/// U unknown.

///|
test "a body walked twice over the same path is one fact" {
  inspect(touched("for f in a b; do rm x; done"), content="D:x")
  // The duplicates came from one source line, so this is the same statement
  // twice, and it says the same thing.
  inspect(touched("rm x; rm x"), content="D:x")
  // The count in the list is not what makes it a fact: fifty runs, one deletion.
  inspect(touched("for f in {1..50}; do rm x; done"), content="D:x")
}

///|
test "what differs stays" {
  inspect(touched("rm x; rm y"), content="D:x D:y")
  // A different path per iteration is a different fact per iteration.
  inspect(touched("for f in a b; do rm $f; done"), content="D:a D:b")
  // The line is part of the fact: the same removal written on two lines is two
  // statements, and a caller reporting by line needs both.
  inspect(touched("rm x\nrm x"), content="D:x D:x")
  // A read and a write of the same path are two facts.
  inspect(touched("cat x > x"), content="W:x R:x")
}

///|
test "a hole with candidates collapses the same way" {
  // The body runs twice and both runs say "one of two paths": one Delete and one
  // Unknown, not two of each.
  let r = @lib.analyze(
    "if c; then x=a; else x=b; fi; for f in 1 2; do rm $x; done",
  )
  let mut holes = 0
  let mut deletes = 0
  for e in r.impact.effects {
    if e.kind == Delete {
      deletes += 1
    }
    if e.kind == Unknown && e.target == "$x" {
      holes += 1
    }
  }
  inspect(deletes, content="1")
  inspect(holes, content="1")
  // The candidate list is part of the fact: it is still there on the survivor.
  inspect(
    candidate_of("if c; then x=a; else x=b; fi; for f in 1 2; do rm $x; done"),
    content="$x[a|b]",
  )
}

///|
/// The first Delete's target and candidates, for the checks that care about them.
fn candidate_of(src : String) -> String {
  let r = @lib.analyze(src)
  for e in r.impact.effects {
    if e.kind == Delete {
      return e.target + "[" + e.candidates.join("|") + "]"
    }
  }
  "none"
}

///|
test "a duplicate does not eat the effect budget" {
  // Fifty identical iterations leave one effect, so nothing is dropped and the
  // answer is not marked uncertain for a reason that does not exist.
  let r = @lib.analyze("for f in {1..50}; do rm x; done")
  inspect(r.impact.effects_dropped, content="0")
  inspect(r.impact.uncertain, content="false")
}
