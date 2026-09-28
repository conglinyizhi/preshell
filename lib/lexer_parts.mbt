///|
/// Reading a word into its parts.
///
/// A word is not a string: `"a$x"` is text with a hole in it, and the audit has
/// to keep the two apart. This file is the scanner for those parts — quotes,
/// globs, backticks, escaping — and it is where the grammar is most sensitive to
/// the dialect, because zsh and bash do not agree about what a bare `(` or an
/// unquoted `}` in the middle of a word means.

///|
/// Read word fragments until the context ends. `unquoted` is false inside a
/// double-quoted string, where only `"` stops the scan and `\` only escapes
/// a few characters.
fn Lexer::read_parts(self : Lexer, unquoted : Bool) -> Array[WordPart] {
  let start = self.pos
  let parts : Array[WordPart] = []
  let lit = StringBuilder()
  // Depth of a zsh pattern group: `*(.)`, `(a|b)`, `(#i)foo`. Inside one, the
  // group's own parens are word characters and blanks are not word separators.
  let mut pct = 0
  // zsh counts plain braces inside a word (`bct` in Src/lex.c gettokstr). A
  // `}` that closes a `{` read here is word content; one that does not is the
  // literal right brace the lexer pushes back at the end of the word.
  let mut bct = 0
  // zsh's `in_brace_param`: the level of a `{` that directly follows an
  // unescaped `$` (Src/lex.c, the String case). Only `$`-braces set it, and
  // while it is set blanks, newlines, `;`, `&`, `|`, `(` and `<`/`>` stay
  // inside the word.
  let mut brace_param = 0
  // Line where that region opened, for the "closing brace expected" complaint.
  let mut brace_param_line = self.line
  // Offset just past the most recent literal right brace. It equals `self.pos`
  // only while nothing has been read after that brace, which is exactly when
  // zsh's pushback fires.
  let mut rbrace_end = -1
  // True once an escape was consumed in this word. bash decides the assignment
  // form from the raw token, where a backslash is not a legal variable
  // character, so `a\=~/x` is not one and its tilde stays literal (measured).
  let mut escaped = false
  // True when the word stopped at a newline while a pattern group was still
  // open. zsh keeps reading the group across the newline (`inbl && !pct` gates
  // the break), so the `}` before it is not the last character of the word
  // there and gettokstr does not push it back. This lexer ends the word at the
  // newline instead, so the pushback has to be suppressed to stay with zsh.
  let mut newline_in_group = false
  for ;; {
    let c = match self.peek() {
      None => break
      Some(c) => c
    }
    if unquoted && self.dialect is Zsh {
      let in_dbrace = brace_param > 0
      if c == '(' && !in_dbrace {
        // `name=(a b)` and `name+=(a b)`: this `(` opens an array, so the word
        // ends here and the parser sees the operator. Without this the `(`
        // became word content and the elements were read as commands.
        if looks_like_array_assign(parts, lit) {
          self.array_open = true
          break
        }
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
      } else if c == ')' && !in_dbrace {
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
      let in_dbrace = self.dialect is Zsh && brace_param > 0
      if c == '\n' && !in_dbrace {
        if in_group {
          newline_in_group = true
        }
        break
      }
      if is_blank(c) && !in_group && !in_dbrace {
        break
      }
      // zsh keeps `|` inside a group: `(a|b)` is one pattern, not a pipeline.
      // `;`, `&` and redirections still end the word there.
      // Inside a group only `;`, `&` and redirections end the word. A numeric
      // glob is a pattern even there: `case x in a:(s.<1-2>))` runs in zsh.
      let numglob_here = self.dialect is Zsh && c == '<' && self.isnumglob_at()
      let ends_word = if in_dbrace {
        // Src/lex.c: while `in_brace_param` is set, `;`, `&`, `|`, `<` and
        // `>` are word content. Measured: `$${x;y}` and `$${x|y}` run in zsh
        // and the whole brace group is one word.
        false
      } else if in_group {
        (c == ';' || c == '&' || c == '<' || c == '>') && !numglob_here
      } else if self.dialect is Zsh && c == '(' {
        // Mid-word zsh never treats `(` as an operator; the group was counted
        // above and already became word content.
        false
      } else if self.dialect is Zsh && c == '<' && self.isnumglob_at() {
        // A numeric glob, not a redirection: `echo <1->`.
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
              escaped = true
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
      '<' | '>' if unquoted && self.peek_at(1) == Some('(') => {
        let dir = c
        self.advance(2)
        flush_lit(parts, lit)
        parts.push(ProcSub(dir, self.sub_seq("process substitution")))
      }
      '<' if self.dialect is Zsh && self.isnumglob_at() => {
        flush_lit(parts, lit)
        parts.push(Glob(self.read_numeric_glob()))
      }
      '+' | '@' | '!' if unquoted && self.peek_at(1) == Some('(') => {
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
      '=' if unquoted &&
        self.dialect is Zsh &&
        self.peek_at(1) == Some('(') &&
        !looks_like_array_head(parts, lit) => {
        // zsh's `=(cmd)` is not a pipe: it writes the command's output to a
        // real file and substitutes the path. Read in word position, where
        // bash has no construct at all.
        self.advance(2)
        flush_lit(parts, lit)
        parts.push(ProcSub('=', self.sub_seq("=( ) process substitution")))
      }
      '[' if unquoted &&
        self.cmd_pos &&
        !self.in_casepat &&
        self.peek_at(1) == Some('[') => {
        // `[[` in command position is the conditional keyword, not a bracket
        // expression. Reading it as a glob swallowed the whole condition into
        // one word: `[[ "$x" == a ]]` became a single command word.
        flush_lit(parts, lit)
        self.advance(2)
        parts.push(Lit("[["))
        break
      }
      '{' if unquoted &&
        self.dialect is Zsh &&
        self.pos == start &&
        self.cmd_pos &&
        !self.in_casepat &&
        !self.in_for_words &&
        !self.array_elems => {
        // zsh's lexer returns the `{` on its own as soon as it opens a word at
        // a command position (Src/lex.c, the Inbrace case), so `{}` is the
        // empty group rather than one word named `{}`. Anywhere else the
        // braces belong to the word: `echo {a,b}` is still one word, and so is
        // each element of `for i in {a,b}`.
        flush_lit(parts, lit)
        self.advance(1)
        parts.push(Lit("{"))
        break
      }
      '{' if unquoted && self.dialect is Zsh => {
        // A plain `{` inside a word is word content, but it still pairs: the
        // `}` that closes it must not be pushed back out of the word. A `{`
        // directly after an unescaped `$` opens zsh's `in_brace_param` region.
        bct += 1
        if brace_param == 0 && self.dollar_brace_before(start) {
          brace_param = bct
          brace_param_line = self.line
        }
        rbrace_end = -1
        lit.write_char('{')
        self.advance(1)
      }
      '}' if unquoted && self.dialect is Zsh => {
        if bct > 0 {
          bct -= 1
          if bct < brace_param {
            brace_param = 0
          }
          rbrace_end = -1
        } else {
          // zsh's pushback candidate (Src/lex.c, the `lexbuf.ptr[-1] == '}'`
          // hack): the `}` did not close a brace read in this word, so if it
          // turns out to be the last character the word ends before it.
          rbrace_end = self.pos + 1
        }
        lit.write_char('}')
        self.advance(1)
      }
      '[' if unquoted && self.looks_like_subscript() => {
        flush_lit(parts, lit)
        parts.push(Subscript(self.read_subscript()))
      }
      '*' | '?' | '[' if unquoted => {
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
      '~' if unquoted && !escaped && tilde_at_value_start(parts, lit) => {
        let t = self.read_tilde()
        match t {
          Some(text) => {
            // The prefix (`of=` in `of=~/z`) is literal text that comes before
            // the expansion, so it has to be flushed first.
            flush_lit(parts, lit)
            parts.push(Tilde(text))
          }
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
  if unquoted && self.dialect is Zsh && brace_param > 0 {
    // zsh's gettokstr ends with this when it reaches the end of the word with
    // in_brace_param still set, and the word cannot end before then: neither
    // blanks nor separators close it. Measured `echo $${x<y` (unclosed) is
    // `zsh: closing brace expected`, while `echo $${x<y}` runs.
    self.fail_at("closing brace expected", brace_param_line)
  }
  // The pushback: at the end of a word zsh cuts off a literal `}` that did not
  // close a brace inside the word, ungets it, and re-lexes it as its own token
  // (Src/lex.c: `unset(IGNOREBRACES) && !sub && lexbuf.len > 1 &&
  // peek == STRING && lexbuf.ptr[-1] == '}'`). The `len > 1` guard is the
  // "not the whole word" test: a lone `}` stays a word.
  if unquoted &&
    self.dialect is Zsh &&
    rbrace_end == self.pos &&
    self.pos > start + 1 &&
    !newline_in_group {
    let text = lit.to_string()
    if text.length() > 0 && text.get_char(text.length() - 1) == Some('}') {
      lit.reset()
      lit.write_string(text.unsafe_substring(start=0, end=text.length() - 1))
      self.pos -= 1
    }
  }
  flush_lit(parts, lit)
  parts
}

///|
/// True when the character just before the cursor is an unescaped `$` that is
/// itself inside the word being read. zsh's lexer sets `in_brace_param` when a
/// `$` is immediately followed by `{` (Src/lex.c, the String case), and that
/// flag, not the character before the brace in the abstract, is what keeps
/// blanks, `|`, `;` and `<`/`>` inside the word afterwards. `$${x` is the
/// spelling that reaches this code: a real `${` is consumed by `read_dollar`
/// before the brace is ever seen here.
fn Lexer::dollar_brace_before(self : Lexer, start : Int) -> Bool {
  if self.pos <= start {
    return false
  }
  let at = self.pos - 1
  if self.src.get_char(at) != Some('$') {
    return false
  }
  let mut backslashes = 0
  let mut j = at - 1
  while j >= 0 && self.src.get_char(j) == Some('\\') {
    backslashes += 1
    j -= 1
  }
  backslashes % 2 == 0
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
///
/// It is still the *same* shell reading it, so the dialect travels with the
/// text: reading a zsh backquote with bash rules turned `echo *(.)` into a
/// syntax error and `>!` into a write of a file named `!`.
fn Lexer::backquote_seq(self : Lexer, text : String) -> Seq {
  let sub = Lexer::with_dialect(text, self.dialect)
  let seq = parse_sub_seq_eof(sub)
  for e in sub.errors {
    self.fail(e)
  }
  seq
}

///|
/// Skip the body of a `"` that opened inside `${...}`, closing quote included.
/// Only the end position matters here: a backslash escapes the next character
/// and everything else, `}` included, stays literal. Measured against zsh
/// 5.9.2: `x=${a"b}c"}` is one expansion whose body holds the brace.
fn Lexer::read_nested_dquote(self : Lexer) -> Unit {
  for ;; {
    match self.peek() {
      None => break
      Some('\\') => self.advance(2)
      Some('"') => {
        self.advance(1)
        break
      }
      Some(_) => self.advance(1)
    }
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
