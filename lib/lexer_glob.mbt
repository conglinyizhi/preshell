///|
/// Matching inside a word: the glob operators `*` and `?`, the bracket
/// expression `[...]`, and the extension groups (`+(a|b)` and the rest).
///
/// Each of the three decides where a word's piece ends, and each has a way to
/// fail softly: an unclosed `[` is literal text rather than an error, and an
/// extension group that never closes returns nothing so the caller can fall
/// back. Reading the boundaries here and nowhere else is what keeps `[a]` and
/// `@(a|b)` from being cut in two places with two different answers.

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
/// Index just past a bracket expression starting at the cursor, or None when
/// there is no bracket expression here.
///
/// A `]` inside a quoted region still closes it: measured in bash 5.3, `a[']'`
/// matches a file named `a]`, so the quoted `]` is both the sole member and the
/// terminator. What the scan must then do is swallow the rest of that quoted
/// region before returning. Stopping at the `]` left the closing quote dangling,
/// and the word reader took it for the start of a new quote, which turned
/// `echo a[']'` (a command bash runs) into "unterminated single quote".
fn Lexer::bracket_end(self : Lexer) -> Int? {
  let mut i = 1
  // The quoted region the scan is inside, if any.
  let mut quote = '\u{0}'
  // Set once a `]` closed the bracket from inside a quoted region: the end of
  // that region is where the bracket expression itself ends.
  let mut closing = -1
  for ;; {
    // The bracket closed inside a quoted region, and that region is now over:
    // the whole thing is one glob, so the closing quote belongs to it too.
    if closing > 0 && quote == '\u{0}' {
      return Some(i)
    }
    let c = match self.peek_at(i) {
      None => return None
      Some(c) => c
    }
    if closing > 0 {
      if c == '\\' && quote == '"' {
        i += 2
        continue
      }
      if c == quote {
        quote = '\u{0}'
      }
      i += 1
      continue
    }
    if c == ']' {
      if quote == '\u{0}' {
        return Some(i + 1)
      }
      closing = i + 1
      i += 1
      continue
    }
    // A backslash escapes what follows, so `\"` is a literal quote and does
    // not open a region: measured, `case x in *[\"]*) : ;; esac` runs in both
    // shells while the bare `*["]*)` is refused by both. Without this the scan
    // read on to the next quote in the command and swallowed the rest of the
    // pattern list with it.
    if c == '\\' && quote == '\u{0}' {
      i += 2
      continue
    }
    if c == '"' || c == '\'' {
      if quote == c {
        quote = '\u{0}'
      } else if quote == '\u{0}' {
        quote = c
      }
      i += 1
      continue
    }
    // A blank or a metacharacter ends the word, but only outside quotes.
    if quote == '\u{0}' && (is_blank(c) || c == '\n' || is_meta(c)) {
      return None
    }
    i += 1
  }
}
