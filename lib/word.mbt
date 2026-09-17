///|
/// Word-level helpers shared by the lexer, parser and auditor.
/// A word is *static* when the shell cannot change it at run time; anything
/// containing `$`, backticks, `$(( ))`, `<(...)` or an unquoted glob is a hole.
pub fn Word::static_text(self : Word) -> String? {
  let sb = StringBuilder()
  for p in self.parts {
    if !write_static(p, sb) {
      return None
    }
  }
  Some(sb.to_string())
}

///|
/// Append a part whose value the shell cannot change; false for any hole.
fn write_static(p : WordPart, sb : StringBuilder) -> Bool {
  match p {
    Lit(s) | SQuote(s) => {
      sb.write_string(s)
      true
    }
    DQuote(inner) => {
      for q in inner {
        if !write_static(q, sb) {
          return false
        }
      }
      true
    }
    Tilde(_) | Glob(_) | Param(_) | CmdSub(_) | ArithSub(_) | ProcSub(_) =>
      false
  }
}

///|
/// Best-effort literal text: holes are rendered as `$` so that a caller can
/// still tell "this word is not a path I can trust" from the text alone.
pub fn Word::literal_text(self : Word) -> String {
  let sb = StringBuilder()
  for p in self.parts {
    match p {
      Lit(s) | SQuote(s) | Glob(s) | Tilde(s) => sb.write_string(s)
      Param(n) => {
        sb.write_char('$')
        sb.write_string(n)
      }
      CmdSub(_) => sb.write_string("$()")
      ArithSub(_) => sb.write_string("$(())")
      ProcSub(_) => sb.write_string("()")
      DQuote(inner) =>
        for q in inner {
          match q {
            Lit(s) | SQuote(s) => sb.write_string(s)
            Param(n) => {
              sb.write_char('$')
              sb.write_string(n)
            }
            _ => sb.write_string("?")
          }
        }
    }
  }
  sb.to_string()
}

///|
/// True when the shell must fill something in before the word is a value.
pub fn Word::has_hole(self : Word) -> Bool {
  for p in self.parts {
    let hit = match p {
      Param(_) | CmdSub(_) | ArithSub(_) | ProcSub(_) => true
      DQuote(inner) =>
        inner.any(fn(q) {
          match q {
            Param(_) | CmdSub(_) | ArithSub(_) | ProcSub(_) => true
            _ => false
          }
        })
      _ => false
    }
    if hit {
      return true
    }
  }
  false
}

///|
/// True when the word can match more than one path.
pub fn Word::has_glob(self : Word) -> Bool {
  for p in self.parts {
    match p {
      Glob(_) => return true
      DQuote(inner) =>
        if inner.any(fn(q) {
            match q {
              Glob(_) => true
              _ => false
            }
          }) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
/// The word read as a single unquoted literal, or None. This is what decides
/// whether a word is a reserved word: `if` is reserved, `\if` and `"if"` are not.
pub fn Word::plain(self : Word) -> String? {
  match self.parts {
    [Lit(s)] => if self.raw == s { Some(s) } else { None }
    _ => None
  }
}

///|
/// Every nested command carried inside a word: `$( )`, backticks, `<()`, `>()`.
pub fn Word::subcommands(self : Word) -> Array[Seq] {
  let out : Array[Seq] = []
  for p in self.parts {
    collect_subs(p, out)
  }
  out
}

///|
fn collect_subs(p : WordPart, out : Array[Seq]) -> Unit {
  match p {
    CmdSub(seq) | ProcSub(_, seq) => out.push(seq)
    DQuote(inner) =>
      for q in inner {
        collect_subs(q, out)
      }
    _ => ()
  }
}
