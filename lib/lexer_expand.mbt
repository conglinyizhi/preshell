///|
/// Expansions the scanner has to recognise as it reads a word, and the shapes
/// that decide what a word is.
///
/// The rules here follow the shells' own behaviour rather than a summary of it:
/// which characters start a tilde expansion (bash's `tilde_find_suffix`), how a
/// subscript keeps `~` inside it (bash's `assignment()`, general.c:480), how
/// zsh's numeric ranges read as globs rather than redirects, and how the value
/// of a parameter is used exactly as it stands.

///|
/// Whether a `~` at this position starts a tilde expansion.
///
/// Besides the head of a word, the shell expands a tilde inside a word that
/// satisfies the conditions of a variable assignment: right after its first `=`
/// and after each `:`. subst.c is where that happens (`W_ASSIGNMENT` records the
/// offset of the first `=` and sets `internal_tilde` when the next character is
/// `~`; `case ':'` does the same), and parse.y sets `W_ASSIGNMENT` from the
/// shape of the word alone, so `echo of=~/z` expands too. `--file=~/x` is not
/// assignment-shaped and bash leaves that tilde alone (measured).
fn tilde_at_value_start(parts : Array[WordPart], lit : StringBuilder) -> Bool {
  let t = match assign_prefix(parts, lit) {
    None => return false
    Some(t) => t
  }
  if t.is_empty() {
    return true
  }
  if !(t.has_suffix("=") || t.has_suffix(":")) {
    return false
  }
  // A backslash left in the prefix means it came from a subscript, where the
  // raw-token rule has already been applied by the caller.
  if t.contains("\\") {
    return false
  }
  is_assign_form(t)
}

///|
/// The text of the word so far, or None when any part of it was quoted or
/// expanded. bash decides the assignment form from the raw token, so `"a"=~/z`
/// is not one and its tilde stays literal (measured).
fn assign_prefix(parts : Array[WordPart], lit : StringBuilder) -> String? {
  let sb = StringBuilder()
  for p in parts {
    match p {
      Lit(s) => sb.write_string(s)
      // `a[0]=~/x`: bash's assignment() skips a subscript before the `=`, and
      // bash's own test suite has `aa[~/Documents]=~/Library`.
      Subscript(inner) => {
        sb.write_char('[')
        sb.write_string(parts_text(inner))
        sb.write_char(']')
      }
      _ => return None
    }
  }
  sb.write_string(lit.to_string())
  Some(sb.to_string())
}

///|
/// A port of bash's `assignment()` (general.c:480), which is what decides
/// whether a word is assignment-shaped: the first character must be a legal
/// variable starter, the name may hold only letters, digits, `_` and `[...]`
/// subscripts, and the name ends at `=` or `+=`.
fn is_assign_form(t : String) -> Bool {
  match t.get_char(0) {
    Some(c) => if !is_name_start(c) { return false }
    None => return false
  }
  let mut i = 1
  while i < t.length() {
    match t.get_char(i) {
      None => return false
      Some(c) =>
        if c == '=' {
          return true
        } else if c == '[' {
          let mut depth = 0
          let mut j = i
          let mut closed = false
          while j < t.length() {
            match t.get_char(j) {
              Some('[') => depth += 1
              Some(']') => {
                depth -= 1
                if depth == 0 {
                  closed = true
                  j += 1
                  break
                }
              }
              Some(_) => ()
              None => break
            }
            j += 1
          }
          if !closed {
            return false
          }
          i = j
          match t.get_char(i) {
            Some('=') => return true
            Some('+') => return t.get_char(i + 1) == Some('=')
            _ => return false
          }
        } else if c == '+' && t.get_char(i + 1) == Some('=') {
          return true
        } else if is_name_char(c) {
          i += 1
        } else {
          return false
        }
    }
  }
  false
}

///|
fn Lexer::read_tilde(self : Lexer) -> String? {
  let start = self.pos
  self.advance(1)
  // bash's tilde_find_suffix runs to the first `/`, not to the end of a name
  // (lib/tilde/tilde.c): `~+` is PWD, `~-` is OLDPWD and `~3` is a directory
  // stack entry, none of which are name-shaped. Our narrower rule left them as
  // literal text, which then looked like a relative path called `~+`.
  for ;; {
    match self.peek() {
      None => break
      Some(c) => {
        if c == '/' || is_blank(c) || is_meta(c) || c == '\n' {
          break
        }
        // "If none of the characters in the tilde-prefix are quoted, the
        // characters following the tilde are treated as a possible login name"
        // (bash 5.3 manual, "Tilde Expansion"). A quoted or escaped character
        // therefore makes the whole thing ordinary text, and the word stays a
        // literal.
        if c == '"' || c == '\'' || c == '\\' {
          self.pos = start
          return None
        }
        self.advance(1)
      }
    }
  }
  Some(self.slice(start, self.pos))
}

