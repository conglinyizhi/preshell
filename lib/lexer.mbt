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
  /// Set when a word ended at a `(` that opens an array assignment
  /// (`argv+=(`), so the next token is read as the operator it is.
  mut array_open : Bool
  /// Set while the parser is reading the elements of an array assignment. An
  /// element may itself start with `(`, and there it is a pattern: the `(` in
  /// `argv+=( (a|b) )` is word content, not a subshell.
  mut array_elems : Bool
  /// Set while the parser is reading a case pattern, which is zsh's
  /// `incasepat`. A pattern is a word, so `(net|open)bsd*` is one pattern whose
  /// leading `(` is a glob group rather than the pattern list's own paren.
  mut in_casepat : Bool
  /// Set while the parser is reading a `for` loop's names, where zsh allows the
  /// csh form `for x ( a b )`. There the `(` is the word list's own paren, not
  /// a glob group.
  mut in_for_words : Bool
  /// Set while the parser is inside an arithmetic command `(( ... ))`. There a
  /// `#` is an operand (zsh's character-code operator), not a comment: measured,
  /// both bash and zsh parse `(( 1 + 2 # c ))` and `(( #x == 97 ))`.
  mut in_arith : Bool
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
    array_open: false,
    array_elems: false,
    in_casepat: false,
    in_for_words: false,
    in_arith: false,
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
    TNewline => {
      self.cmd_pos = true
      self.array_open = false
    }
    TOp(op) =>
      match op {
        // The `(` that opens an array turns on element reading: the elements
        // are words, so a `(` inside one is a pattern rather than a subshell.
        // It stays on until the matching `)` is emitted.
        "(" => {
          if self.array_open {
            self.array_elems = true
          }
          self.array_open = false
          self.cmd_pos = true
        }
        ")" => {
          if self.array_elems {
            self.array_elems = false
          }
          self.array_open = false
          self.cmd_pos = true
        }
        // A redirection leaves us inside the same command, but the word that
        // follows it is the redirect's target, not a command word. zsh reads
        // that target with `incmdpos` clear, which is why `<{a,b}` is a
        // redirect from the brace expansion and not a redirect from the group
        // brace `{`. Leaving the flag set made the target `{` a group brace.
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
        | "&>>" => self.cmd_pos = false
        _ => {
          self.cmd_pos = true
          self.array_open = false
        }
      }
    _ => self.array_open = false
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
    if c == '#' && !self.in_arith {
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
      // Inside `(( ))` every `(` is an operator: the shell hands the whole
      // expression to its arithmetic parser, so no paren there opens a pattern
      // group. Without this the parser's token-based depth count came up one
      // short and the expression closed early, leaving an orphan `)`.
      !self.in_arith &&
      (!self.cmd_pos || self.array_elems || self.in_casepat) &&
      !self.in_for_words &&
      !self.array_open &&
      self.peek_at(1) != Some(')')
    let numglob = c == '<' && self.dialect is Zsh && self.isnumglob_at()
    // `array_open` is deliberately not cleared here: it was set while reading
    // the word that just ended, and `note_position` is the one that consumes
    // it, once the token that follows is known.
    if is_meta(c) && !prosub && !paren_in_word && !numglob {
      return TOp(self.read_operator())
    }
    return TWord(self.read_word())
  }
}

///|
/// Consume the clobber-override suffix of a redirect operator, if present.
///
/// zsh spells `>|` as `>!` as well, and takes the same suffix after every form
/// that accepts one: in its lexer `d == '!' || d == '|'` appears together at
/// each of those points (Src/lex.c). bash has no `!` spelling, so there the
/// `!` stays a file name -- measured: `bash -c 'echo hi >! out'` writes a file
/// called `!`, `zsh -c 'echo hi >! out'` writes `out`.
fn Lexer::take_clobber_variant(self : Lexer) -> Unit {
  if self.peek() == Some('|') ||
    (self.dialect is Zsh && self.peek() == Some('!')) {
    self.pos += 1
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
        // bash spells "test the next pattern as well" as `;;&`; zsh spells it
        // `;|` and refuses `;;&` outright (measured: parse error near `&`).
        if self.peek() == Some('&') && self.dialect is Bash {
          self.pos += 1
        }
      } else if self.peek() == Some('&') {
        self.pos += 1
      } else if self.peek() == Some('|') && self.dialect is Zsh {
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
        self.take_clobber_variant()
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
      if self.peek() == Some('>') {
        self.pos += 1
        if self.peek() == Some('&') && self.dialect is Zsh {
          // `>>&N` is a zsh spelling; measured, bash refuses `echo a >>&2`
          // (`&>>` is its form). Leaving the `&` alone there turns the input
          // into two operators in a row, which is where it becomes an error.
          self.pos += 1
          self.take_clobber_variant()
        } else {
          // `>>|` / `>>!`: the append form takes the suffix as well.
          self.take_clobber_variant()
        }
      } else if self.peek() == Some('&') {
        self.pos += 1
        self.take_clobber_variant()
      } else {
        self.take_clobber_variant()
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
  { parts, raw: self.slice(start, self.pos), line, origin: None, }
}

///|
/// Length of a `[...]` glob bracket starting at the current position, if it
/// really looks like one; otherwise None.
