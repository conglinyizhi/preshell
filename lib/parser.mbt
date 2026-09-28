///|
/// Where a sequence of commands stops. Reserved words stop it only at a
/// command boundary, which is what makes `if echo then; then :; fi` parse.
pub(all) struct Stop {
  words : Array[String]
  ops : Array[String]
}

///|
pub(all) struct Parser {
  lex : Lexer
  mut cur : Tok
  mut cur_start : Int
  mut la : Tok?
  mut la_start : Int
  /// How deep the nested-construct recursion currently is. Bounded, because an
  /// unbounded one is a crash: 40k nested `if` used to overflow the stack and
  /// take the process down with SIGSEGV. Real scripts nest a few dozen deep.
  mut depth : Int
  /// zsh lets an `if`/`while`/`until` condition be followed by a brace group
  /// instead of `then ... fi` / `do ... done`. The `{` only counts at a command
  /// position and only when no separator came first, so the condition list has
  /// to stop and hand it to the construct: if the sequence loop parses it as an
  /// ordinary command, the body is gone and the construct reads as unfinished.
  /// Only the condition call sites turn this on, and it stays on for everything
  /// the condition parses directly.
  mut brace_body : Bool
  /// Set by `parse_seq_in` when it stopped on such a brace, so the caller can
  /// tell a body from a stray `{` in a sequence that failed for another reason.
  mut brace_stop : Bool
  /// Whether the sequence being read may end at end of input without a
  /// complaint. zsh's SHORTLOOPS allows `while cond` with no body at all, and
  /// `while true; { : }` is that shape: the brace group joins the condition
  /// (a separator lets the list continue) and the loop keeps an empty body.
  mut eof_ok : Bool
  /// Line the pending here-document count belongs to, and how many were pushed
  /// on it. bash gathers them when the command ends, so the budget is per line.
  mut heredoc_line : Int
  mut heredoc_count : Int
}

///|
pub fn Parser::Parser(lex : Lexer) -> Parser {
  let cur = lex.next()
  {
    lex,
    cur,
    cur_start: lex.tok_start,
    la: None,
    la_start: 0,
    depth: 0,
    brace_body: false,
    brace_stop: false,
    eof_ok: false,
    heredoc_line: -1,
    heredoc_count: 0,
  }
}

///|
/// Parse a whole command line. Returns the tree plus any lexical complaints.
pub fn parse(src : String) -> (Seq, Array[String]) {
  parse_dialect(src, Bash)
}

///|
pub fn parse_dialect(src : String, dialect : Dialect) -> (Seq, Array[String]) {
  let lex = Lexer::with_dialect(src, dialect)
  let p = Parser::Parser(lex)
  let seq = p.parse_seq({ words: [], ops: [], })
  (seq, lex.errors)
}

///|
/// Same, plus the line each complaint came from: "which line is the problem"
/// is the first thing a caller asks about a parse failure.
pub fn parse_located(src : String) -> (Seq, Array[String], Array[Int]) {
  parse_located_dialect(src, Bash)
}

///|
/// Same, in a chosen dialect.
pub fn parse_located_dialect(
  src : String,
  dialect : Dialect,
) -> (Seq, Array[String], Array[Int]) {
  let lex = Lexer::with_dialect(src, dialect)
  let p = Parser::Parser(lex)
  let seq = p.parse_seq({ words: [], ops: [], })
  (seq, lex.errors, lex.error_lines)
}

///|
/// Parse inside `$( )`, `<()`, `>()`: everything up to the closing operator.
/// The operator itself is *already consumed* from the source by the tokenizer
/// that produced it, so the caller must not try to eat it again. The flag says
/// whether the close was actually found before the input ran out.
pub fn parse_sub_seq(lex : Lexer, op : String, label : String) -> (Seq, Bool) {
  let p = Parser::Parser(lex)
  let seq = p.parse_seq_in({ words: [], ops: [op], }, label)
  let closed = match p.cur {
    TOp(o) => o == op
    _ => false
  }
  (seq, closed)
}

///|
/// Parse a backquoted command, which ends at the end of its own little input.
pub fn parse_sub_seq_eof(lex : Lexer) -> Seq {
  let p = Parser::Parser(lex)
  p.parse_seq({ words: [], ops: [], })
}

