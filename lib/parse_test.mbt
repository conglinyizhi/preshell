///|
fn parse_ok(src : String) -> (Seq, Array[String]) {
  let (seq, errs) = parse(src)
  (seq, errs)
}

///|
fn first_cmd(src : String) -> Cmd {
  let (seq, _) = parse(src)
  seq.items[0].pipeline.cmds[0]
}

///|
fn cmd_count(src : String) -> Int {
  let (seq, _) = parse(src)
  seq.items[0].pipeline.cmds.length()
}

///|
fn command_of(src : String) -> String {
  match first_cmd(src) {
    Cmd::Simple(s) =>
      match s.words {
        [w, ..] => w.literal_text()
        _ => ""
      }
    _ => ""
  }
}

///|
test "pipeline splits on |" {
  inspect(cmd_count("a | b | c"), content="3")
  inspect(cmd_count("a |& b"), content="2")
  inspect(cmd_count("a; b"), content="1")
}

///|
test "list operators" {
  let (seq, _) = parse("a && b || c; d &")
  inspect(seq.items.length(), content="4")
  debug_inspect(seq.items[0].op, content="And")
  debug_inspect(seq.items[1].op, content="Or")
  debug_inspect(seq.items[2].op, content="Semi")
  debug_inspect(seq.items[3].op, content="Amp")
}

///|
test "words keep their holes" {
  let (seq, _) = parse("echo \"a $(date) c\" $HOME `id`")
  let w = match first_cmd("echo \"a $(date) c\" $HOME `id`") {
    Cmd::Simple(s) => s.words
    _ => []
  }
  inspect(w.length(), content="4")
  inspect(w[1].raw, content="\"a $(date) c\"")
  inspect(w[1].has_hole(), content="true")
  inspect(w[2].has_hole(), content="true")
  inspect(w[3].has_hole(), content="true")
  inspect(seq.items.length(), content="1")
}

///|
test "quoted words are static" {
  let w = match first_cmd("echo \"a b\" 'c d'") {
    Cmd::Simple(s) => s.words[1]
    _ => { parts: [], raw: "", line: 0, }
  }
  debug_inspect(w.static_text(), content="Some(\"a b\")")
}

///|
test "reserved word only at command position" {
  let (seq, errs) = parse("if echo then; then :; fi")
  inspect(errs.length(), content="0")
  match first_cmd("if echo then; then :; fi") {
    Cmd::If(cond~, then_~, ..) => {
      inspect(cond.items.length(), content="1")
      inspect(then_.items.length(), content="1")
    }
    _ => fail("expected an if")
  }
  inspect(seq.items.length(), content="1")
}

///|
test "assignments are split from arguments" {
  match first_cmd("A=1 B+=2 cmd arg") {
    Cmd::Simple(s) => {
      inspect(s.assigns.length(), content="2")
      inspect(s.assigns[1].name, content="B")
      inspect(s.assigns[1].append, content="true")
      inspect(s.words.length(), content="2")
    }
    _ => fail("expected a simple command")
  }
}

///|
test "file descriptor prefixes" {
  match first_cmd("cmd 2>&1 > /dev/null") {
    Cmd::Simple(s) => {
      inspect(s.redirects.length(), content="2")
      debug_inspect(s.redirects[0].fd, content="Some(2)")
      inspect(s.redirects[0].target.raw, content="1")
      debug_inspect(s.redirects[1].fd, content="None")
    }
    _ => fail("expected a simple command")
  }
}

///|
test "here-document body is collected after the newline" {
  match first_cmd("cat <<EOF\nhello $x\nEOF\n") {
    Cmd::Simple(s) => {
      inspect(s.redirects.length(), content="1")
      debug_inspect(s.redirects[0].body, content="Some(\"hello $x\\n\")")
    }
    _ => fail("expected a simple command")
  }
}

///|
test "here-document with a quoted delimiter" {
  match first_cmd("cat <<'EOF'\n$(rm -rf /)\nEOF\n") {
    Cmd::Simple(s) =>
      debug_inspect(s.redirects[0].body, content="Some(\"$(rm -rf /)\\n\")")
    _ => fail("expected a simple command")
  }
}

///|
test "case pattern paren does not close a command substitution" {
  let (seq, errs) = parse("x=$(case y in a) echo z;; esac)")
  inspect(errs.length(), content="0")
  let subs = match first_cmd("x=$(case y in a) echo z;; esac)") {
    Cmd::Simple(s) => s.assigns[0].value
    _ => []
  }
  match subs {
    [CmdSub(inner), ..] => inspect(inner.items.length(), content="1")
    _ => fail("expected one command substitution")
  }
  inspect(seq.items.length(), content="1")
}

///|
test "missing close parenthesis is reported" {
  let (_, errs) = parse("echo $(date")
  inspect(errs.length(), content="1")
  inspect(errs[0], content="unexpected end of input in command substitution")
}

///|
test "process substitution contains a real command" {
  match first_cmd("diff <(a) >(b)") {
    Cmd::Simple(s) => {
      inspect(s.words.length(), content="3")
      inspect(s.words[1].has_hole(), content="true")
      inspect(s.words[1].subcommands().length(), content="1")
    }
    _ => fail("expected a simple command")
  }
}

///|
test "function definitions and groups" {
  match first_cmd("f() { echo hi; }") {
    Cmd::FuncDef(name~, ..) => inspect(name, content="f")
    _ => fail("expected a function definition")
  }
  match first_cmd("g ( ) { echo hi; }") {
    Cmd::FuncDef(name~, ..) => inspect(name, content="g")
    _ => fail("expected a function definition")
  }
}

///|
test "for loop keeps its word list" {
  match first_cmd("for f in a b c; do echo $f; done") {
    Cmd::For(name~, words~, ..) => {
      inspect(name, content="f")
      inspect(words.length(), content="3")
    }
    _ => fail("expected a for loop")
  }
}

///|
test "comments and line continuations" {
  let (seq, errs) = parse("echo a \\\n  b # trailing\n")
  inspect(errs.length(), content="0")
  inspect(seq.items.length(), content="1")
  match first_cmd("echo a \\\n  b # trailing\n") {
    Cmd::Simple(s) => inspect(s.words.length(), content="3")
    _ => fail("expected a simple command")
  }
}

///|
test "ANSI-C quoting is decoded" {
  match first_cmd("rm -rf $'\\x2f'") {
    Cmd::Simple(s) =>
      debug_inspect(s.words[2].static_text(), content="Some(\"/\")")
    _ => fail("expected a simple command")
  }
}

///|
test "arithmetic command and expansion" {
  match first_cmd("((1 + 2))") {
    Cmd::Arith(raw) => inspect(raw.trim(), content="1 + 2")
    _ => fail("expected arithmetic")
  }
  match first_cmd("echo $((1 + $(date)))") {
    Cmd::Simple(s) => inspect(s.words[1].raw, content="$((1 + $(date)))")
    _ => fail("expected a simple command")
  }
}