///|
fn Lexer::read_dollar(
  self : Lexer,
  parts : Array[WordPart],
  lit : StringBuilder,
  in_dquote : Bool,
) -> Unit {
  // Inside double quotes a dollar sign before a quote is just a dollar sign:
  // bash reads `"...$"` as the text ending in `$`, not as the start of a
  // `$"..."` translation string. Treating it as one swallowed the rest of the
  // file, which is how five real scripts ended up with "unterminated double
  // quote".
  let nxt = self.peek_at(1)
  if in_dquote && (nxt == Some('"') || nxt == Some('\'')) {
    self.advance(1)
    lit.write_char('$')
    return
  }
  match self.peek_at(1) {
    Some('(') =>
      if self.peek_at(2) == Some('(') {
        self.advance(3)
        flush_lit(parts, lit)
        parts.push(ArithSub(self.read_arith()))
      } else {
        self.advance(2)
        flush_lit(parts, lit)
        parts.push(CmdSub(self.sub_seq("command substitution")))
      }
    Some('{') => {
      self.advance(2)
      flush_lit(parts, lit)
      parts.push(Param(self.read_braced(in_dquote)))
    }
    Some('[') => {
      self.advance(2)
      flush_lit(parts, lit)
      parts.push(ArithSub(self.read_bracket_arith()))
    }
    Some('"') => {
      self.advance(2)
      let inner = self.read_parts(false)
      if self.peek() == Some('"') {
        self.advance(1)
      }
      flush_lit(parts, lit)
      parts.push(DQuote(inner))
    }
    Some('\'') => {
      self.advance(2)
      let body = self.read_ansi_body()
      flush_lit(parts, lit)
      parts.push(SQuote(decode_ansi(body)))
    }
    Some(c) =>
      if is_name_start(c) {
        let start = self.pos + 1
        let mut i = start
        for ;; {
          match self.src.get_char(i) {
            Some(d) if is_name_char(d) => i += 1
            _ => break
          }
        }
        self.pos = i
        flush_lit(parts, lit)
        parts.push(Param(self.slice(start, i)))
      } else if c.is_ascii_digit() || "*@#?-$!".contains_char(c) {
        self.advance(2)
        flush_lit(parts, lit)
        parts.push(Param(c.to_string()))
      } else {
        self.advance(1)
        lit.write_char('$')
      }
    None => {
      self.advance(1)
      lit.write_char('$')
    }
  }
}

///|
/// `${ ... }` with nesting: `${a:-${b}}` is one parameter expansion.
fn Lexer::read_braced(self : Lexer, in_dquote : Bool) -> String {
  let start = self.pos
  let mut depth = 0
  // zsh counts a plain `{` as nesting inside a bare expansion but not inside a
  // double-quoted one; bash never counts it. Measured, same text in both
  // shells and both quotings:
  //   zsh  ${a//b/X{Y}/Z}     the expansion runs to the last `}`
  //   zsh  "${a//b/X{Y}/Z}"   it ends at the first one
  //   bash both spellings     it ends at the first one
  // Two real scripts in the corpus need one branch each, so this is not a
  // detail that can be rounded off.
  let count_braces = self.dialect is Zsh && !in_dquote
  for ;; {
    match self.peek() {
      None => {
        self.fail("unterminated ${")
        break
      }
      Some('{') => {
        if count_braces {
          depth += 1
        }
        self.advance(1)
      }
      Some('$') =>
        // A nested `${` always has to be scanned through, in both shells and
        // however the outer expansion is quoted.
        if self.peek_at(1) == Some('{') {
          depth += 1
          self.advance(2)
        } else {
          self.advance(1)
        }
      Some('}') =>
        if depth == 0 {
          break
        } else {
          depth -= 1
          self.advance(1)
        }
      Some('\'') =>
        if self.dialect is Zsh && in_dquote {
          // A lone `'` inside a double-quoted expansion is text in zsh: the
          // `}` still ends the expansion. Measured, same shape in both
          // quotings:
          //   zsh  x="${a:-'}"   accepted, value `'`
          //   zsh  x=${a:-'}     unmatched '
          // compinstall line 19 needs this (a backquoted `q'` inside `${1:...}`).
          self.advance(1)
        } else {
          self.advance(1)
          ignore(self.read_until('\''))
          if self.peek() == Some('\'') {
            self.advance(1)
          }
        }
      Some('"') => {
        // A `"` inside the expansion opens a nested quoted string in both
        // shells, and a backslash in there escapes the next character, so
        // `\"` does not close it:
        //   x=${a"b\"c"}   accepted in zsh and bash
        //   x=${a"b\"}     unmatched " in both
        // read_until() alone stopped at the escaped quote, then went looking
        // for a partner and ate the closing brace. _perforce line 1255 needs it.
        self.advance(1)
        self.read_nested_dquote()
      }
      Some('\\') => self.advance(2)
      Some(_) => self.advance(1)
    }
  }
  let body = self.slice(start, self.pos)
  if self.peek() == Some('}') {
    self.advance(1)
  }
  body
}

