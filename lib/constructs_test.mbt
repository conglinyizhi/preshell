///|
/// Constructs that were gaps until the parser learned them. Each one is here
/// because a corpus run showed it failing on valid bash, and the shape of the
/// parse matters as much as the accept/reject answer.
fn status_of_construct(src : String) -> @lib.ParseStatus {
  @lib.analyze(src).status
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
    @lib.Cmd::Simple(s) => {
      inspect(s.assigns[0].name, content="arr")
      debug_inspect(s.assigns[0].index, content="[Lit(\"0\")]")
    }
    _ => fail("expected an assignment")
  }
  match first_cmd("echo a[0]") {
    @lib.Cmd::Simple(s) => inspect(s.words[1].has_glob(), content="true")
    _ => fail("expected a simple command")
  }
}

///|
test "a hole inside a subscript is not a clean result" {
  let r = @lib.analyze("arr[$i]=1")
  // The hole is in the target, so the effect itself is uncertain.
  debug_inspect(r.impact.uncertain, content="true")
  debug_inspect(r.impact.effects[0].kind, content="Unknown")
  // A literal subscript stays clean.
  debug_inspect(@lib.analyze("arr[0]=1").impact.uncertain, content="false")
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
  let im = @lib.impact(@lib.parse("(echo a) > /tmp/o").0)
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

///|
test "an unclosed bracket stays on its own line" {
  // `echo [[:alpha:]` has no closing bracket; bash treats it as literal text.
  // Scanning past the newline for a match turned lines 37-44 of a corpus file
  // into a single word, which silently swallowed the rest of the input.
  let src = "echo [[:alpha:]\necho done\n"
  debug_inspect(status_of_construct(src), content="Complete")
  inspect(seq_of(src).items.length(), content="2")
  match first_cmd(src) {
    @lib.Cmd::Simple(s) => inspect(s.words[1].has_glob(), content="true")
    _ => fail("expected a simple command")
  }
}

///|
test "issues carry the line they happened on" {
  // 没有结尾换行：EOF 落在第 2 行，也就是命令替换开始的那一行。
  let r = @lib.analyze("echo a\necho $(date")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].line, content="2")
}

///|
test "quoted brackets are not subscripts" {
  // `touch '[a' '[x'`: the bracket is inside quotes, so nothing to scan.
  debug_inspect(status_of_construct("touch '[a' '[x'"), content="Complete")
}

///|
test "a case pattern list has to be closed by a paren" {
  // Measured on bash 5.3 and zsh 5.9.2: both refuse a pattern list whose `)`
  // is missing. `case x in a : ;; esac` and `case x in a) :;; junk esac` are
  // the same defect — the trailing `junk` is read as the next pattern list —
  // so one rule covers both shapes.
  for
    src in [
      "case x in a : ;; esac", "case x in a) :;; junk esac", "case x in a) :;; es esac",
      "case x in a|b : ;; esac",
    ] {
    debug_inspect(status_of_construct(src), content="Unsupported")
  }
  // A case with no pattern list at all is fine: `esac` closes it directly.
  debug_inspect(status_of_construct("case x in esac"), content="Complete")
  debug_inspect(
    status_of_construct("case x in a) : ;; esac"),
    content="Complete",
  )
  // The `;` before `in` is one of the spellings only zsh takes, so it is the
  // dialect that decides: bash refuses it, zsh runs it.
  debug_inspect(
    status_of_construct("case x; in a) : ;; esac"),
    content="Unsupported",
  )
  debug_inspect(
    @lib.analyze_dialect("case x; in a) : ;; esac", Zsh).status,
    content="Complete",
  )
  // zsh's parenthesised pattern needs no closing paren of its own: the group's
  // own `)` does double duty. bash reads the `(` as the list's paren instead.
  for
    src in [
      "case $x in\n  (gnu) echo hi ;;\nesac", "case $x in\n  (net|open)bsd*) echo hi ;;\nesac",
      "case $x in\n  (<1->|\\*) a[1]=$1;;\nesac",
    ] {
    debug_inspect(zstatus(src), content="Complete")
  }
}

