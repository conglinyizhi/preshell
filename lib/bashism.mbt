///|
/// Constructs that only bash (and its relatives) understand. A POSIX shell
/// rejects them, so a script that declares `sh` or `dash` and uses one of these
/// will not run there — and reporting its effects without saying so would
/// answer a question about a different program.
///
/// This is the honest half of "POSIX mode": rather than pretending to parse two
/// grammars, the tool says which bash-only thing it saw.
pub fn bashisms(seq : Seq) -> Array[String] {
  let out : Array[String] = []
  collect_bashisms(seq, out)
  out
}

///|
fn add_bashism(out : Array[String], what : String) -> Unit {
  if !out.contains(what) {
    out.push(what)
  }
}

///|
fn collect_bashisms(seq : Seq, out : Array[String]) -> Unit {
  for item in seq.items {
    for cmd in item.pipeline.cmds {
      collect_cmd_bashisms(cmd, out)
    }
  }
}

///|
fn collect_cmd_bashisms(cmd : Cmd, out : Array[String]) -> Unit {
  match cmd {
    Cmd::Arith(_) => add_bashism(out, "(( ))")
    Cmd::Cond(_) => add_bashism(out, "[[ ]]")
    Cmd::Simple(s) => {
      for a in s.assigns {
        if a.array {
          add_bashism(out, "array assignment")
        }
        for p in a.value {
          collect_part_bashisms(p, out)
        }
        for p in a.index {
          collect_part_bashisms(p, out)
        }
      }
      for r in s.redirects {
        if r.op is RHereString {
          add_bashism(out, "<<<")
        }
        collect_word_bashisms(r.target, out)
      }
      for w in s.words {
        collect_word_bashisms(w, out)
      }
    }
    Cmd::Subshell(inner) | Cmd::Group(inner) => collect_bashisms(inner, out)
    Cmd::If(cond~, then_~, elifs~, else_~) => {
      collect_bashisms(cond, out)
      collect_bashisms(then_, out)
      for pair in elifs {
        let (c, b) = pair
        collect_bashisms(c, out)
        collect_bashisms(b, out)
      }
      match else_ {
        Some(e) => collect_bashisms(e, out)
        None => ()
      }
    }
    Cmd::Loop(cond~, body~, ..) => {
      collect_bashisms(cond, out)
      collect_bashisms(body, out)
    }
    Cmd::For(body~, words~, ..) => {
      for w in words {
        collect_word_bashisms(w, out)
      }
      collect_bashisms(body, out)
    }
    Cmd::Case(subject~, items~) => {
      collect_word_bashisms(subject, out)
      for it in items {
        for p in it.patterns {
          collect_word_bashisms(p, out)
        }
        collect_bashisms(it.body, out)
      }
    }
    Cmd::FuncDef(body~, keyword~, ..) => {
      if keyword {
        add_bashism(out, "function keyword")
      }
      match body {
        Cmd::Subshell(inner) => collect_bashisms(inner, out)
        Cmd::Group(inner) => collect_bashisms(inner, out)
        _ => ()
      }
    }
    Cmd::Redirected(inner~, redirects~) => {
      collect_cmd_bashisms(inner, out)
      for r in redirects {
        if r.op is RHereString {
          add_bashism(out, "<<<")
        }
      }
    }
  }
}

///|
fn collect_word_bashisms(w : Word, out : Array[String]) -> Unit {
  for p in w.parts {
    collect_part_bashisms(p, out)
  }
}

///|
fn collect_part_bashisms(p : WordPart, out : Array[String]) -> Unit {
  match p {
    ProcSub(_, seq) => {
      add_bashism(out, "<( ) process substitution")
      collect_bashisms(seq, out)
    }
    CmdSub(seq) => collect_bashisms(seq, out)
    DQuote(inner) | Subscript(inner) =>
      for q in inner {
        collect_part_bashisms(q, out)
      }
    _ => ()
  }
}

///|
/// The note to attach when a POSIX script uses bash-only syntax.
fn posix_mismatch_note(src : String, seq : Seq) -> Array[String] {
  match declared_shell(src) {
    Some(name) =>
      if name == "sh" || name == "dash" {
        let used = bashisms(seq)
        if used.length() > 0 {
          [
            "this input declares " +
            name +
            " but uses bash-only syntax (" +
            used.join(", ") +
            "): it would not run under that shell as written",
          ]
        } else {
          []
        }
      } else {
        []
      }
    None => []
  }
}
