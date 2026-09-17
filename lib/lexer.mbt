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
  /// Line of each entry in `errors`, index for index.
  mut error_lines : Array[Int]
  mut depth : Int
  /// Offset where the token most recently returned by `next` starts.
  mut tok_start : Int
  /// Grammar to read. Consulted only where the two shells disagree.
  dialect : Dialect
  /// Whether the next token would start a command. zsh's lexer tracks this
  /// itself (`incmdpos`) and uses it to decide whether `(` opens a subshell or
  /// is just part of a word: `echo *(.)` is a glob, `(echo x)` is a subshell.
  mut cmd_pos : Bool
}

///|
pub fn Lexer::new(src : String) -> Lexer {
  Lexer::with_dialect(src, Bash)
}

///|
pub fn Lexer::with_dialect(src : String, dialect : Dialect) -> Lexer {
  {
    src,
    pos: 0,
    line: 1,
    pending: [],
    errors: [],
    error_lines: [],
    depth: 0,
    tok_start: 0,
    dialect,
    cmd_pos: true,
  }
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
///
/// Record a complaint together with the line it happened on. The line matters:
/// "which line is the problem" is the first thing a caller asks, and without it
/// tracking a parse failure down means bisecting the input by hand.
fn Lexer::fail(self : Lexer, message : String) -> Unit {
  self.fail_at(message, self.line)
}

///|
/// Report against a specific line. Construct-level complaints (an unclosed
/// `if`, an unterminated quote) are only useful if they point at where the
/// construct *started*; pointing at end of input says nothing.
fn Lexer::fail_at(self : Lexer, message : String, line : Int) -> Unit {
  self.errors.push(message)
  self.error_lines.push(line)
}

///|

///|
/// Slice by code-unit offsets. Clamped so an inverted range yields an empty
/// string instead of aborting the process: this is called with positions
/// derived from token bookkeeping, and a two-character input once took the
/// whole tool down through `unsafe_substring(start=2, end=0)`.
fn Lexer::slice(self : Lexer, a : Int, b : Int) -> String {
  let hi = if b > a { b } else { a }
  self.src.unsafe_substring(start=a, end=hi)
}

///|

///|
/// Step over `n` *characters*, not code units.
///
/// MoonBit strings are UTF-16, so a character outside the BMP (an emoji, an
/// extended CJK ideograph) occupies two units. Stepping one unit at a time
/// lands inside the surrogate pair, where `get_char` returns None, and the
/// scanner then reads that as end of input: `echo "🧐"` came back as an
/// unterminated double quote.
fn Lexer::advance(self : Lexer, n : Int) -> Unit {
  for _ in 0..<n {
    match self.peek() {
      None => return
      Some('\n') => {
        self.line += 1
        self.pos += 1
      }
      Some(c) => self.pos += if c > '\u{ffff}' { 2 } else { 1 }
    }
  }
}

///|
pub fn Lexer::next(self : Lexer) -> Tok {
  let tok = self.next_raw()
  self.note_position(tok)
  tok
}

///|
/// Track whether the following token would start a command. zsh's lexer does
/// the same thing with `incmdpos`, and it is what tells `echo *(.)` (a word)
/// apart from `(echo x)` (a subshell).
fn Lexer::note_position(self : Lexer, tok : Tok) -> Unit {
  match tok {
    TWord(w) =>
      match w.plain() {
        Some(text) => self.cmd_pos = is_command_word(text)
        None => self.cmd_pos = false
      }
    TNewline => self.cmd_pos = true
    TOp(op) =>
      // A redirection leaves us inside the same command; the word after it
      // clears this again anyway.
      match op {
        ">"
        | "<"
        | ">>"
        | "<<"
        | "<<-"
        | "<&"
        | ">&"
        | "<>"
        | ">|"
        | "&>"
        | "&>>" => ()
        _ => self.cmd_pos = true
      }
    _ => ()
  }
}

///|
/// Words after which a command may start. This is the reserved-word list the
/// parser keys on, plus the two zsh-only block words.
fn is_command_word(w : String) -> Bool {
  match w {
    "if"
    | "then"
    | "elif"
    | "else"
    | "fi"
    | "while"
    | "until"
    | "do"
    | "done"
    | "for"
    | "case"
    | "esac"
    | "in"
    | "select"
    | "function"
    | "time"
    | "coproc"
    | "repeat"
    | "foreach"
    | "{"
    | "}"
    | "!" => true
    _ => false
  }
}

///|
fn Lexer::next_raw(self : Lexer) -> Tok {
  for ;; {
    let c = match self.peek() {
      None => {
        if self.pending.length() > 0 {
          self.gather_heredocs()
        }
        // Record where this token starts even at end of input: callers use it
        // to slice the text between two tokens.
        self.tok_start = self.pos
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
    // zsh: a `(` in word position opens a glob qualifier or pattern group and
    // is part of the word, so it must reach the word reader. At command
    // position it is the subshell operator in both shells.
    let paren_in_word = c == '(' &&
      self.dialect is Zsh &&
      !self.cmd_pos &&
      self.peek_at(1) != Some(')')
    if is_meta(c) && !prosub && !paren_in_word {
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
    // `((` and `))` are deliberately NOT merged here. They only mean
    // arithmetic in an arithmetic context, and merging them everywhere makes a
    // command substitution unable to find its own `)`: `arr=($(echo a))`
    // had the two closing parens glued into one token that the substitution did
    // not accept. The parser recognises the pair by adjacency instead.
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
/// Is the `((` at `start` an arithmetic command, or two nested subshells?
///
/// bash decides mechanically (parse.y:parse_arith_cmd): scan to the `)` that
/// matches, and look at the character after it. Another `)` means arithmetic;
/// anything else means the first paren was a subshell, which is why
/// `((gzip ...) 3>&- | eval ...)` in zdiff is two subshells and not arithmetic.
fn Lexer::is_arith_at(self : Lexer, start : Int) -> Bool {
  let mut i = start + 2
  let mut depth = 1
  for ;; {
    if i - start > 4096 {
      return false
    }
    let c = match self.src.get_char(i) {
      None => return false
      Some(c) => c
    }
    match c {
      '\'' => i = skip_quoted(self.src, i, '\'')
      '"' => i = skip_quoted(self.src, i, '"')
      '\\' => i += 2
      '(' => {
        depth += 1
        i += 1
      }
      ')' => {
        depth -= 1
        i += 1
        if depth == 0 {
          return self.src.get_char(i) == Some(')')
        }
      }
      _ => i += 1
    }
  }
}

///|
fn Lexer::read_word(self : Lexer) -> Word {
  let line = self.line
  let start = self.pos
  let parts = self.read_parts(true)
  // A word that consumed nothing would leave the token stream stuck, so take
  // the character as a literal instead. Nothing should reach this, and a hang
  // is the one failure mode worse than a wrong answer.
  if self.pos == start {
    self.advance(1)
    parts.push(Lit(self.slice(start, self.pos)))
  }
  { parts, raw: self.slice(start, self.pos), line, }
}

///|
/// Read word fragments until the context ends. `unquoted` is false inside a
/// double-quoted string, where only `"` stops the scan and `\` only escapes
/// a few characters.
fn Lexer::read_parts(self : Lexer, unquoted : Bool) -> Array[WordPart] {
  let parts : Array[WordPart] = []
  let lit = StringBuilder()
  // Depth of a zsh pattern group: `*(.)`, `(a|b)`, `(#i)foo`. Inside one, the
  // group's own parens are word characters and blanks are not word separators.
  let mut pct = 0
  for ;; {
    let c = match self.peek() {
      None => break
      Some(c) => c
    }
    if unquoted && self.dialect is Zsh {
      if c == '(' {
        // `()` is the function-definition token, not a pattern group.
        if self.peek_at(1) == Some(')') {
          break
        }
        pct += 1
        // Mark the group as a pattern, not literal text: \`rm (a|b)\` deletes
        // the files matching a or b, and reporting the parenthesised text as a
        // literal path would be a wrong answer rather than a missing one.
        flush_lit(parts, lit)
        parts.push(Glob("("))
        self.advance(1)
        continue
      } else if c == ')' {
        // At depth zero this closes an enclosing subshell: not our word.
        if pct == 0 {
          break
        }
        pct -= 1
        flush_lit(parts, lit)
        parts.push(Glob(")"))
        self.advance(1)
        continue
      }
    }
    if unquoted {
      let in_group = self.dialect is Zsh && pct > 0
      if c == '\n' {
        break
      }
      if is_blank(c) && !in_group {
        break
      }
      // zsh keeps `|` inside a group: `(a|b)` is one pattern, not a pipeline.
      // `;`, `&` and redirections still end the word there.
      let ends_word = if in_group {
        c == ';' || c == '&' || c == '<' || c == '>'
      } else if self.dialect is Zsh && c == '(' {
        // Mid-word zsh never treats `(` as an operator; the group was counted
        // above and already became word content.
        false
      } else {
        is_meta(c) && !((c == '<' || c == '>') && self.peek_at(1) == Some('('))
      }
      if ends_word {
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
        let opened_at = self.line
        self.advance(1)
        let s = self.read_until('\'')
        if self.peek() == Some('\'') {
          self.advance(1)
        } else {
          self.fail_at("unterminated single quote", opened_at)
        }
        flush_lit(parts, lit)
        parts.push(SQuote(s))
      }
      '"' => {
        let opened_at = self.line
        self.advance(1)
        let inner = self.read_parts(false)
        if self.peek() == Some('"') {
          self.advance(1)
        } else {
          self.fail_at("unterminated double quote", opened_at)
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
      '$' => self.read_dollar(parts, lit, !unquoted)
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
        self.fail("unterminated $'")
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
        self.fail("unterminated backquote")
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
    self.fail("nesting too deep")
    return Seq::empty()
  }
  self.depth += 1
  let (seq, _closed) = parse_sub_seq(self, ")", what)
  self.depth -= 1
  seq
}

///|
/// A backquoted command gets its own little input: it ends at the end of that
/// text, not at a `)`.
fn Lexer::backquote_seq(self : Lexer, text : String) -> Seq {
  let sub = Lexer::new(text)
  let seq = parse_sub_seq_eof(sub)
  for e in sub.errors {
    self.fail(e)
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
        self.fail("unterminated ${")
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
/// Here-document bodies are read after the line that introduced them.
/// `pending` holds the redirects in the order they appeared.
fn Lexer::gather_heredocs(self : Lexer) -> Unit {
  let pend = self.pending
  self.pending = []
  for r in pend {
    let (raw_delim, _quoted) = heredoc_delimiter(r.target)
    let strip = r.op is RHereDocStrip
    // `<<-` strips leading tabs from the terminator line *and* from the
    // delimiter itself: `cat <<-'\tEND'` is closed by a `\tEND` line.
    // bash was checked to behave this way; without it the delimiter never
    // matches and the rest of the input is silently swallowed as body.
    let delim = if strip { strip_leading_tabs(raw_delim) } else { raw_delim }
    let sb = StringBuilder()
    for ;; {
      if self.pos >= self.src.length() {
        // A here-document that runs into end of input matches bash: it warns
        // when the line runs, and the remaining text is body, not code.
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
      // Inside a command substitution the delimiter line can be closed by the
      // `)` that ends the substitution: `x=$(cat <<EOF` / `body` / `EOF)`.
      // That `)` belongs to the outer parser (bash spells this with
      // PST_CMDSUBST + shell_eof_token), so leave it in the input.
      if self.depth > 0 {
        match comsub_close_after(body_line, delim) {
          Some(off) => {
            let tabbed = line.length() - body_line.length()
            self.pos = line_start + tabbed + off
            break
          }
          None => ()
        }
      }
      sb.write_string(body_line)
      sb.write_char('\n')
    }
    r.body = Some(sb.to_string())
  }
}

///|
/// Offset of the `)` that closes an enclosing command substitution, when the
/// line begins with the here-document delimiter and only blanks sit between
/// them. None when this line is not a delimiter line at all.
fn comsub_close_after(line : String, delim : String) -> Int? {
  if !line.has_prefix(delim) {
    return None
  }
  let mut i = delim.length()
  for ;; {
    match line.get_char(i) {
      Some(' ') | Some('\t') => i += 1
      Some(')') => return Some(i)
      _ => return None
    }
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
