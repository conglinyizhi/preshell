///|
/// Tokens. The auditor never expands anything, so a "word" is a word plus the
/// holes inside it, and everything else is an operator or a line break.
pub(all) enum Tok {
  TWord(Word)
  TOp(String)
  TNewline
  TEof
} derive(Debug, Eq)

///|
fn is_meta(c : Char) -> Bool {
  match c {
    ';' | '&' | '|' | '(' | ')' | '<' | '>' => true
    _ => false
  }
}

///|
fn is_blank(c : Char) -> Bool {
  match c {
    ' ' | '\t' | '\r' => true
    _ => false
  }
}

///|
fn is_name_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c == '_'
}

///|
fn is_name_char(c : Char) -> Bool {
  is_name_start(c) || c.is_ascii_digit()
}

///|
pub(all) struct Lexer {
  src : String
  mut pos : Int
  mut line : Int
  /// Here-documents whose delimiter has been seen but whose body has not.
  /// The body can only be read after the newline that ends the current line.
  mut pending : Array[Redirect]
  mut errors : Array[String]
  mut depth : Int
  /// Offset where the token most recently returned by `next` starts.
  mut tok_start : Int
}

///|
pub fn Lexer::new(src : String) -> Lexer {
  { src, pos: 0, line: 1, pending: [], errors: [], depth: 0, tok_start: 0, }
}

///|
fn Lexer::peek(self : Lexer) -> Char? {
  self.src.get_char(self.pos)
}

///|
fn Lexer::peek_at(self : Lexer, n : Int) -> Char? {
  self.src.get_char(self.pos + n)
}

///|
fn Lexer::slice(self : Lexer, a : Int, b : Int) -> String {
  self.src.unsafe_substring(start=a, end=b)
}

///|
fn Lexer::advance(self : Lexer, n : Int) -> Unit {
  for _ in 0..<n {
    match self.peek() {
      Some('\n') => self.line += 1
      _ => ()
    }
    self.pos += 1
  }
}

///|
pub fn Lexer::next(self : Lexer) -> Tok {
  for ;; {
    let c = match self.peek() {
      None => {
        if self.pending.length() > 0 {
          self.gather_heredocs()
        }
        return TEof
      }
      Some(c) => c
    }
    if is_blank(c) {
      self.pos += 1
      continue
    }
    if c == '\n' {
      self.pos += 1
      self.line += 1
      if self.pending.length() > 0 {
        self.gather_heredocs()
      }
      return TNewline
    }
    if c == '\\' && self.peek_at(1) == Some('\n') {
      self.pos += 2
      self.line += 1
      continue
    }
    if c == '#' {
      for ;; {
        match self.peek() {
          None | Some('\n') => break
          Some(_) => self.pos += 1
        }
      }
      continue
    }
    self.tok_start = self.pos
    let prosub = (c == '<' || c == '>') && self.peek_at(1) == Some('(')
    if is_meta(c) && !prosub {
      return TOp(self.read_operator())
    }
    return TWord(self.read_word())
  }
}

///|
fn Lexer::read_operator(self : Lexer) -> String {
  let start = self.pos
  let c = self.peek()
  self.pos += 1
  match c {
    Some(';') =>
      if self.peek() == Some(';') {
        self.pos += 1
        if self.peek() == Some('&') {
          self.pos += 1
        }
      } else if self.peek() == Some('&') {
        self.pos += 1
      }
    Some('&') =>
      if self.peek() == Some('&') {
        self.pos += 1
      } else if self.peek() == Some('>') {
        self.pos += 1
        if self.peek() == Some('>') {
          self.pos += 1
        }
      }
    Some('|') =>
      if self.peek() == Some('|') || self.peek() == Some('&') {
        self.pos += 1
      }
    Some('(') => if self.peek() == Some('(') { self.pos += 1 }
    Some(')') => if self.peek() == Some(')') { self.pos += 1 }
    Some('<') =>
      if self.peek() == Some('<') {
        self.pos += 1
        if self.peek() == Some('-') || self.peek() == Some('<') {
          self.pos += 1
        }
      } else if self.peek() == Some('&') || self.peek() == Some('>') {
        self.pos += 1
      }
    Some('>') =>
      if self.peek() == Some('>') ||
        self.peek() == Some('&') ||
        self.peek() == Some('|') {
        self.pos += 1
      }
    _ => ()
  }
  self.slice(start, self.pos)
}