///|
fn Parser::advance(self : Parser) -> Unit {
  match self.la {
    Some(t) => {
      self.cur = t
      self.cur_start = self.la_start
      self.la = None
    }
    None => {
      self.cur = self.lex.next()
      self.cur_start = self.lex.tok_start
    }
  }
}

///|
fn Parser::peek_tok(self : Parser) -> Tok {
  match self.la {
    Some(t) => t
    None => {
      let t = self.lex.next()
      self.la_start = self.lex.tok_start
      self.la = Some(t)
      t
    }
  }
}

///|
fn Parser::skip_newlines(self : Parser) -> Unit {
  for ;; {
    match self.cur {
      TNewline => self.advance()
      _ => break
    }
  }
}

///|
fn Parser::reserved(self : Parser) -> String? {
  match self.cur {
    TWord(w) => w.plain()
    _ => None
  }
}

///|
fn is_closer(op : String) -> Bool {
  match op {
    ")" | "))" | ";;" | ";&" | ";;&" => true
    _ => false
  }
}

///|
/// Does a command leave the parser at a command position? This is zsh's
/// `incmdpos`, and it is what tells `if [[ x ]] { : }` from `if true { : }`:
/// `[[ ]]`, `(( ))`, a subshell, a group and an assignment alone all end at a
/// command position, while a simple command's word does not (zsh's par_simple
/// clears the flag before it reads the next token).
fn cmd_ends_at_cmdpos(cmd : Cmd) -> Bool {
  match cmd {
    Simple(s) => s.words.length() == 0
    _ => true
  }
}

///|
fn pipeline_ends_at_cmdpos(p : Pipeline) -> Bool {
  match p.cmds {
    [] => false
    cmds => cmd_ends_at_cmdpos(cmds[cmds.length() - 1])
  }
}

///|
fn Parser::at_stop(self : Parser, stop : Stop) -> Bool {
  match self.cur {
    TEof => true
    TNewline => false
    TOp(op) => stop.ops.contains(op) || is_closer(op)
    TWord(w) =>
      match w.plain() {
        Some(s) => stop.words.contains(s)
        None => false
      }
  }
}

///|
pub fn Parser::parse_seq(self : Parser, stop : Stop) -> Seq {
  self.parse_seq_in(stop, "")
}

///|
/// Same, but names the construct for the error message. A sequence that is
/// waiting for a closer (`)`, `}`, `fi`, `done`, `esac`) and meets end of input
/// instead is unfinished, and bash rejects it: accepting it silently is how
/// `(echo a` used to come back as Complete.
pub fn Parser::parse_seq_in(self : Parser, stop : Stop, label : String) -> Seq {
  let started_at = self.lex.line
  let items : Array[AndOr] = []
  // One-shot, unlike `brace_body`: a nested construct inside a loop condition
  // still has to report its own unterminated input.
  let eof_ok = self.eof_ok
  self.eof_ok = false
  let mut stopped_at_brace = false
  for ;; {
    self.skip_newlines()
    if self.at_stop(stop) {
      break
    }
    let before = self.lex.pos
    let pipeline = self.parse_pipeline()
    match self.parse_separator() {
      Some(op) => items.push({ pipeline, op, })
      None => {
        items.push({ pipeline, op: Semi, })
        if self.cur is TEof {
          break
        }
        if self.brace_body &&
          self.at_body_brace() &&
          pipeline_ends_at_cmdpos(pipeline) {
          // The condition ends here and the `{` belongs to the construct.
          stopped_at_brace = true
          break
        }
        if !self.stop_matches(stop) {
          // A command list needs a separator. Treating "none" as one is how
          // `printf x a=(a b)` used to become `printf` followed by a subshell.
          // bash rejects the same input, but this stays a Gap until the
          // corpus shows the two agree (see lib/status.mbt).
          self.lex.fail("unexpected token after command")
          self.advance()
        }
        break
      }
    }
    if self.lex.pos == before {
      // No input consumed: refuse to spin on a malformed line.
      self.advance()
    }
  }
  if !eof_ok &&
    (stop.ops.length() > 0 || stop.words.length() > 0) &&
    self.cur is TEof {
    let what = if label == "" { "construct" } else { label }
    // Point at where the construct opened: end of input is where the parser
    // noticed, not where the problem is.
    self.lex.fail_at("unexpected end of input in " + what, started_at)
  }
  self.eof_ok = eof_ok
  self.brace_stop = stopped_at_brace
  { items, }
}

