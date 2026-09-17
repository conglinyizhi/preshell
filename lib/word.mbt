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
    DQuote(inner) | Subscript(inner) => {
      // A subscript is part of the name being assigned to, so it is static
      // exactly when its own parts are.
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
    sb.write_string(part_text(p))
  }
  sb.to_string()
}

///|
/// Render one part roughly the way it was written, for reporting.
fn part_text(p : WordPart) -> String {
  let sb = StringBuilder()
  match p {
    Lit(s) | SQuote(s) | Glob(s) | Tilde(s) => sb.write_string(s)
    Param(n) => {
      sb.write_char('$')
      sb.write_string(n)
    }
    CmdSub(_) => sb.write_string("$()")
    ArithSub(_) => sb.write_string("$(())")
    // The shape, not a bare `()`: the word expands to a path this tool cannot
    // name (a pipe, or zsh's temporary file), and printing `()` would read as
    // a file actually called that.
    ProcSub(c, _) =>
      match c {
        '=' => sb.write_string("=()")
        _ => {
          sb.write_char(c)
          sb.write_string("()")
        }
      }
    Subscript(inner) => {
      sb.write_char('[')
      for q in inner {
        sb.write_string(part_text(q))
      }
      sb.write_char(']')
    }
    DQuote(inner) =>
      for q in inner {
        sb.write_string(part_text(q))
      }
  }
  sb.to_string()
}

///|
/// True when the shell must fill something in before the word is a value.
pub fn Word::has_hole(self : Word) -> Bool {
  for p in self.parts {
    if part_has_hole(p) {
      return true
    }
  }
  false
}

///|
fn part_has_hole(p : WordPart) -> Bool {
  match p {
    Param(_) | CmdSub(_) | ArithSub(_) | ProcSub(_) => true
    DQuote(inner) | Subscript(inner) => inner.any(part_has_hole)
    _ => false
  }
}

///|
/// True when the word can match more than one path. A subscript is not a glob:
/// what sits inside `name[...]` is an index expression, not a pattern.
pub fn Word::has_glob(self : Word) -> Bool {
  for p in self.parts {
    if part_has_glob(p) {
      return true
    }
  }
  false
}

///|
fn part_has_glob(p : WordPart) -> Bool {
  match p {
    Glob(_) => true
    DQuote(inner) | Subscript(inner) => inner.any(part_has_glob)
    _ => false
  }
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
    DQuote(inner) | Subscript(inner) =>
      for q in inner {
        collect_subs(q, out)
      }
    _ => ()
  }
}