///|
fn Lexer::read_word(self : Lexer) -> Word {
  let line = self.line
  let start = self.pos
  let parts = self.read_parts(true)
  { parts, raw: self.slice(start, self.pos), line, }
}

///|
/// Read word fragments until the context ends. `unquoted` is false inside a
/// double-quoted string, where only `"` stops the scan and `\` only escapes
/// a few characters.
fn Lexer::read_parts(self : Lexer, unquoted : Bool) -> Array[WordPart] {
  let parts : Array[WordPart] = []
  let lit = StringBuilder()
  for ;; {
    let c = match self.peek() {
      None => break
      Some(c) => c
    }
    if unquoted {
      if is_blank(c) || c == '\n' {
        break
      }
      let prosub = (c == '<' || c == '>') && self.peek_at(1) == Some('(')
      if is_meta(c) && !prosub {
        break
      }
    } else if c == '"' {
      break
    }
    match c {
      '\\' =>
        match self.peek_at(1) {
          None => {
            self.advance(1)
            lit.write_char('\\')
          }
          Some('\n') => self.advance(2)
          Some(d) =>
            if !unquoted && !(d == '"' || d == '$' || d == '`' || d == '\\') {
              self.advance(1)
              lit.write_char('\\')
            } else {
              self.advance(2)
              lit.write_char(d)
            }
        }
      '\'' if unquoted => {
        self.advance(1)
        let s = self.read_until('\'')
        if self.peek() == Some('\'') {
          self.advance(1)
        } else {
          self.errors.push("unterminated single quote")
        }
        flush_lit(parts, lit)
        parts.push(SQuote(s))
      }
      '"' => {
        self.advance(1)
        let inner = self.read_parts(false)
        if self.peek() == Some('"') {
          self.advance(1)
        } else {
          self.errors.push("unterminated double quote")
        }
        flush_lit(parts, lit)
        parts.push(DQuote(inner))
      }
      '`' => {
        self.advance(1)
        let body = self.read_backtick()
        flush_lit(parts, lit)
        parts.push(CmdSub(self.backquote_seq(body)))
      }
      '$' => self.read_dollar(parts, lit)
      '<' | '>' if self.peek_at(1) == Some('(') => {
        let dir = c
        self.advance(2)
        flush_lit(parts, lit)
        parts.push(ProcSub(dir, self.sub_seq("process substitution")))
      }
      '+' | '@' | '!' if self.peek_at(1) == Some('(') => {
        let g = self.read_extglob()
        match g {
          Some(text) => {
            flush_lit(parts, lit)
            parts.push(Glob(text))
          }
          None => {
            lit.write_char(c)
            self.advance(1)
          }
        }
      }
      '[' if self.looks_like_subscript() => {
        flush_lit(parts, lit)
        parts.push(Subscript(self.read_subscript()))
      }
      '*' | '?' | '[' => {
        let g = self.read_glob()
        match g {
          Some(text) => {
            flush_lit(parts, lit)
            parts.push(Glob(text))
          }
          None => {
            lit.write_char(c)
            self.advance(1)
          }
        }
      }
      '~' if unquoted && parts.length() == 0 && lit.is_empty() => {
        let t = self.read_tilde()
        match t {
          Some(text) => parts.push(Tilde(text))
          None => {
            lit.write_char(c)
            self.advance(1)
          }
        }
      }
      _ => {
        lit.write_char(c)
        self.advance(1)
      }
    }
  }
  flush_lit(parts, lit)
  parts
}

