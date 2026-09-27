///|
/// Values the command line establishes for its own parameters.
///
/// Every expectation here was measured against bash 5.3 first, and the ones that
/// look surprising are the reason the rules are as narrow as they are. Codes are
/// the same as commands_test.mbt: R read, W write, D delete, N network, S spawn,
/// U unknown.
///
/// The line this file draws: a name is resolved only when the input says what it
/// holds, and never when the shell would do something else to the value on the
/// way. Everything left over stays a hole, which is what the tool reported
/// before this existed.

///|
test "a spelled-out for list runs the body once per word" {
  // The list is a closed set, so the loop name holds each word in turn.
  inspect(touched("for f in a b; do rm -rf \"$f\"; done"), content="D:a D:b")
  inspect(touched("for f in a b; do cat $f; done"), content="R:a R:b")
  // Quoting the use site changes nothing: the value has no blank in it.
  inspect(touched("for f in a b; do cat \"$f\"; done"), content="R:a R:b")
  // zsh's csh spelling is the same list.
  inspect(ztouched("foreach x ( a b ) rm $x; end"), content="D:a D:b")
}

///|
test "a list the shell has to work out stays a hole" {
  // A glob needs the file system, which this tool never reads; the list word is
  // reported as unknown, because saying nothing about it lost the loop's own
  // word list entirely.
  inspect(
    touched("for f in *.ts; do rm \"$f\"; done"),
    content="U:*.ts D:$f U:$f",
  )
  inspect(
    touched("for f in lib/*.ts; do cat $f; done"),
    content="U:lib/*.ts R:$f U:$f",
  )
  // `for ((...))` names no list at all.
  inspect(touched("for ((i=0;i<3;i++)); do rm $i; done"), content="D:$i U:$i")
  // zsh's two names rotate over one list, so neither name holds every word.
  inspect(ztouched("for a b in x y; do rm $a; done"), content="D:$a U:$a")
}

///|
test "the loop name does not survive the loop" {
  // bash leaves the name at the last word, but a caller reading the report has
  // no way to know the loop ran at all, so the hole is the honest answer.
  inspect(touched("for f in a b; do :; done; rm $f"), content="D:$f U:$f")
}

///|
test "a value written on its own line is the value the next line sees" {
  inspect(touched("x=dist; rm -rf $x"), content="D:dist")
  inspect(touched("x=/tmp/a; rm -- \"$x\""), content="D:/tmp/a")
  // A value copied from another name is followed through, because the copy is
  // still text the command line spelled out.
  inspect(touched("x=a; y=$x; rm $y"), content="D:a")
}

///|
test "a value the shell would expand further is a hole" {
  // A blank used to be here too; it is not a hole any more, it is word splitting
  // (fields_test.mbt). What is left is the values the shell would do something
  // else to: the glob would fan out against the file system at the use site.
  inspect(touched("x='*.log'; rm $x"), content="D:$x U:$x")
  // A nested command is a run-time value.
  inspect(touched("x=$(date); rm $x"), content="D:$x U:$x")
  // `+=` and the array form build on the old value.
  inspect(touched("x=a; x+=b; rm $x"), content="D:$x U:$x")
  inspect(touched("x=a; a[0]=b; rm $x"), content="D:a")
}

///|
test "a value that holds on one path only is dropped" {
  // Each of these really does set the name (`if true; then x=b; fi; echo $x`
  // prints `b` in bash), but only on the path that was taken. What survives is
  // the set of what it may hold, which is `candidates` on the effect, and the
  // target stays the hole it was.
  inspect(touched("x=a; if true; then x=b; fi; rm $x"), content="D:$x U:$x")
  inspect(touched("x=a; while :; do x=b; done; rm $x"), content="D:$x U:$x")
  // A `for` over a spelled-out list always runs, so what its body left is the
  // whole answer: both iterations set `b`, and that is a fact.
  inspect(touched("x=a; for i in 1 2; do x=b; done; rm $x"), content="D:b")
}

///|
test "a subshell's value does not escape it" {
  // Measured: `x=old; (x=sub); echo $x` prints `old`.
  inspect(touched("x=a; (x=b); rm $x"), content="D:a")
  inspect(touched("x=a; y=$(x=b); rm $x"), content="D:a")
}

///|
test "an assignment in front of a command does not outlive it" {
  // Measured: `x=old; x=new echo hi; echo $x` prints `old`.
  inspect(touched("x=old; x=new echo hi; rm $x"), content="D:old")
}

