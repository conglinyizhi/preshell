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

///|
/// The variables a word reads, in the order they appear, deduplicated.
///
/// These are the names a caller can look up to finish the path: the tool never
/// reads the environment, so "which name do I need to substitute" is the part it
/// can hand over. Only names an environment could supply are listed; positional
/// and special parameters (`$1`, `$@`, `$?`) are holes with no lookup, and a
/// bare `~user` is a passwd lookup rather than a variable.
pub fn Word::vars(self : Word) -> Array[String] {
  let out : Array[String] = []
  for p in self.parts {
    part_vars(p, out)
  }
  out
}

///|
fn part_vars(p : WordPart, out : Array[String]) -> Unit {
  match p {
    Param(n) =>
      match param_name(n) {
        Some(name) => if !out.contains(name) { out.push(name) }
        None => ()
      }
    Tilde(s) => {
      // bash 5.3 manual, "Tilde Expansion": `~` is HOME, `~+` is PWD, `~-` is
      // OLDPWD. `~user` is that user's home directory from the password
      // database, and zsh's `~name` may come from `hash -d`, so neither is a
      // variable a caller could substitute.
      let name = if s == "~" {
        "HOME"
      } else if s == "~+" {
        "PWD"
      } else if s == "~-" {
        "OLDPWD"
      } else {
        ""
      }
      if name != "" && !out.contains(name) {
        out.push(name)
      }
    }
    DQuote(inner) | Subscript(inner) =>
      for q in inner {
        part_vars(q, out)
      }
    // A nested command is audited on its own; its variables belong to it.
    CmdSub(_) | ArithSub(_) | ProcSub(_, _) | Lit(_) | SQuote(_) | Glob(_) => ()
  }
}

///|
/// The variable a parameter payload names, when it names one. `${X:-d}`,
/// `${X#p}` and `${X/a/b}` all read X, so the leading name is the answer; a
/// payload that is only a special or positional parameter names nothing a
/// caller could look up.
fn param_name(n : String) -> String? {
  let body = if n.has_prefix("#") || n.has_prefix("!") {
    // `${#X}` counts, `${!X}` indirection: both still need X to be read.
    n.unsafe_substring(start=1, end=n.length())
  } else {
    n
  }
  let mut name = ""
  let mut index = 0
  for c in body {
    let letters = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    let digits = c >= '0' && c <= '9'
    if index == 0 && !letters {
      return None
    }
    if !letters && !digits {
      break
    }
    name = name + c.to_string()
    index += 1
  }
  if name == "" {
    None
  } else {
    Some(name)
  }
}

///|
/// Whether the word's first segment is something the shell fills in at run time.
///
/// This is the difference between `$HOME/x` and `dir/$X/y`: only the former may
/// turn out to be absolute, and only then does anchoring it to a base make a
/// path that is quietly wrong. A quoted `"~"` or `'$X'` is literal text and
/// counts as resolved, which is why this walks the parts rather than the text.
pub fn Word::head_unresolved(self : Word) -> Bool {
  head_state(self.parts) == Some(true)
}

///|
/// `Some(true)` unresolved, `Some(false)` resolved, `None` nothing seen yet —
/// an empty literal is not evidence either way.
fn head_state(parts : Array[WordPart]) -> Bool? {
  for p in parts {
    let state = match p {
      Lit(s) | SQuote(s) | Glob(s) =>
        if s.is_empty() {
          None
        } else {
          Some(false)
        }
      // `name[...]` starts with a literal name, so the path is still relative.
      Subscript(_) => Some(false)
      DQuote(inner) => head_state(inner)
      Tilde(_) | Param(_) | CmdSub(_) | ArithSub(_) | ProcSub(_, _) =>
        Some(true)
    }
    match state {
      Some(_) => return state
      None => ()
    }
  }
  None
}

///|
/// A command word in the position of a path: the text as written, whether it is
/// a closed set, whether it can be anchored, and what the caller would have to
/// substitute to finish it.
///
/// The four travel together because they are all read off the same word. Deriving
/// any of them from the rendered text afterwards would lose the difference
/// between `${X}y` and `$Xy`, and between an expanding `~` and a quoted one.
pub(all) struct PathArg {
  text : String
  /// Not a closed set: a hole or a glob.
  dynamic : Bool
  /// The first segment is expanded at run time, so the base cannot be applied.
  unrooted : Bool
  vars : Array[String]
} derive(Debug, Eq)

///|
pub fn PathArg::of(w : Word) -> PathArg {
  {
    text: w.literal_text(),
    dynamic: w.has_hole() || w.has_glob(),
    unrooted: w.head_unresolved(),
    vars: w.vars(),
  }
}

///|
/// The same path with a suffix glued on (`gzip f.txt` writes `f.txt.gz`): the
/// text changes, the rest does not.
pub fn PathArg::plus_suffix(self : PathArg, suffix : String) -> PathArg {
  {
    text: self.text + suffix,
    dynamic: self.dynamic,
    unrooted: false,
    vars: self.vars,
  }
}

///|
/// The same path read as a name inside a directory (`cp -t dir x` writes
/// `dir/x`). The directory contributes its own holes and its own head: `-t $D`
/// makes the result unanchored, and a variable in either half is a variable the
/// caller needs.
pub fn PathArg::in_dir(self : PathArg, dir : PathArg) -> PathArg {
  let vars : Array[String] = []
  for v in dir.vars {
    vars.push(v)
  }
  for v in self.vars {
    if !vars.contains(v) {
      vars.push(v)
    }
  }
  {
    text: join_dir(dir.text, self.text),
    dynamic: dir.dynamic || self.dynamic,
    unrooted: dir.unrooted,
    vars,
  }
}

///|
/// A path that did not come from a word: a literal the table knows, like tar's
/// `-` or zsh's temporary file name.
pub fn PathArg::lit(text : String, dynamic? : Bool = false) -> PathArg {
  { text, dynamic, unrooted: false, vars: [], }
}

///|
/// Whether a value carved out of a word (the part after `of=` or `--file=`)
/// starts with an expansion.
///
/// The word-level flag does not apply here: the head of `of=$X` is the literal
/// `of=`. This reads the rendered text instead, which is exact for the two
/// markers below because a quoted `$` or `~` leaves no hole behind, and no hole
/// means the answer is false without looking further.
pub fn value_head_unresolved(text : String, dynamic : Bool) -> Bool {
  dynamic && (text.has_prefix("$") || text.has_prefix("~"))
}