///|
fn Lexer::read_bracket_arith(self : Lexer) -> String {
  let start = self.pos
  for ;; {
    match self.peek() {
      None => break
      Some(']') => break
      Some(_) => self.advance(1)
    }
  }
  let body = self.slice(start, self.pos)
  if self.peek() == Some(']') {
    self.advance(1)
  }
  body
}

///|
/// `$(( ... ))`: the closing pair is the first `))` at paren depth zero.
fn Lexer::read_arith(self : Lexer) -> String {
  let start = self.pos
  let mut depth = 0
  for ;; {
    match self.peek() {
      None => break
      Some('(') => {
        depth += 1
        self.advance(1)
      }
      Some(')') =>
        if depth == 0 && self.peek_at(1) == Some(')') {
          break
        } else {
          if depth > 0 {
            depth -= 1
          }
          self.advance(1)
        }
      Some(_) => self.advance(1)
    }
  }
  let body = self.slice(start, self.pos)
  if self.peek() == Some(')') && self.peek_at(1) == Some(')') {
    self.advance(2)
  } else {
    self.fail("unterminated arithmetic expansion")
  }
  body
}

///|
/// `$'...'`: the escapes are resolved by the shell before the word is used,
/// so `$'\x2f'` is a `/` and must not be read as three harmless characters.
fn decode_ansi(s : String) -> String {
  let sb = StringBuilder()
  let n = s.length()
  let mut i = 0
  for ;; {
    if i >= n {
      break
    }
    let c = s.get_char(i).unwrap()
    if c != '\\' || i + 1 >= n {
      sb.write_char(c)
      i += 1
      continue
    }
    let d = s.get_char(i + 1).unwrap()
    match d {
      'n' => {
        sb.write_char('\n')
        i += 2
      }
      't' => {
        sb.write_char('\t')
        i += 2
      }
      'r' => {
        sb.write_char('\r')
        i += 2
      }
      'a' => {
        sb.write_char('\u{07}')
        i += 2
      }
      'b' => {
        sb.write_char('\u{08}')
        i += 2
      }
      'f' => {
        sb.write_char('\u{0c}')
        i += 2
      }
      'v' => {
        sb.write_char('\u{0b}')
        i += 2
      }
      'e' | 'E' => {
        sb.write_char('\u{1b}')
        i += 2
      }
      '\\' | '\'' | '"' | '?' => {
        sb.write_char(d)
        i += 2
      }
      'x' => {
        let (v, used) = read_hex(s, i + 2, 2)
        sb.write_char(v.unsafe_to_char())
        i += used
      }
      'u' => {
        let (v, used) = read_hex(s, i + 2, 4)
        sb.write_char(v.unsafe_to_char())
        i += used
      }
      _ =>
        if d.is_ascii_digit() {
          let (v, used) = read_octal(s, i + 1)
          sb.write_char(v.unsafe_to_char())
          i += used
        } else {
          sb.write_char('\\')
          i += 1
        }
    }
  }
  sb.to_string()
}

///|
fn read_hex(s : String, start : Int, max : Int) -> (Int, Int) {
  let mut v = 0
  let mut used = 0
  for ;; {
    if used >= max {
      break
    }
    let c = match s.get_char(start + used) {
      None => break
      Some(c) => c
    }
    if !c.is_ascii_hexdigit() {
      break
    }
    v = v * 16 + hex_value(c)
    used += 1
  }
  if used == 0 {
    (0, 1)
  } else {
    (v, used + 2)
  }
}

