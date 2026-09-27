///|
/// Word splitting at the report level: the same value is two paths in one place
/// and one path in another, and the difference is whether the use site was
/// quoted. Codes as in commands_test.mbt, `!` for a target that is not a closed
/// set.
///
/// Every expectation here was measured against bash 5.3 first.

///|
/// The targets a report marks as not closed, which is what a hole looks like.
fn field_dynamic(src : String) -> String {
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
test "an unquoted value is split, a quoted one is not" {
  inspect(touched("x=\"a b\"; rm $x"), content="D:a D:b")
  // The quoted form names one file whose name has a space in it.
  inspect(touched("x=\"a b\"; rm \"$x\""), content="D:a b")
  // Whitespace at either end is padding, runs in the middle delimit.
  inspect(touched("x=\" a \"; rm $x"), content="D:a")
  inspect(touched("x=\"  a  b  \"; rm $x"), content="D:a D:b")
}

///|
test "the pieces keep the text around the value" {
  // Measured: `x="a b"; printf '<%s>' pre$x` is `prea` and `b`.
  inspect(touched("x=\"a b\"; rm pre$x"), content="D:prea D:b")
  inspect(touched("x=\"a b\"; rm $x/post"), content="D:a D:b/post")
  // The quoted piece glues onto the last field of the unquoted one.
  inspect(touched("x=\"a b\"; rm $x\"$x\""), content="D:a D:ba b")
  inspect(
    touched("x=\"a b\"; rm $x/unquoted \"$x\""),
    content="D:a D:b/unquoted D:a b",
  )
}

///|
test "IFS decides the separators, and an empty IFS turns them off" {
  // Only IFS characters separate, so a colon is an ordinary character by default.
  inspect(touched("x=\"a:b\"; rm $x"), content="D:a:b")
  inspect(touched("IFS=:; x=\"a:b\"; rm $x"), content="D:a D:b")
  // With IFS empty the value stays one word, which is the whole point of it.
  inspect(touched("IFS=; x=\"a b\"; rm $x"), content="D:a b")
  // An empty field names no path, so it is not reported: bash would pass it and
  // the command would fail on it.
  inspect(touched("IFS=:; x=\":a\"; rm $x"), content="D:a")
}

///|
test "an assignment is not split, its use site is" {
  // Measured: `x="a b"; y=$x` puts the whole value in `y`.
  inspect(touched("x=\"a b\"; y=$x; rm \"$y\""), content="D:a b")
  inspect(touched("x=\"a b\"; y=$x; rm $y"), content="D:a D:b")
}

///|
test "a value that disappears makes no argument" {
  // Measured: `x=""; rm $x` runs `rm` with no arguments at all, and
  // `rm "$x"` passes one empty one, which deletes nothing either way.
  inspect(touched("x=\"\"; rm $x"), content="")
  inspect(touched("x=\"\"; rm \"$x\""), content="")
}

///|
test "a redirect target is not split, it is refused" {
  // Measured: `x="a b"; echo hi > $x` is an ambiguous redirect — bash refuses the
  // command instead of opening anything, so the target is a hole.
  inspect(field_dynamic("x=\"a b\"; echo hi > $x"), content="$x")
  // Quoted, it names one file whose name has a space in it.
  inspect(touched("x=\"a b\"; echo hi > \"$x\""), content="W:a b")
}

///|
test "two values that both split are left alone" {
  // The shell splits the whole expanded word; gluing one name's fields onto
  // another's needs the full algorithm, so this stays a hole rather than a guess.
  inspect(touched("x=\"a b\"; y=\"c d\"; rm $x$y"), content="D:$x$y U:$x$y")
}

///|
test "a for list is split like an argument list" {
  inspect(touched("x=\"a b\"; for f in $x; do rm $f; done"), content="D:a D:b")
  inspect(
    touched("IFS=:; x=\"a:b\"; for f in $x; do rm \"$f\"; done"),
    content="D:a D:b",
  )
}