///|
test "an array assignment body is a word list, not a command list" {
  // Measured: bash 5.3 and zsh 5.9.2 both refuse a redirect, `&`, `&&`, `|` or
  // a bare `(` between the parentheses — `x=(a > f)`, `x=(a && b)`, `x=(a (b))`
  // — while `;` is refused by bash only (`x=(a;b)` runs in zsh).
  for
    src in [
      "x=(a > f)", "x=(a 2>&1)", "x=(a < f)", "x=(a <<< hi)", "x=(a && b)", "x=(a | b)",
      "x=(&)", "x=(a &)", "arr=(1 arr=(1 2 3)", "x=(a <<EOF\nhi\nEOF\n)",
    ] {
    debug_inspect(status_of_construct(src), content="Unsupported")
  }
  // `;` splits commands, not words: bash refuses it here, zsh takes it.
  debug_inspect(status_of_construct("x=(a;b)"), content="Unsupported")
  debug_inspect(status_of_construct("x=(a b;)"), content="Unsupported")
  debug_inspect(status_of_construct("x=(a\\;;b)"), content="Unsupported")
  debug_inspect(@lib.analyze_dialect("x=(a;b)", Zsh).status, content="Complete")
  debug_inspect(
    @lib.analyze_dialect("x=(a b;)", Zsh).status,
    content="Complete",
  )
  debug_inspect(
    @lib.analyze_dialect("x=(a\\;;b)", Zsh).status,
    content="Complete",
  )
  // And the shapes that are a plain word list stay accepted.
  for
    src in [
      "x=(a b)", "x=()", "x=(a\nb)", "x=(a # c\nb)", "x=([0]=a [1]=b)", "x=($(echo 1) b)",
      "x=(a $((1+2)))", "x=({a,b})", "x=(\"a;b\")", "x=('a;b')",
    ] {
    debug_inspect(status_of_construct(src), content="Complete")
  }
}

///|
test "a case terminator may follow a semicolon or an ampersand" {
  // Measured on bash 5.3 and zsh 5.9.2: both run `case x in a) : ; ;; esac`
  // and `case x in a) : & ;; esac` — the `;;` closes the branch right after a
  // separator, with no command in between. `&&`, `||` and `|` in the same
  // place are refused by both, because those demand a right-hand side.
  for
    src in [
      "case x in a) : ; ;; esac", "case x in a) : & ;; esac", "case $# in\n0) help ; exit 1 ; ;;\nesac",
    ] {
    debug_inspect(status_of_construct(src), content="Complete")
  }
  for
    src in [
      "case x in a) : && ;; esac", "case x in a) : | ;; esac", "case x in a) : || ;; esac",
      "case x in a) : ; | esac",
    ] {
    debug_inspect(status_of_construct(src), content="Unsupported")
  }
}

///|
test "a backslash inside a bracket expression escapes the quote" {
  // Measured: bash 5.3 and zsh 5.9.2 both run `case x in *[\"]*) : ;; esac`
  // while the bare `*["]*)` is refused by both — there the `"` opens a region
  // that never closes, so the two spellings really differ and the scan has to
  // honour the backslash. Missing that made the bracket swallow the rest of the
  // pattern list and, with a quote in the body, leak the quote state into it.
  for
    src in [
      "case x in\n  *[\\\"]*)\n    :;;\nesac", "case x in\n  *[\\\"]*)\n    x=\"abc\"\n    ;;\nesac",
      "case x in\n  *[\\\\\\`\\\"\\$]*)\n    :;;\nesac",
      // The quoted region inside a bracket is real, so this one stays accepted.
       "case x in\n  *[\"a b\"]*)\n    :;;\nesac",
    ] {
    debug_inspect(status_of_construct(src), content="Complete")
  }
  // Without the backslash the quote really does open a region, and both shells
  // refuse the result.
  debug_inspect(
    status_of_construct("case x in\n  *[\"]*)\n    :;;\nesac"),
    content="Unsupported",
  )
}
