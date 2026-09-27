///|
/// Brace expansion, which is a purely textual expansion that runs before
/// parameter expansion: `rm -rf {a,b}` names two files, while `x='{a,b}'; rm $x`
/// names one file whose name has braces in it.
///
/// Codes as in commands_test.mbt: R read, W write, D delete, N network, S spawn,
/// U unknown. A trailing `!` marks a target that is not a closed set.

///|
/// The targets a report marks as not closed, which is what a hole looks like.
fn dynamic_targets(src : String) -> String {
  let r = @lib.analyze(src)
  let parts : Array[String] = []
  for e in r.impact.effects {
    if e.dynamic {
      parts.push(e.target)
    }
  }
  parts.join(" ")
}

///|
test "a brace list is the words it names" {
  // Measured: `echo {a,b}` prints `a b`, so the command sees two arguments.
  inspect(touched("rm -rf {a,b}"), content="D:a D:b")
  inspect(touched("rm -rf a{b,c}d"), content="D:abd D:acd")
  inspect(touched("rm -rf {a,b}c{d,e}"), content="D:acd D:ace D:bcd D:bce")
  // The words are spliced where bash puts them, so the program is still the first
  // word: `{echo,true} hi` runs `echo` with two arguments (measured).
  inspect(
    @lib.analyze("{echo,true} hi").impact.effects[0].target,
    content="echo",
  )
}

///|
test "a brace range counts" {
  inspect(touched("rm -rf {1..3}"), content="D:1 D:2 D:3")
  inspect(touched("rm -rf {3..1}"), content="D:3 D:2 D:1")
  inspect(touched("rm -rf {1..7..2}"), content="D:1 D:3 D:5 D:7")
  // A leading zero pads, and the width counts the sign (measured).
  inspect(touched("rm -rf {01..03}"), content="D:01 D:02 D:03")
  inspect(touched("rm -rf {a..c}"), content="D:a D:b D:c")
  inspect(touched("rm -rf {a..f..3}"), content="D:a D:d")
}

///|
test "the two shells disagree about what a range is" {
  // bash needs two numbers or two letters: `{1..a}` is literal there.
  inspect(touched("rm -rf {1..a}"), content="D:{1..a}")
  // zsh walks the ASCII table for any two single characters.
  inspect(
    ztouched("rm -rf {1..a}").split(" ").to_array().length(),
    content="49",
  )
  // and refuses a step on a character range, while bash takes one.
  inspect(ztouched("rm -rf {a..f..3}"), content="D:{a..f..3}")
}

///|
test "braces that do not expand stay with the word" {
  // An escape makes the brace literal, and the parts have already resolved the
  // escape away, so the raw text is what decides.
  inspect(touched("rm -rf \\{a,b\\}"), content="D:{a,b}")
  // Quotes do too, and there the parts still know.
  inspect(touched("rm -rf \"{a,b}\""), content="D:{a,b}")
  inspect(touched("rm -rf '{a,b}'"), content="D:{a,b}")
  // A brace with no comma and no range is literal, and the search moves past it.
  inspect(touched("rm -rf {a}"), content="D:{a}")
  inspect(touched("rm -rf {a,b"), content="D:{a,b")
  inspect(touched("rm -rf {1..3..x}"), content="D:{1..3..x}")
}

///|
test "an expansion too large to spell out is a hole" {
  // A thousand paths is not an answer a caller can use, and the cut has to be
  // visible rather than silent.
  inspect(dynamic_targets("rm -rf {1..1000}"), content="{1..1000} {1..1000}")
  // The ones that do fit are not holes.
  inspect(dynamic_targets("rm -rf {a,b}"), content="")
  inspect(dynamic_targets("rm -rf {1..100}"), content="")
}

///|
test "braces come out before values go in" {
  // Measured: `x=a; echo {x,y}` prints `x y` — the braces name literal words, so
  // the value of `x` is not involved.
  inspect(touched("x=a; rm -rf {x,y}"), content="D:x D:y")
  // The other way round: a value with braces in it is one word with braces in it.
  inspect(touched("x={a,b}; rm $x"), content="D:$x U:$x")
  // A brace glued to a name is part of the expansion of that name — measured,
  // `x=1; echo $x{a,b}` is `$xa` and `$xb`, not `${x}a` — so the tool leaves the
  // word as a hole rather than inventing `${x}a`.
  inspect(touched("x=a; rm -rf $x{a,b}"), content="D:$x{a,b} U:$x{a,b}")
}

///|
test "a brace list is a closed set for a loop and for a redirect" {
  inspect(touched("for f in {a,b}; do rm $f; done"), content="D:a D:b")
  inspect(touched("echo hi > {a,b}"), content="W:a W:b")
}
