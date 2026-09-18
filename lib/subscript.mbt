///|
/// Read a `[...]` subscript: `name[expr]` in an assignment, where quotes are
/// quote characters and brackets nest.
///
/// bash has to decide the moment it sees `[`, because its lexer reads one
/// character at a time (parse.y:5622-5650, `P_ARRAYSUB`, guarded by
/// `token_index > 0 && assignment_acceptable(last_read_token) && token_is_ident`
/// or `PST_COMPASSIGN`). Here the whole line is already in hand, so the decision
/// is a lookahead: brackets followed immediately by `=` are a subscript, and
/// everything else keeps the glob meaning.
fn Lexer::looks_like_subscript(self : Lexer) -> Bool {
  match self.subscript_end() {
    None => false
    Some(end) => {
      // Quotes inside the brackets mean this is a subscript even without an
      // assignment following: `unset A[']']`, `echo A["]"]`.
      let inner = self.slice(self.pos + 1, end - 1)
      if inner.contains_char('"') || inner.contains_char('\'') {
        return true
      }
      match self.src.get_char(end) {
        Some('=') => true
        Some('+') => self.src.get_char(end + 1) == Some('=')
        _ => false
      }
    }
  }
}

///|
/// Index just past the `]` that closes the bracket at the current position, or
/// None. Quotes inside are skipped whole, so `myarray["a]a"]` closes at the
/// outer bracket and not at the one inside the string.
fn Lexer::subscript_end(self : Lexer) -> Int? {
  let mut i = self.pos + 1
  let mut depth = 1
  for ;; {
    // An unclosed bracket stays a literal glob character in bash, so the scan
    // must not run past the end of the line looking for a match: doing that
    // swallowed `echo [[:alpha:]` and every following line with it.
    if i - self.pos > 4096 {
      return None
    }
    let c = match self.src.get_char(i) {
      None => return None
      Some(c) => c
    }
    match c {
      '\n' => return None
      '[' => {
        depth += 1
        i += 1
      }
      ']' => {
        depth -= 1
        i += 1
        if depth == 0 {
          return Some(i)
        }
      }
      '\'' => i = skip_quoted(self.src, i, '\'')
      '"' => i = skip_quoted(self.src, i, '"')
      '\\' => i += 2
      _ => i += 1
    }
  }
}

///|
/// `i` points at an opening quote; return the position just past the closing
/// one, or the end of the string when it never closes.
fn skip_quoted(s : String, i : Int, q : Char) -> Int {
  let mut j = i + 1
  for ;; {
    match s.get_char(j) {
      None => return j
      // A quote that does not close on this line cannot be part of a
      // subscript; hand the newline back so the caller gives up.
      Some('\n') => return j
      Some(c) =>
        if c == q {
          return j + 1
        } else if c == '\\' && q == '"' {
          j += 2
        } else {
          j += 1
        }
    }
  }
}

///|
fn Lexer::read_subscript(self : Lexer) -> Array[WordPart] {
  let start = self.pos + 1
  match self.subscript_end() {
    None => {
      self.fail("unterminated array subscript")
      self.advance(1)
      []
    }
    Some(end) => {
      let inner = self.slice(start, end - 1)
      while self.pos < end {
        self.advance(1)
      }
      // Re-lex the inside so that holes in `a[$i]` and quotes in `a["k]k"]`
      // are still visible to the audit, not flattened into text.
      let sub = Lexer::with_dialect(inner, self.dialect)
      let parts = sub.read_parts(true)
      for e in sub.errors {
        self.fail(e)
      }
      parts
    }
  }
}