///|

///|
/// Consume a list separator. `None` means nothing was consumed, which is not
/// the same as `;`.
fn Parser::parse_separator(self : Parser) -> BinOp? {
  match self.cur {
    TOp("&&") => {
      self.advance()
      self.check_operator_sequence("&&")
      Some(And)
    }
    TOp("||") => {
      self.advance()
      self.check_operator_sequence("||")
      Some(Or)
    }
    TOp("&") => {
      self.advance()
      self.check_operator_sequence("&")
      Some(Amp)
    }
    TOp(";") => {
      self.advance()
      self.check_operator_sequence(";")
      Some(Semi)
    }
    TNewline => {
      self.advance()
      Some(Semi)
    }
    _ => None
  }
}

///|
/// Does the current token end this sequence? Membership only: `at_stop` also
/// accepts any stray closing token so that parsing cannot spin, but a closer
/// this context never asked for is an error, not a boundary.
fn Parser::stop_matches(self : Parser, stop : Stop) -> Bool {
  match self.cur {
    TOp(op) => stop.ops.contains(op)
    TWord(w) =>
      match w.plain() {
        Some(s) => stop.words.contains(s)
        None => false
      }
    _ => false
  }
}

///|
fn Parser::parse_pipeline(self : Parser) -> Pipeline {
  self.skip_newlines()
  let mut negated = false
  if self.reserved() == Some("!") {
    negated = true
    self.advance()
    self.skip_newlines()
  }
  let cmds : Array[Cmd] = [self.parse_command()]
  for ;; {
    match self.cur {
      TOp("|") | TOp("|&") => {
        self.advance()
        self.check_operator_sequence("|")
        self.skip_newlines()
        cmds.push(self.parse_command())
      }
      _ => break
    }
  }
  { negated, cmds, }
}

///|
fn empty_word(line : Int) -> Word {
  { parts: [], raw: "", line, origin: None, }
}

///|
/// Any compound command may be followed by its own redirections; the simple
/// command case handles its redirects inline instead.

///|
/// Recursion ceiling for nested constructs. Measured: 1000 levels of nested
/// `if` parse fine and 40k crash the native stack, so this sits far from both
/// ends. Exceeding it is reported as an issue, never as a crash.

///|
/// Wrap a single command as a sequence, for the `always cmd` short form.
fn parse_seq_of_cmd(p : Parser) -> Seq {
  let cmd = p.parse_command()
  { items: [{ pipeline: { negated: false, cmds: [cmd], }, op: Semi, }], }
}

///|
/// Any compound command may be followed by its own redirections; the simple
/// command case handles its redirects inline instead.
fn Parser::parse_command(self : Parser) -> Cmd {
  if self.depth >= max_nesting() {
    self.lex.fail("input nested too deeply")
    return Cmd::Simple({ assigns: [], words: [], redirects: [], })
  }
  self.depth += 1
  let base = self.parse_command_base()
  let result = match base {
    Cmd::Simple(_) => base
    _ => {
      let redirects = self.parse_redirect_list()
      if redirects.length() == 0 {
        base
      } else {
        Cmd::Redirected(inner=base, redirects~)
      }
    }
  }
  self.depth -= 1
  result
}

///|
/// A token-stream position, so a speculative skip can be undone. The `for` loop
/// needs one: it may skip separators before a body, but a csh-style loop such
/// as `foreach x (a b); body; end` has no body of its own, and eating the `;`
/// then leaves the caller without the separator it needs.
priv struct Mark {
  pos : Int
  cur : Tok
  cur_start : Int
  la : Tok?
  la_start : Int
}

///|
fn Parser::mark(self : Parser) -> Mark {
  {
    pos: self.lex.pos,
    cur: self.cur,
    cur_start: self.cur_start,
    la: self.la,
    la_start: self.la_start,
  }
}

///|
fn Parser::restore(self : Parser, m : Mark) -> Unit {
  self.lex.pos = m.pos
  self.cur = m.cur
  self.cur_start = m.cur_start
  self.la = m.la
  self.la_start = m.la_start
}

///|
/// `NAME=value` and `NAME+=value` are assignments only at the head of a
/// simple command; `echo a=1` is just two words.
