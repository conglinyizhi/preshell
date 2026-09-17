///|
/// Constructs that were gaps until the parser learned them. Each one is here
/// because a corpus run showed it failing on valid bash, and the shape of the
/// parse matters as much as the accept/reject answer.
fn status_of_construct(src : String) -> ParseStatus {
  check(src, AuditConfig::default()).status
}

///|
test "array subscripts with quotes and brackets inside" {
  // bash: parse.y:5622-5650 scans `name[...]` with P_ARRAYSUB, so a `]` inside
  // a quoted key does not end the subscript.
  let cases = [
    "a[0]=x", "a[0]+=5", "myarray[\"a]a\"]=\"abc\"", "foo=([\"version[agent]\"]=version.agent)",
    "arr[$i]=1", "declare foo[\"foo[bar]\"]=bowl", "typeset -A foo=([one]=bar)",
  ]
  for src in cases {
    if status_of_construct(src) is Unsupported {
      fail("regressed on: \{src}")
    }
  }
}

///|
test "a subscript is a subscript, and a bracket without `=` stays a glob" {
  match first_cmd("arr[0]=x") {
    Cmd::Simple(s) => {
      inspect(s.assigns[0].name, content="arr")
      debug_inspect(s.assigns[0].index, content="[Lit(\"0\")]")
    }
    _ => fail("expected an assignment")
  }
  match first_cmd("echo a[0]") {
    Cmd::Simple(s) => inspect(s.words[1].has_glob(), content="true")
    _ => fail("expected a simple command")
  }
}

///|
test "a hole inside a subscript is not a clean result" {
  let r = check("arr[$i]=1", AuditConfig::default())
  // The hole is in the target, so the effect itself is uncertain.
  debug_inspect(r.impact.uncertain, content="true")
  debug_inspect(r.impact.effects[0].kind, content="Unknown")
  // A literal subscript stays clean.
  debug_inspect(
    check("arr[0]=1", AuditConfig::default()).impact.uncertain,
    content="false",
  )
}

///|
test "compound commands carry their own redirections" {
  let cases = [
    "( echo a ) > /tmp/o", "( ls > /tmp/nw ) 2>/dev/null", "{ echo x; } >&2", "if true; then echo y; fi > /tmp/log",
    "while true; do echo y; done < /dev/null", "f() { echo x; } 2>&1",
  ]
  for src in cases {
    if status_of_construct(src) is Unsupported {
      fail("regressed on: \{src}")
    }
  }
  // And the redirect has to show up in the summary, not just parse.
  let im = impact(parse("(echo a) > /tmp/o").0)
  inspect(
    im.effects.any(fn(e) { e.kind is Write && e.target == "/tmp/o" }),
    content="true",
  )
}

///|
test "a negated empty command is still a command" {
  debug_inspect(status_of_construct("!; echo 1 $?"), content="Complete")
  debug_inspect(status_of_construct("!& echo 2 $?"), content="Complete")
}

///|
test "nested arithmetic heads count depth" {
  debug_inspect(
    status_of_construct("for (( i=0 ; (( i < 3 )) ; i++ )) ; do echo $i; done"),
    content="Complete",
  )
  debug_inspect(status_of_construct("((i++))"), content="Complete")
  debug_inspect(
    status_of_construct("echo $(( (1 + 2) * 3 ))"),
    content="Complete",
  )
}
