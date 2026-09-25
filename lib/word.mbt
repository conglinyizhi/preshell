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
  parts_text(self.parts)
}

///|
/// Render a run of parts, keeping a parameter's braces when dropping them would
/// run it into the next name character: `$Xy` and `${X}y` are different
/// expansions, and the report must not spell the second one as the first.
fn parts_text(parts : Array[WordPart]) -> String {
  let sb = StringBuilder()
  for i, p in parts {
    let needs_braces = match p {
      Param(n) =>
        is_bare_param_name(n) &&
        i + 1 < parts.length() &&
        starts_with_name_char(parts[i + 1])
      _ => false
    }
    match p {
      Param(n) =>
        if needs_braces {
          sb.write_string("${")
          sb.write_string(n)
          sb.write_char('}')
        } else if is_bare_param_name(n) {
          sb.write_char('$')
          sb.write_string(n)
        } else {
          sb.write_string("${")
          sb.write_string(n)
          sb.write_char('}')
        }
      _ => sb.write_string(part_text(p))
    }
  }
  sb.to_string()
}

///|
/// Whether a part renders as something that would glue onto a preceding
/// parameter name.
fn starts_with_name_char(p : WordPart) -> Bool {
  match part_text(p).get_char(0) {
    Some(c) =>
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    None => false
  }
}

///|
/// Whether a parameter payload can be written without braces: a name, a digit,
/// or one of the special parameters. Anything else (`X:-default`, `#X`, `X[1]`)
/// keeps its `${...}` spelling so the boundary stays visible.
fn is_bare_param_name(n : String) -> Bool {
  let mut index = 0
  for c in n {
    index += 1
    if index == 1 {
      let name_start = (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        c == '_'
      if !name_start {
        // A one-character special parameter: `$1`, `$@`, `$?`, `$$`.
        return index == n.length() &&
          (
            (c >= '0' && c <= '9') ||
            c == '@' ||
            c == '*' ||
            c == '#' ||
            c == '?' ||
            c == '-' ||
            c == '$' ||
            c == '!'
          )
      }
      continue
    }
    let name_body = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if !name_body {
      return false
    }
  }
  index > 0
}

///|
/// Render one part roughly the way it was written, for reporting.
fn part_text(p : WordPart) -> String {
  let sb = StringBuilder()
  match p {
    Lit(s) | SQuote(s) | Glob(s) | Tilde(s) => sb.write_string(s)
    Param(n) =>
      // `${X}y` and `$Xy` are different expansions, so the braces have to
      // survive whenever the payload is anything other than a bare name. Doing
      // the other thing printed `$Xy` for `${X}y`, which reads as a variable
      // that does not exist.
      if is_bare_param_name(n) {
        sb.write_char('$')
        sb.write_string(n)
      } else {
        sb.write_string("${")
        sb.write_string(n)
        sb.write_char('}')
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
      sb.write_string(parts_text(inner))
      sb.write_char(']')
    }
    DQuote(inner) => sb.write_string(parts_text(inner))
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
    // An unquoted tilde-prefix is expanded too: `~` is `$HOME`, `~+` is `$PWD`
    // and `~user` is another user's home directory (bash 5.3 manual, "Tilde
    // Expansion"). The text says `~`; the shell says an absolute path, or, when
    // the login name is invalid, leaves the prefix exactly as written.
    Tilde(_) => true
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
