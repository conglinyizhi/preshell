///|
/// Constructs that only bash (and its relatives) understands, split by *how* a
/// POSIX shell fails on them. The distinction is measured, not guessed: each
/// entry was run through `dash -n`.
///
/// - `Rejects`: dash refuses to parse the file at all (`x=(1 2)`, `<<<`,
///   `<(...)`, the `function` keyword). Saying "it would not run" is accurate.
/// - `Differs`: dash parses it and does something else. `[[ -f x ]]` is a
///   command named `[[` to dash, and `((i++))` is two nested subshells. The
///   report must not claim these make the file invalid, because they do not.
pub(all) struct Bashisms {
  rejects : Array[String]
  differs : Array[String]
} derive(Debug, Eq, ToJson)

///|
pub fn bashisms(seq : Seq) -> Bashisms {
  let rejects : Array[String] = []
  let differs : Array[String] = []
  collect_bashisms(seq, rejects, differs)
  { rejects, differs, }
}

///|
fn add_bashism(out : Array[String], what : String) -> Unit {
  if !out.contains(what) {
    out.push(what)
  }
}

///|
fn collect_bashisms(
  seq : Seq,
  rejects : Array[String],
  differs : Array[String],
) -> Unit {
  for item in seq.items {
    for cmd in item.pipeline.cmds {
      collect_cmd_bashisms(cmd, rejects, differs)
    }
  }
}

///|
fn collect_cmd_bashisms(
  cmd : Cmd,
  rejects : Array[String],
  differs : Array[String],
) -> Unit {
  match cmd {
    // dash parses `((...))` as two nested subshells, so this is a silent
    // difference in meaning rather than a syntax error.
    Cmd::Arith(_) => add_bashism(differs, "(( ))")
    // `[[` is a keyword to bash and an ordinary command name to dash.
    Cmd::Cond(_) => add_bashism(differs, "[[ ]]")
    Cmd::Simple(s) => {
      for a in s.assigns {
        if a.array {
          add_bashism(rejects, "array assignment")
        }
        for p in a.value {
          collect_part_bashisms(p, rejects, differs)
        }
        for p in a.index {
          collect_part_bashisms(p, rejects, differs)
        }
      }
      for r in s.redirects {
        if r.op is RHereString {
          add_bashism(rejects, "<<<")
        }
        collect_word_bashisms(r.target, rejects, differs)
      }
      for w in s.words {
        collect_word_bashisms(w, rejects, differs)
      }
    }
    Cmd::Subshell(inner) | Cmd::Group(inner) =>
      collect_bashisms(inner, rejects, differs)
    Cmd::Always(inner~, always~) => {
      collect_bashisms(inner, rejects, differs)
      collect_bashisms(always, rejects, differs)
    }
    Cmd::If(cond~, then_~, elifs~, else_~) => {
      collect_bashisms(cond, rejects, differs)
      collect_bashisms(then_, rejects, differs)
      for pair in elifs {
        let (c, b) = pair
        collect_bashisms(c, rejects, differs)
        collect_bashisms(b, rejects, differs)
      }
      match else_ {
        Some(e) => collect_bashisms(e, rejects, differs)
        None => ()
      }
    }
    Cmd::Loop(cond~, body~, ..) => {
      collect_bashisms(cond, rejects, differs)
      collect_bashisms(body, rejects, differs)
    }
    Cmd::For(body~, words~, ..) => {
      for w in words {
        collect_word_bashisms(w, rejects, differs)
      }
      collect_bashisms(body, rejects, differs)
    }
    Cmd::Case(subject~, items~) => {
      collect_word_bashisms(subject, rejects, differs)
      for it in items {
        for p in it.patterns {
          collect_word_bashisms(p, rejects, differs)
        }
        collect_bashisms(it.body, rejects, differs)
      }
    }
    Cmd::FuncDef(body~, keyword~, ..) => {
      if keyword {
        add_bashism(rejects, "function keyword")
      }
      match body {
        Cmd::Subshell(inner) => collect_bashisms(inner, rejects, differs)
        Cmd::Group(inner) => collect_bashisms(inner, rejects, differs)
        _ => ()
      }
    }
    Cmd::Redirected(inner~, redirects~) => {
      collect_cmd_bashisms(inner, rejects, differs)
      for r in redirects {
        if r.op is RHereString {
          add_bashism(rejects, "<<<")
        }
      }
    }
  }
}

///|
fn collect_word_bashisms(
  w : Word,
  rejects : Array[String],
  differs : Array[String],
) -> Unit {
  for p in w.parts {
    collect_part_bashisms(p, rejects, differs)
  }
}

///|
fn collect_part_bashisms(
  p : WordPart,
  rejects : Array[String],
  differs : Array[String],
) -> Unit {
  match p {
    ProcSub(_, seq) => {
      add_bashism(rejects, "<( ) process substitution")
      collect_bashisms(seq, rejects, differs)
    }
    CmdSub(seq) => collect_bashisms(seq, rejects, differs)
    DQuote(inner) | Subscript(inner) =>
      for q in inner {
        collect_part_bashisms(q, rejects, differs)
      }
    _ => ()
  }
}

///|
/// The notes to attach when a POSIX script uses bash-only syntax. Two notes at
/// most, because the two kinds are different claims: one says the file cannot
/// run there, the other says it runs and means something else.
fn posix_mismatch_note(src : String, seq : Seq) -> Array[String] {
  match declared_shell(src) {
    Some(name) =>
      if name == "sh" || name == "dash" {
        let bs = bashisms(seq)
        let notes : Array[String] = []
        if bs.rejects.length() > 0 {
          notes.push(
            "this input declares " +
            name +
            " but uses syntax that shell rejects (" +
            bs.rejects.join(", ") +
            "): it would not run under " +
            name +
            " as written",
          )
        }
        if bs.differs.length() > 0 {
          notes.push(
            "this input declares " +
            name +
            " but uses syntax that shell reads differently (" +
            bs.differs.join(", ") +
            "): it parses, and does something else",
          )
        }
        notes
      } else {
        []
      }
    None => []
  }
}
