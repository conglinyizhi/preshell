///|
/// Here-documents: the redirect whose body arrives after the line that opened
/// it.
///
/// The body is collected once the newline has been seen, so the lexer keeps a
/// pending list and fills the bodies in afterwards. `<<-` strips leading tabs
/// from the body, and the delimiter is quoted or not — which decides whether the
/// shell expands the body, a difference the report has to keep visible.

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