///|
test "the builtins that write a parameter drop what was known" {
  // An external program cannot reach the shell's variables; these can.
  inspect(touched("x=a; unset x; rm $x"), content="D:$x U:$x")
  inspect(touched("x=a; read x; rm $x"), content="D:$x U:$x")
  inspect(touched("x=a; printf -v x b; rm $x"), content="D:$x U:$x")
  // `.` runs a command line that is not in this input.
  inspect(touched("x=a; . other.sh; rm $x"), content="R:other.sh D:$x U:$x")
}

///|
test "a declaration builtin sets the value only when it means to" {
  // Measured against bash 5.3: these leave the value the word spells.
  inspect(touched("export x=a; rm $x"), content="D:a")
  inspect(touched("declare x=a; rm $x"), content="D:a")
  inspect(touched("local x=a; rm $x"), content="D:a")
  inspect(touched("readonly x=a; rm $x"), content="D:a")
  // These do not: `declare -i x=1+2` leaves `3`, `let x=a` leaves `0` (it reads
  // its words as arithmetic), and `alias x=a` writes no variable at all.
  inspect(touched("declare -i x=1+2; rm $x"), content="D:$x U:$x")
  inspect(touched("let x=a; rm $x"), content="D:$x U:$x")
  inspect(touched("x=old; let x=a; rm $x"), content="D:$x U:$x")
  inspect(touched("alias x=a; rm $x"), content="D:$x U:$x")
  // An alias leaves the variable exactly as it was.
  inspect(touched("x=old; alias x=a; rm $x"), content="D:old")
}

///|
test "a name resolved to a program is that program" {
  // bash expands the word and then runs it, so the report is about `rm`.
  inspect(touched("x=rm; $x -rf t"), content="D:t")
}

///|
test "a resolved value is no longer a name the caller has to look up" {
  // The contract hands over names to substitute; a name this tool resolved is
  // not one of them any more.
  inspect(@lib.analyze("x=dist; rm -rf $x").impact.vars.join(" "), content="")
  inspect(@lib.analyze("rm -rf $x").impact.vars.join(" "), content="x")
  inspect(
    @lib.analyze("x=dist; y=build; rm -rf $x $y").impact.vars.join(" "),
    content="",
  )
  // One name resolved and one not: the report keeps the hole and its name.
  inspect(
    @lib.analyze("x=dist; rm -rf $x $y").impact.vars.join(" "),
    content="y",
  )
}

///|
/// The reference an effect was written as, when a value went into it:
/// `Delete:$x` for a target of `/tmp/dist` that came from `x=dist`. Effects with
/// nothing resolved into them are absent, which is what the caller reads as "the
/// target is what the word says".
fn origins_of(src : String) -> String {
  let r = @lib.analyze(src)
  let parts : Array[String] = []
  for e in r.impact.effects {
    match e.origin {
      Some(o) => parts.push(kind_tag(e.kind) + ":" + o)
      None => ()
    }
  }
  parts.join(" ")
}

///|
test "an effect that came from a value says which reference it was written as" {
  // The command-name position is why this exists: `/usr/bin/jq` is nowhere in
  // the command text, `$x` is.
  inspect(origins_of("x=/usr/bin/jq; $x -n 1"), content="Exec:$x")
  inspect(
    origins_of("if c; then x=/usr/bin/jq; else x=/usr/bin/jq; fi; $x -n 1"),
    content="Exec:$x",
  )
  inspect(origins_of("x=dist; rm -rf $x"), content="Delete:$x")
  // The origin is the word as written, rendered the way a hole is rendered, so
  // it matches the text a caller reads out of the command.
  inspect(origins_of("x=dist; rm -rf \"$x\""), content="Delete:$x")
  inspect(origins_of("x=dist; rm -rf pre$x"), content="Delete:pre$x")
  // The nearest reference wins, so a chain of assignments still points at
  // something in the command text.
  inspect(origins_of("x=/a; y=$x; rm -rf $y"), content="Delete:$y")
  // A derived path keeps the reference of the half that was one.
  inspect(origins_of("d=/tmp/a; cp -t $d f"), content="Write:$d")
}

///|
test "nothing resolved means no origin" {
  inspect(origins_of("rm -rf dist"), content="")
  // A name the tool did not resolve is already in `target`; there is nothing to
  // map it back from.
  inspect(origins_of("rm -rf $ENV"), content="")
  inspect(origins_of("rm -rf $ENV/x"), content="")
  // Held only as data (a here-document body, an arithmetic value): no path, no
  // origin.
  inspect(origins_of("x=1; echo $((x + 1))"), content="")
}