///|
fn hex_value(c : Char) -> Int {
  if c.is_ascii_digit() {
    c.to_int() - '0'.to_int()
  } else {
    c.to_ascii_lowercase().to_int() - 'a'.to_int() + 10
  }
}

///|
fn read_octal(s : String, start : Int) -> (Int, Int) {
  let mut v = 0
  let mut used = 0
  for ;; {
    if used >= 3 {
      break
    }
    let c = match s.get_char(start + used) {
      None => break
      Some(c) => c
    }
    if !c.is_ascii_octdigit() {
      break
    }
    v = v * 8 + (c.to_int() - '0'.to_int())
    used += 1
  }
  if used == 0 {
    (0, 1)
  } else {
    (v, used + 1)
  }
}

///|
/// zsh's numeric glob: `<1-10>`, `<->`, `<-3>`. zsh recognises it wherever a
/// `<` starts a token, so `echo <1->` is a pattern and not a redirection. The
/// shape is the state machine in zsh's isnumglob(): digits, then `-`, then
/// digits, then `>`. Both digit runs may be empty.
fn Lexer::isnumglob_at(self : Lexer) -> Bool {
  let mut i = self.pos + 1
  for ;; {
    match self.src.get_char(i) {
      Some(c) => if c.is_ascii_digit() { i += 1 } else { break }
      None => break
    }
  }
  if self.src.get_char(i) != Some('-') {
    return false
  }
  i += 1
  for ;; {
    match self.src.get_char(i) {
      Some(c) => if c.is_ascii_digit() { i += 1 } else { break }
      None => break
    }
  }
  self.src.get_char(i) == Some('>')
}

///|
/// Read a numeric glob, `<` already seen. Returns its text and leaves the
/// cursor after the closing `>`.
fn Lexer::read_numeric_glob(self : Lexer) -> String {
  let start = self.pos
  for ;; {
    match self.peek() {
      Some('>') => {
        self.advance(1)
        break
      }
      None => break
      Some(_) => self.advance(1)
    }
  }
  self.slice(start, self.pos)
}

///|
/// Whether the text read so far is an array-assignment head: `name`, `name+`
/// or `name[index]`. In zsh `name=(a b)` is an array, while `=(cmd)` anywhere
/// else in a word is process substitution writing to a temporary file, so the
/// two have to be told apart before the `(` is read.
fn looks_like_array_assign(
  parts : Array[WordPart],
  lit : StringBuilder,
) -> Bool {
  match word_text(parts, lit) {
    Some(text) => looks_like_array_head_text(text, true)
    None => false
  }
}

///|
/// Without the trailing `=`: the shapes where `=(` is an array assignment
/// rather than zsh's `=( )` process substitution.
fn looks_like_array_head(parts : Array[WordPart], lit : StringBuilder) -> Bool {
  match word_text(parts, lit) {
    Some(text) => looks_like_array_head_text(text, false)
    None => false
  }
}

///|
/// The literal text read so far, or `None` if any part is not literal.
fn word_text(parts : Array[WordPart], lit : StringBuilder) -> String? {
  let sb = StringBuilder()
  for p in parts {
    match p {
      Lit(s) => sb.write_string(s)
      _ => return None
    }
  }
  sb.write_string(lit.to_string())
  Some(sb.to_string())
}

///|
/// The shared body. `name`, `name+`, `name[index]`, and with `with_equals` the
/// same followed by exactly one `=`.
fn looks_like_array_head_text(text : String, with_equals : Bool) -> Bool {
  let n = text.length()
  if n == 0 {
    return false
  }
  match text.get_char(0) {
    Some(c) => if !is_name_start(c) { return false }
    None => return false
  }
  let mut i = 1
  for ;; {
    if i >= n {
      break
    }
    match text.get_char(i) {
      Some(c) => if is_name_char(c) { i += 1 } else { break }
      None => break
    }
  }
  if i < n && text.get_char(i) == Some('[') {
    let mut depth = 0
    for ;; {
      if i >= n {
        return false
      }
      match text.get_char(i) {
        Some('[') => depth += 1
        Some(']') => depth -= 1
        Some('\\') => i += 1
        _ => ()
      }
      i += 1
      if depth == 0 {
        break
      }
    }
  }
  if i < n && text.get_char(i) == Some('+') {
    i += 1
  }
  if with_equals {
    // `name=(` only: the `=` has to be there and be the last character, or a
    // plain word followed by a pattern like `echo a(b)` would look like one.
    if i >= n || text.get_char(i) != Some('=') {
      return false
    }
    i += 1
  }
  i == n
}