///|
fn flush_lit(parts : Array[WordPart], lit : StringBuilder) -> Unit {
  if !lit.is_empty() {
    parts.push(Lit(lit.to_string()))
    lit.reset()
  }
}

///|
fn Lexer::read_until(self : Lexer, stop : Char) -> String {
  let start = self.pos
  for ;; {
    match self.peek() {
      None => break
      Some(c) => if c == stop { break } else { self.advance(1) }
    }
  }
  self.slice(start, self.pos)
}

///|
/// \`$'...'\`: inside ANSI-C quoting a backslash escapes the closing quote,
/// so \`$'it\\'s'\` is one word and not the start of a runaway string.
fn Lexer::read_ansi_body(self : Lexer) -> String {
  let sb = StringBuilder()
  for ;; {
    match self.peek() {
      None => {
        self.errors.push("unterminated $'")
        break
      }
      Some('\'') => {
        self.advance(1)
        break
      }
      Some('\\') =>
        match self.peek_at(1) {
          None => self.advance(1)
          Some(d) => {
            sb.write_char('\\')
            sb.write_char(d)
            self.advance(2)
          }
        }
      Some(c) => {
        sb.write_char(c)
        self.advance(1)
      }
    }
  }
  sb.to_string()
}

///|
fn Lexer::read_backtick(self : Lexer) -> String {
  let sb = StringBuilder()
  for ;; {
    match self.peek() {
      None => {
        self.errors.push("unterminated backquote")
        break
      }
      Some('`') => {
        self.advance(1)
        break
      }
      Some('\\') =>
        match self.peek_at(1) {
          Some(d) =>
            if d == '`' || d == '\\' || d == '$' {
              sb.write_char(d)
              self.advance(2)
            } else {
              sb.write_char('\\')
              self.advance(1)
            }
          None => self.advance(1)
        }
      Some(c) => {
        sb.write_char(c)
        self.advance(1)
      }
    }
  }
  sb.to_string()
}

///|
/// `<(...)`, `>(...)` and `$(...)` all end at a `)` that belongs to them.
/// Finding it needs a real parse, because `case x in a) ... esac` is legal
/// inside a command substitution and its `)` does not close it.
fn Lexer::sub_seq(self : Lexer, what : String) -> Seq {
  if self.depth >= 24 {
    self.errors.push("nesting too deep")
    return Seq::empty()
  }
  self.depth += 1
  let (seq, closed) = parse_sub_seq(self, ")")
  self.depth -= 1
  if !closed {
    self.errors.push("unterminated " + what)
  }
  seq
}

///|
/// A backquoted command gets its own little input: it ends at the end of that
/// text, not at a `)`.
fn Lexer::backquote_seq(self : Lexer, text : String) -> Seq {
  let sub = Lexer::new(text)
  let seq = parse_sub_seq_eof(sub)
  for e in sub.errors {
    self.errors.push(e)
  }
  seq
}

///|
fn Lexer::read_glob(self : Lexer) -> String? {
  let sb = StringBuilder()
  for ;; {
    match self.peek() {
      Some('*') | Some('?') => {
        sb.write_char(self.peek().unwrap())
        self.advance(1)
      }
      Some('[') =>
        match self.bracket_end() {
          Some(len) =>
            for _ in 0..<len {
              sb.write_char(self.peek().unwrap())
              self.advance(1)
            }
          None => break
        }
      _ => break
    }
  }
  if sb.is_empty() {
    None
  } else {
    Some(sb.to_string())
  }
}

///|
/// An extglob group such as `+(a|b)` is one word.
fn Lexer::read_extglob(self : Lexer) -> String? {
  let start = self.pos
  let sb = StringBuilder()
  sb.write_char(self.peek().unwrap())
  sb.write_char('(')
  self.advance(2)
  let mut depth = 1
  for ;; {
    match self.peek() {
      None => return None
      Some('(') => {
        depth += 1
        sb.write_char('(')
        self.advance(1)
      }
      Some(')') => {
        depth -= 1
        sb.write_char(')')
        self.advance(1)
        if depth == 0 {
          break
        }
      }
      Some(c) => {
        sb.write_char(c)
        self.advance(1)
      }
    }
  }
  if depth != 0 {
    self.pos = start
    None
  } else {
    Some(sb.to_string())
  }
}

