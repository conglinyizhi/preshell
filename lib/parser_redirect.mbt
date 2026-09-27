///|
/// Redirections: `>`, `>>`, `<`, `<<`, `<<<`, `&>`, `>|`, the descriptor forms
/// and the here-document bookkeeping.
///
/// Which operator a word is has to be decided without a table the shell owns, so
/// the shapes are read here and nowhere else. A here-document is the one
/// redirect whose body arrives later, which is why the parser counts them and
/// the lexer gathers them once the line ends.

///|
fn Parser::parse_redirect_list(self : Parser) -> Array[Redirect] {
  let out : Array[Redirect] = []
  for ;; {
    match self.cur {
      TOp(op) =>
        if is_redirect_op(op) {
          out.push(self.parse_redirect(None))
          continue
        } else {
          break
        }
      TWord(w) =>
        // `( ... ) 2>/dev/null`: the fd prefix is glued to the operator.
        if self.peek_is_redirect() && self.fd_adjacent(w) {
          match w.plain() {
            Some(digits) =>
              if all_digits(digits) {
                self.advance()
                out.push(self.parse_redirect(Some(parse_fd(digits))))
                continue
              } else if self.lex.dialect is Bash && is_named_fd(digits) {
                // Measured: bash takes `done {fd}<file`, zsh refuses it. The
                // other call site (inside a simple command) is common ground.
                self.advance()
                out.push(self.parse_redirect(None))
                continue
              } else {
                break
              }
            None => break
          }
        } else {
          break
        }
      _ => break
    }
  }
  out
}

///|
fn Parser::parse_redirect(self : Parser, fd : Int?) -> Redirect {
  let opstr = match self.cur {
    TOp(op) => op
    _ => ""
  }
  self.advance()
  let op = redir_op_of(opstr)
  // A here-document body is read from the next line, so the redirect has to be
  // registered *before* the parser pulls the token that may be the newline.
  if self.cur is TWord(w) && (op is RHereDoc || op is RHereDocStrip) {
    let r : Redirect = { fd, op, target: w, body: None, }
    self.count_heredoc()
    self.lex.pending.push(r)
    self.advance()
    return r
  }
  let target = match self.cur {
    TWord(w) => {
      self.advance()
      w
    }
    _ => {
      // A redirection without a target is a syntax error in every shell that
      // reads this syntax, so reporting a wordless redirect would be a claim
      // that a command runs when it does not.
      self.lex.fail("expected a word after the redirection operator")
      empty_word(self.lex.line)
    }
  }
  let r : Redirect = { fd, op, target, body: None, }
  r
}

///|
fn is_redirect_op(op : String) -> Bool {
  match op {
    "<"
    | ">"
    | ">>"
    | "<>"
    | "<&"
    | ">&"
    | "<<"
    | "<<-"
    | "<<<"
    | "&>"
    | "&>>"
    | ">>&"
    // The clobber spellings zsh accepts: `>|` and `>!`, and the same suffix on
    // the other redirect forms.
    | ">|"
    | ">!"
    | ">>|"
    | ">>!"
    | ">&|"
    | ">&!"
    | ">>&|"
    | ">>&!"
    | "&>|"
    | "&>!"
    | "&>>|"
    | "&>>!" => true
    _ => false
  }
}

///|
fn redir_op_of(op : String) -> RedirOp {
  match op {
    "<" => RIn
    ">" => ROut
    ">>" => RAppend
    "<>" => RInOut
    "<&" => RDupIn
    ">&" => RDupOut
    "<<" => RHereDoc
    "<<-" => RHereDocStrip
    "<<<" => RHereString
    // Every clobber spelling zsh accepts, plus the `!` variants of the other
    // redirect forms, which all clobber the target the same way.
    ">|"
    | ">!"
    | ">>|"
    | ">>!"
    | ">&|"
    | ">&!"
    | ">>&|"
    | ">>&!"
    | "&>|"
    | "&>!"
    | "&>>|"
    | "&>>!" => RClobber
    "&>>" | ">>&" => RAppend
    "&>" => ROut
    _ => ROut
  }
}

///|
fn Parser::peek_is_redirect(self : Parser) -> Bool {
  match self.peek_tok() {
    TOp(op) => is_redirect_op(op)
    _ => false
  }
}

///|
/// bash keeps pending here-documents in a fixed stack and refuses the command
/// when a seventeenth is pushed on the same one: shell.h:172 has
/// `#define HEREDOC_MAX 16`, and y.tab.c:5467 reports "maximum here-document
/// count exceeded" and exits. Measured in bash 5.3: sixteen on one line parse,
/// seventeen do not, and a second line starts over because the stack is drained
/// when the command before it is gathered. zsh has no such limit (measured), so
/// this is bash-only, which is also why the message is not in zsh's evidence.
fn Parser::count_heredoc(self : Parser) -> Unit {
  if !(self.lex.dialect is Bash) {
    return
  }
  let line = self.lex.line
  if self.heredoc_line == line {
    self.heredoc_count = self.heredoc_count + 1
  } else {
    self.heredoc_line = line
    self.heredoc_count = 1
  }
  // Exactly once per line: bash exits at the first one, and repeating it for
  // every further here-document would only pad the issue list.
  if self.heredoc_count == 17 {
    self.lex.fail("maximum here-document count exceeded")
  }
}

///|
fn parse_fd(s : String) -> Int {
  let mut v = 0
  for c in s {
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  v
}

///|
/// Whether a word is the `{varname}` descriptor prefix bash and zsh accept
/// before a redirect: `{fd}<file`, `exec {fd}>out`. The descriptor number is
/// assigned at run time, so for an audit only the redirect's target matters.
fn is_named_fd(text : String) -> Bool {
  if text.length() < 3 || !text.has_prefix("{") || !text.has_suffix("}") {
    return false
  }
  is_valid_name(text.unsafe_substring(start=1, end=text.length() - 1))
}

///|
/// `2>&1` is a redirect on fd 2 only when the digit is glued to the operator;
/// `echo 2 > f` is just a word and a redirect on stdout.
fn Parser::fd_adjacent(self : Parser, w : Word) -> Bool {
  self.la_start == self.cur_start + w.raw.length()
}

///|
/// Whether a dup target names a descriptor rather than a file: `2`, `1-`, `-`.
fn is_fd_word(t : String) -> Bool {
  if t == "-" {
    return true
  }
  let trimmed = if t.has_suffix("-") {
    t.unsafe_substring(start=0, end=t.length() - 1)
  } else {
    t
  }
  trimmed.length() > 0 && all_digits(trimmed)
}