///|
/// Length of a `[...]` glob bracket starting at the current position, if it
/// really looks like one; otherwise None.
fn Lexer::bracket_end(self : Lexer) -> Int? {
  let mut i = 1
  for ;; {
    match self.peek_at(i) {
      None => return None
      Some(']') => return Some(i + 1)
      Some(c) => {
        if is_blank(c) || c == '\n' || is_meta(c) {
          return None
        }
        i += 1
      }
    }
  }
}

///|
fn Lexer::read_tilde(self : Lexer) -> String? {
  let start = self.pos
  self.advance(1)
  for ;; {
    match self.peek() {
      Some(c) if is_name_char(c) => self.advance(1)
      _ => break
    }
  }
  match self.peek() {
    None | Some('/') => Some(self.slice(start, self.pos))
    Some(c) =>
      if is_blank(c) || is_meta(c) || c == '\n' {
        Some(self.slice(start, self.pos))
      } else {
        self.pos = start
        None
      }
  }
}

///|
fn Lexer::read_dollar(
  self : Lexer,
  parts : Array[WordPart],
  lit : StringBuilder,
) -> Unit {
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
      parts.push(Param(self.read_braced()))
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
fn Lexer::read_braced(self : Lexer) -> String {
  let start = self.pos
  let mut depth = 0
  for ;; {
    match self.peek() {
      None => {
        self.errors.push("unterminated ${")
        break
      }
      Some('{') => {
        depth += 1
        self.advance(1)
      }
      Some('}') =>
        if depth == 0 {
          break
        } else {
          depth -= 1
          self.advance(1)
        }
      Some('\'') => {
        self.advance(1)
        ignore(self.read_until('\''))
        if self.peek() == Some('\'') {
          self.advance(1)
        }
      }
      Some('"') => {
        self.advance(1)
        ignore(self.read_until('"'))
        if self.peek() == Some('"') {
          self.advance(1)
        }
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
    self.errors.push("unterminated arithmetic expansion")
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
/// Here-document bodies are read after the line that introduced them.
/// `pending` holds the redirects in the order they appeared.
fn Lexer::gather_heredocs(self : Lexer) -> Unit {
  let pend = self.pending
  self.pending = []
  for r in pend {
    let (delim, _quoted) = heredoc_delimiter(r.target)
    let strip = r.op is RHereDocStrip
    let sb = StringBuilder()
    for ;; {
      if self.pos >= self.src.length() {
        self.errors.push("unterminated here-document")
        break
      }
      let line_start = self.pos
      let mut i = self.pos
      for ;; {
        match self.src.get_char(i) {
          None => break
          Some('\n') => break
          Some(_) => i += 1
        }
      }
      let line = self.slice(line_start, i)
      self.pos = if i < self.src.length() { i + 1 } else { i }
      self.line += 1
      let body_line = if strip { strip_leading_tabs(line) } else { line }
      if body_line == delim {
        break
      }
      sb.write_string(body_line)
      sb.write_char('\n')
    }
    r.body = Some(sb.to_string())
  }
}

///|
fn strip_leading_tabs(s : String) -> String {
  let mut i = 0
  for ;; {
    match s.get_char(i) {
      Some('\t') => i += 1
      _ => break
    }
  }
  s.unsafe_substring(start=i, end=s.length())
}

///|
/// The delimiter text plus whether it was quoted. A quoted delimiter turns
/// the whole body into literal text; an unquoted one still expands.
pub fn heredoc_delimiter(w : Word) -> (String, Bool) {
  let text = w.literal_text()
  let quoted = w.raw != text
  (text, quoted)
}
