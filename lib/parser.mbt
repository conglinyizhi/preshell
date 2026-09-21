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
///
/// Is the current token the `{` that opens a group? In zsh a lone `{` at a
/// command position is the reserved word `{`, and it is the only spelling a
/// brace body has.
fn Parser::at_body_brace(self : Parser) -> Bool {
  match self.cur {
    TWord(w) => w.plain() == Some("{")
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
/// Read an `if`/`while`/`until` condition with that rule switched on. `eof_ok`
/// says the condition is allowed to run out of input, which zsh permits for a
/// loop (SHORTLOOPS) and not for an `if`.
fn Parser::parse_cond_seq(
  self : Parser,
  stop : Stop,
  label : String,
  eof_ok : Bool,
) -> Seq {
  let saved_body = self.brace_body
  let saved_eof = self.eof_ok
  self.brace_body = true
  self.eof_ok = eof_ok
  let seq = self.parse_seq_in(stop, label)
  self.brace_body = saved_body
  self.eof_ok = saved_eof
  seq
}

///|
/// Consume a `{ ... }` body, the zsh spelling that replaces `then ... fi` and
/// `do ... done`. The caller has already checked that the brace is there.
fn Parser::parse_brace_body(self : Parser, label : String) -> Seq {
  self.advance()
  let body = self.parse_seq_in({ words: ["}"], ops: [], }, label)
  if self.reserved() == Some("}") {
    self.advance()
  }
  body
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
      self.check_operator_sequence()
      Some(And)
    }
    TOp("||") => {
      self.advance()
      self.check_operator_sequence()
      Some(Or)
    }
    TOp("&") => {
      self.advance()
      self.check_operator_sequence()
      Some(Amp)
    }
    TOp(";") => {
      self.advance()
      self.check_operator_sequence()
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
        self.check_operator_sequence()
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
  { parts: [], raw: "", line, }
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
fn max_nesting() -> Int {
  1024
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
fn Parser::parse_command_base(self : Parser) -> Cmd {
  self.skip_newlines()
  match self.cur {
    TOp("(") =>
      // `((` is an arithmetic command only when the two parens are glued
      // together; `( (` is a subshell inside a subshell. The lexer no longer
      // merges them, because merging everywhere broke nested command
      // substitutions (`arr=($(echo a))`).
      // An adjacent pair is arithmetic only if the text between the parens is
      // followed by another paren; otherwise it is a subshell inside a
      // subshell, which is what zdiff relies on.
      if self.lex.dialect is Zsh && self.next_is_adjacent(")") {
        // zsh's anonymous function: `()` glued together, then a command, then
        // the arguments it is called with. `( )` with a space inside is an
        // empty subshell instead, and the word after it is a syntax error,
        // so the adjacency is what tells the two apart.
        self.advance()
        self.advance()
        self.parse_anon_func(self.parse_command())
      } else if self.next_is_adjacent("(") &&
        self.lex.is_arith_at(self.cur_start) {
        let start = self.cur_start + 2
        // Inside the arithmetic a `#` is an operand (zsh reads `#x` as a
        // character code), not the start of a comment: measured, both shells
        // accept `(( 1 + 2 # c ))`.
        self.lex.in_arith = true
        self.advance()
        self.advance()
        let mut closed = false
        // Balance every paren: the expression has its own, so `(((4+4)))`
        // closes at the last one, not at the first `))`-looking pair.
        let mut depth = 2
        // End of the last token that belongs to the expression, for the raw
        // text handed to the caller. Closers do not move it.
        let mut raw_end = start
        for ;; {
          match self.cur {
            TEof => break
            TOp("(") => {
              depth += 1
              raw_end = self.lex.pos
              self.advance()
            }
            TOp(")") => {
              depth -= 1
              if depth == 0 {
                closed = true
                break
              }
              self.advance()
            }
            _ => {
              raw_end = self.lex.pos
              self.advance()
            }
          }
        }
        let raw = self.lex.slice(start, raw_end)
        self.lex.in_arith = false
        if closed {
          self.advance()
        } else {
          // An unclosed `((` is a command that never finishes; accepting it
          // silently reads as "nothing happens here".
          self.lex.fail("unexpected end of input in arithmetic")
        }
        Cmd::Arith(raw)
      } else {
        self.advance()
        let body = self.parse_seq_in({ words: [], ops: [")"], }, "subshell")
        if self.cur is TOp(")") {
          self.advance()
        }
        Cmd::Subshell(body)
      }
    TWord(w) =>
      match w.plain() {
        Some("if") => self.parse_if()
        // zsh's `repeat N { body }` and `repeat N do ... done`. The count is a
        // word like any other and is carried as the loop's word list: what
        // matters for an audit is that the body runs.
        Some("repeat") if self.lex.dialect is Zsh => self.parse_repeat()
        Some("while") => self.parse_loop(false)
        Some("until") => self.parse_loop(true)
        Some("for") => self.parse_for()
        Some("select") => self.parse_for()
        // zsh's csh-style spelling of the same loop.
        Some("foreach") if self.lex.dialect is Zsh =>
          self.parse_for(foreach=true)
        Some("case") => self.parse_case()
        Some("function") => self.parse_function_kw()
        Some(kw) if is_stray_keyword(kw, self.lex.dialect) => {
          // These words only continue or close a construct. With nothing open
          // they are errors in both shells, so accepting them turned
          // `do :; done` into a command that cannot run.
          self.lex.fail("unexpected keyword " + kw)
          self.advance()
          Cmd::Simple({ assigns: [], words: [], redirects: [], })
        }
        Some("time") => {
          self.advance()
          self.parse_command()
        }
        Some("coproc") => {
          self.advance()
          // `coproc [NAME] compound-command`: the name is optional and what
          // follows it is the body, so `coproc r { :; }` defines a coprocess
          // rather than running a command named `r` with a brace for an
          // argument. Reading it the second way used to pass the corpus with a
          // tree that was simply wrong.
          match self.cur {
            TWord(w) =>
              if w.plain() != None && self.next_is_group_body() {
                self.advance()
              }
            _ => ()
          }
          self.parse_command()
        }
        Some("{") => {
          self.advance()
          let body = self.parse_seq_in({ words: ["}"], ops: [], }, "group")
          if self.reserved() == Some("}") {
            self.advance()
          }
          // zsh's try/finally: `{ ... } always { ... }`. The second block runs
          // whether or not the first one succeeded, so both contribute effects
          // and the AST keeps them apart.
          // `always` is zsh's try/finally. bash has no such word, so reading
          // it there would be a claim the shell does not back up.
          if self.lex.dialect is Zsh && self.reserved() == Some("always") {
            self.advance()
            if self.reserved() == Some("{") {
              self.advance()
              let fin = self.parse_seq_in({ words: ["}"], ops: [], }, "always")
              if self.reserved() == Some("}") {
                self.advance()
              }
              Cmd::Always(inner=body, always=fin)
            } else {
              // `{ ... } always cmd` is also legal zsh
              let fin = parse_seq_of_cmd(self)
              Cmd::Always(inner=body, always=fin)
            }
          } else {
            Cmd::Group(body)
          }
        }
        Some("[[") => self.parse_cond()
        _ => self.parse_simple_or_funcdef(w)
      }
    TOp(op) if is_redirect_op(op) =>
      // Redirections may precede the command word: `< /dev/null foo bar`.
      self.parse_simple()
    _ => {
      // A command position holding nothing: `!;`, `!& echo`. The separator
      // belongs to the caller, so do not eat it here.
      let empty = Cmd::Simple({ assigns: [], words: [], redirects: [], })
      match self.cur {
        TEof | TNewline => empty
        TOp(op) =>
          if is_closer(op) ||
            op == ";" ||
            op == "&" ||
            op == "&&" ||
            op == "||" ||
            op == "|" ||
            op == "|&" {
            empty
          } else {
            self.advance()
            empty
          }
        _ => {
          self.advance()
          empty
        }
      }
    }
  }
}

///|
fn Parser::parse_cond(self : Parser) -> Cmd {
  let start = self.cur_start + 2
  self.advance()
  // A command substitution inside the brackets is a command that runs, so it
  // is collected here even though the condition text itself is opaque.
  let subs : Array[Seq] = []
  for ;; {
    match self.cur {
      TEof => break
      TWord(w) =>
        if w.plain() == Some("]]") {
          break
        } else {
          for s in w.subcommands() {
            subs.push(s)
          }
          self.advance()
        }
      _ => self.advance()
    }
  }
  let raw = self.lex.slice(start, self.cur_start)
  if self.reserved() == Some("]]") {
    // zsh's parser is at a command position again once the brackets close
    // (par_dinbrack sets incmdpos), so `if [[ x ]] { : }` has a brace body.
    // Setting it before the next token is read is what makes `[[ x ]] {}`
    // read as the empty group rather than as one word.
    self.lex.cmd_pos = true
    self.advance()
  } else {
    self.lex.fail("unexpected end of input in [[ ]]")
  }
  Cmd::Cond(raw~, subs~)
}

///|
fn Parser::parse_if(self : Parser) -> Cmd {
  self.advance()
  let cond = self.parse_cond_seq({ words: ["then"], ops: [], }, "if", false)
  // zsh: `if cond { body }` -- a brace group in place of `then ... fi`, and
  // then `fi` is not needed either. Measured: `if [[ x ]] { : }` parses and
  // `if true { : }` is a syntax error, because a plain word leaves the parser
  // outside a command position.
  let mut usebrace = self.brace_stop && self.at_body_brace()
  if self.reserved() == Some("then") {
    self.advance()
  } else if !usebrace {
    // Measured: `if true` and `if true; then :` without `fi` are refused by
    // both shells, and neither accepts a missing `then`.
    self.lex.fail("expected then after the if condition")
  }
  let then_ = if usebrace {
    self.parse_brace_body("if")
  } else {
    self.parse_seq_in({ words: ["elif", "else", "fi"], ops: [], }, "if")
  }
  let elifs : Array[(Seq, Seq)] = []
  for ;; {
    if self.reserved() == Some("elif") {
      self.advance()
      let c = self.parse_cond_seq({ words: ["then"], ops: [], }, "if", false)
      let elif_brace = self.brace_stop && self.at_body_brace()
      if self.reserved() == Some("then") {
        self.advance()
      }
      let b = if elif_brace {
        self.parse_brace_body("if")
      } else {
        self.parse_seq_in({ words: ["elif", "else", "fi"], ops: [], }, "if")
      }
      if elif_brace {
        // zsh keeps one `usebrace` flag for the whole chain: a brace body
        // anywhere in it means the `else` may take one too.
        usebrace = true
      }
      elifs.push((c, b))
    } else {
      break
    }
  }
  let else_ = if self.reserved() == Some("else") {
    self.advance()
    if usebrace && self.at_body_brace() {
      // zsh: when the `if` itself took a brace body, `else` may take one too,
      // and then there is no `fi` to close either of them.
      Some(self.parse_brace_body("if"))
    } else {
      Some(self.parse_seq_in({ words: ["fi"], ops: [], }, "if"))
    }
  } else {
    None
  }
  if self.reserved() == Some("fi") {
    self.advance()
  }
  Cmd::If(cond~, then_~, elifs~, else_~)
}

///|
fn Parser::parse_repeat(self : Parser) -> Cmd {
  self.advance()
  let count = match self.cur {
    TWord(w) => {
      self.advance()
      w
    }
    _ => empty_word(self.lex.line)
  }
  // zsh's par_repeat skips separators after the count (`while (tok == SEPER)`),
  // so `repeat 2; do ... done` and `repeat 2 { ... }` are both fine. Without
  // this the body was left as separate commands and `repeat 2; do rm -rf x;
  // done` reported two fake Execs and no Delete at all.
  for ;; {
    if self.cur is TNewline || self.cur is TOp(";") {
      self.advance()
    } else {
      break
    }
  }
  let body = if self.reserved() == Some("do") {
    self.advance()
    let b = self.parse_seq_in({ words: ["done"], ops: [], }, "loop")
    if self.reserved() == Some("done") {
      self.advance()
    }
    b
  } else if self.reserved() == Some("{") {
    self.advance()
    let b = self.parse_seq_in({ words: ["}"], ops: [], }, "loop")
    if self.reserved() == Some("}") {
      self.advance()
    }
    b
  } else {
    Seq::empty()
  }
  Cmd::For(name="", words=[count], body~)
}

///|
fn Parser::parse_loop(self : Parser, until : Bool) -> Cmd {
  self.advance()
  let cond = self.parse_cond_seq({ words: ["do"], ops: [], }, "loop", true)
  let brace_body_here = self.brace_stop && self.at_body_brace()
  let body = if self.reserved() == Some("do") {
    self.advance()
    let b = self.parse_seq_in({ words: ["done"], ops: [], }, "loop")
    if self.reserved() == Some("done") {
      self.advance()
    }
    b
  } else if brace_body_here {
    self.parse_brace_body("loop")
  } else if self.cur is TEof {
    // zsh's SHORTLOOPS: with no `do ... done` the loop body is the empty
    // list, which is what `while true; { : }` is -- there the brace group
    // joins the condition instead (a separator lets the list continue), and
    // the loop itself keeps the empty body. Refusing this used to report the
    // whole input as unfinished.
    //
    // Measured: bash refuses a loop with no body at all (`while true`,
    // `while read x`), so that part is zsh-only.
    if self.lex.dialect is Bash {
      self.lex.fail("expected do...done after while")
    }
    Seq::empty()
  } else {
    let b = self.parse_seq_in({ words: ["done"], ops: [], }, "loop")
    if self.reserved() == Some("done") {
      self.advance()
    }
    b
  }
  Cmd::Loop(until~, cond~, body~)
}

///|
fn Parser::parse_for(self : Parser, foreach? : Bool = false) -> Cmd {
  self.advance()
  let mut name = ""
  match self.cur {
    TWord(w) =>
      match w.plain() {
        Some(s) => {
          name = s
          // zsh's csh form is `for x ( a b ) body`: those parens belong to the
          // word list. Set before advancing, since advancing is what reads the
          // `(` token.
          if self.lex.dialect is Zsh {
            self.lex.in_for_words = true
          }
          self.advance()
        }
        None => self.advance()
      }
    _ => ()
  }
  // zsh takes more than one loop name: `for a b in x y` splits the list two at
  // a time, and `for a b` splits "$@" that way. bash refuses both, so this is
  // the zsh dialect only (measured against both shells).
  if self.lex.dialect is Zsh {
    for ;; {
      match self.cur {
        TWord(w) =>
          match w.plain() {
            Some(s) =>
              if s.length() > 0 && !is_command_word(s) {
                self.advance()
              } else {
                break
              }
            None => break
          }
        _ => break
      }
    }
  }
  let words : Array[Word] = []
  // Whether the loop named an explicit word list (`in ...` or `( ... )`). That
  // is what decides the body-less case at the end: `for i in a` cannot run in
  // either shell, while `for i` is a valid zsh loop over `$@` that does
  // nothing, and bash refuses even that.
  let mut had_words = false
  // `for x` and its `in` may sit on different lines: measured, bash and zsh
  // both accept `for x\nin x\ndo ... done`.
  self.skip_newlines()
  if self.cur is TOp("(") && self.next_is_adjacent("(") {
    // `for ((...))` requires arithmetic: bash errors out here instead of
    // falling back to subshells (parse.y:parse_dparen, the FOR case).
    if !self.lex.is_arith_at(self.cur_start) {
      self.lex.fail("expected an arithmetic expression after for ((")
    }
    // for ((init; cond; step)) -- the condition may itself contain parens
    // Inside the arithmetic a `#` is an operand and every `(` is an operator,
    // same as the `(( ))` command form.
    self.lex.in_arith = true
    self.advance()
    self.advance()
    let mut depth = 2
    for ;; {
      match self.cur {
        TEof => break
        TOp("(") => {
          depth += 1
          self.advance()
        }
        TOp(")") => {
          depth -= 1
          if depth == 0 {
            break
          }
          self.advance()
        }
        _ => self.advance()
      }
    }
    if self.cur is TOp(")") {
      self.advance()
    }
    self.lex.in_arith = false
  } else {
    if self.lex.dialect is Zsh && self.cur is TOp("(") {
      // `for x ( a b )`: the parens belong to the word list.
      had_words = true
      self.advance()
      for ;; {
        match self.cur {
          TWord(w) => {
            words.push(w)
            self.advance()
          }
          TOp(")") => {
            self.advance()
            break
          }
          TEof => break
          _ => self.advance()
        }
      }
    } else if self.reserved() == Some("in") {
      had_words = true
      self.advance()
      for ;; {
        match self.cur {
          TWord(w) => {
            // zsh's `}` is a reserved word wherever it stands, so it ends the
            // word list instead of becoming one of its words. What follows then
            // has to be a separator, which is why `for i in a { : }` is a
            // syntax error there rather than a loop with an empty body. In
            // bash a `}` here is just a word, so this stays zsh-only.
            if self.lex.dialect is Zsh && w.plain() == Some("}") {
              break
            }
            words.push(w)
            self.advance()
          }
          _ => break
        }
      }
      if self.lex.dialect is Zsh && self.reserved() == Some("}") {
        self.lex.fail("unexpected token in for word list")
      }
    }
    if self.cur is TOp(";") {
      self.advance()
    }
  }
  self.lex.in_for_words = false
  // Both `for x in ...` and `for ((...))` may be followed by a separator
  // before the body. Without this the arithmetic form left `do ... done` as
  // separate commands: the body ran nowhere and `do` even errored. The skip is
  // speculative, because a csh-style loop may have no body of its own.
  let before_seps = self.mark()
  for ;; {
    if self.cur is TNewline || self.cur is TOp(";") {
      self.advance()
    } else {
      break
    }
  }
  if !foreach &&
    !(self.reserved() == Some("do") || self.reserved() == Some("{")) {
    // No body after all: the separators belong to whoever called us.
    self.restore(before_seps)
  }
  let body = if self.reserved() == Some("do") {
    self.advance()
    let b = self.parse_seq_in({ words: ["done"], ops: [], }, "loop")
    if self.reserved() == Some("done") {
      self.advance()
    }
    b
  } else if self.reserved() == Some("{") {
    self.advance()
    let b = self.parse_seq_in({ words: ["}"], ops: [], }, "loop")
    if self.reserved() == Some("}") {
      self.advance()
    }
    b
  } else if foreach {
    // `foreach x ( a b ) body end`: the body is a plain command list closed by
    // `end`. Measured: `for x (a b) :; end` is refused by zsh, so `end` only
    // closes the csh spelling.
    let b = self.parse_seq_in({ words: ["end"], ops: [], }, "loop")
    if self.reserved() == Some("end") {
      self.advance()
    }
    b
  } else {
    // A `for` that named a word list has to say what to do with it: measured,
    // both shells refuse `for i in a` and `for i in`. Without a word list the
    // shells disagree, so that case is split by dialect.
    if !(self.lex.dialect is Zsh && !had_words) {
      self.lex.fail("expected do...done after for")
    }
    Seq::empty()
  }
  Cmd::For(name~, words~, body~)
}

///|
/// Skip the separators zsh allows between a `case` subject and its `in`.
fn Parser::skip_case_separators(self : Parser) -> Unit {
  for ;; {
    match self.cur {
      TNewline | TOp(";") => self.advance()
      _ => break
    }
  }
}

///|
fn Parser::parse_case(self : Parser) -> Cmd {
  self.advance()
  // zsh takes the subject in parentheses: measured, `case (x) in a) : ;; esac`
  // runs there and is a syntax error in bash.
  let paren_subject = self.lex.dialect is Zsh && self.cur is TOp("(")
  if paren_subject {
    self.advance()
  }
  let subject = match self.cur {
    TWord(w) => {
      self.advance()
      w
    }
    _ => empty_word(self.lex.line)
  }
  if paren_subject && self.cur is TOp(")") {
    self.advance()
  }
  // Between the subject and `in` zsh's parser eats any run of `;` and
  // newlines (`case x; in a) : ;; esac` is legal there). bash accepts newlines
  // only: measured, `bash -n -c 'case x; in a) : ;; esac'` is a syntax error
  // while zsh runs it, so the `;` spelling stays a zsh-only shape.
  if self.lex.dialect is Zsh {
    self.skip_case_separators()
  } else {
    self.skip_newlines()
  }
  if self.reserved() == Some("in") {
    // From here the patterns are words: zsh reads `(net|open)bsd*)` as one
    // pattern with a glob group in it, not as the pattern list's own paren
    // followed by two alternatives.
    self.lex.in_casepat = true
    self.advance()
  } else {
    // Measured: `case $x` and `case $x in` are refused by both shells, so a
    // `case` without its subject or without `in` cannot be reported as a
    // command that runs.
    self.lex.fail("expected in after the case subject")
  }
  let items : Array[CaseItem] = []
  for ;; {
    self.skip_newlines()
    if self.reserved() == Some("esac") {
      self.lex.in_casepat = false
      self.advance()
      break
    }
    if self.cur is TEof {
      self.lex.in_casepat = false
      // Measured: `case $x in` with no `esac` is refused by both shells.
      self.lex.fail("expected esac to close the case")
      break
    }
    let before = self.lex.pos
    if self.cur is TOp("(") {
      self.advance()
    }
    let patterns : Array[Word] = []
    for ;; {
      match self.cur {
        TWord(w) => {
          patterns.push(w)
          self.advance()
        }
        _ => break
      }
      if self.cur is TOp("|") {
        self.advance()
      } else {
        break
      }
    }
    // The body is a command list again, so a `(` there is a subshell.
    self.lex.in_casepat = false
    if self.cur is TOp(")") {
      self.advance()
    }
    let body = self.parse_seq_in(
      { words: ["esac"], ops: [";;", ";&", ";;&", ";|"], },
      "case",
    )
    let mut ft = 0
    // Whatever comes after the terminator is the next pattern list.
    self.lex.in_casepat = true
    match self.cur {
      TOp(";;") => {
        ft = 0
        self.advance()
      }
      TOp(";&") => {
        ft = 1
        self.advance()
      }
      TOp(";;&") | TOp(";|") => {
        // Both mean "keep testing the following patterns". bash spells it
        // `;;&`, zsh `;|`; the lexer only ever produces one of them per dialect.
        ft = 2
        self.advance()
      }
      _ => ()
    }
    items.push({ patterns, body, fallthrough: ft, })
    if self.lex.pos == before {
      self.advance()
    }
  }
  Cmd::Case(subject~, items~)
}

///|
fn Parser::parse_function_kw(self : Parser) -> Cmd {
  self.advance()
  // zsh's anonymous function in its `function` spelling. Measured with zsh
  // 5.9: `function { echo $1 } extra` prints `extra`, and `function () { : }`
  // does the same, so both open a body that runs right there with the words
  // after it as arguments -- the same construct as `() { body }`. A *named*
  // definition takes no argument list: `function foo { : } extra` is a parse
  // error in zsh.
  if self.lex.dialect is Zsh && self.at_body_brace() {
    return self.parse_anon_func(self.parse_command())
  }
  if self.lex.dialect is Zsh &&
    self.cur is TOp("(") &&
    self.next_is_adjacent(")") {
    // `function ()`: the parens carry no name, so they are the anonymous
    // marker rather than part of a definition.
    self.advance()
    self.advance()
    return self.parse_anon_func(self.parse_command())
  }
  let name = match self.cur {
    TWord(w) => {
      self.advance()
      w.plain().unwrap_or("")
    }
    _ => ""
  }
  if self.cur is TOp("(") {
    self.advance()
    if self.cur is TOp(")") {
      self.advance()
    }
  }
  let body = self.parse_command()
  // bash refuses a body-less `function g` (measured: `bash -n -c 'function g'`
  // is a syntax error) while zsh takes it as a definition with an empty body.
  if self.lex.dialect is Bash && is_empty_command(body) {
    self.lex.fail("expected a body after the function definition")
  }
  Cmd::FuncDef(name~, body~, keyword=true)
}

///|
/// The tail of zsh's anonymous function: the words it is called with, then its
/// own redirections. Shared by `() { body } args` and `function { body } args`.
fn Parser::parse_anon_func(self : Parser, body : Cmd) -> Cmd {
  let args : Array[Word] = []
  let redirects : Array[Redirect] = []
  for ;; {
    match self.cur {
      TWord(w) =>
        // zsh reads a lone `}` as the closing reserved word wherever it
        // stands, so it ends the argument list instead of becoming one:
        // `function { : } { echo y }` and `() { : } }` are parse errors
        // there, and taking the `}` as an argument made us accept them.
        if w.plain() == Some("}") {
          break
        } else {
          args.push(w)
          self.advance()
        }
      TOp(op) =>
        if is_redirect_op(op) {
          redirects.push(self.parse_redirect(None))
        } else {
          break
        }
      _ => break
    }
  }
  if is_empty_command(body) && args.length() == 0 && redirects.length() == 0 {
    // `()` with nothing after it: zsh refuses this too.
    self.lex.fail("expected a command after the anonymous function")
  }
  Cmd::AnonFunc(body~, args~, redirects~)
}

///|
fn Parser::parse_simple_or_funcdef(self : Parser, w : Word) -> Cmd {
  // `name()` is a function definition; `name=(...)` is an array assignment,
  // and bash happily accepts function names that are not identifiers (`:`).
  // The name does not have to be a plain word either: measured, all three
  // shells take `<(:) () { ... }` as a definition of a function whose name
  // happens to be a process substitution. Requiring `plain()` here skipped
  // that branch and left the construct unparsed (func5 in the bash corpus).
  let is_assign = match split_assignment(w) {
    Some(_) => true
    None => false
  }
  let name = w.literal_text()
  // A lone `}` is a reserved word in bash only where a command could start:
  // `echo }` runs (measured) while `{ echo a; } }` does not. zsh treats it as
  // reserved everywhere, which the word reader already handles.
  if self.lex.dialect is Bash && name == "}" {
    self.lex.fail("unexpected token after command")
    self.advance()
    return Cmd::Simple({ assigns: [], words: [], redirects: [], })
  }
  if !is_assign && name != "" {
    match self.peek_tok() {
      TOp("(") => {
        self.advance()
        self.advance()
        if self.cur is TOp(")") {
          self.advance()
          return Cmd::FuncDef(name~, body=self.parse_command(), keyword=false)
        }
        self.lex.fail("expected ) in function definition")
        return Cmd::FuncDef(
          name~,
          body=Cmd::Simple({ assigns: [], words: [], redirects: [], }),
          keyword=false,
        )
      }
      _ => ()
    }
  }
  self.parse_simple()
}

///|
/// Declaration builtins take assignment statements as arguments, so `name=(...)`
/// is valid inside their argument list and not only at the head of a command.
///
/// bash's rule is in parse.y:5798-5810: when the command word is a builtin
/// flagged ASSIGNMENT_BUILTIN, or the word is `eval`/`let`, the parser sets
/// PST_ASSIGNOK and `name=` becomes an assignment word again. The list below
/// was checked against `bash -n`: declare/typeset/local/export/readonly/eval/
/// let/alias accept it, while printf/echo/unset reject it (and so do
/// `command declare ...` / `builtin declare ...`).
fn takes_assignments(name : String) -> Bool {
  match name {
    "declare"
    | "typeset"
    | "local"
    | "export"
    | "readonly"
    | "eval"
    | "let"
    | "alias" => true
    _ => false
  }
}

///|
/// Is `name=value` still an assignment at this point in the command?
fn assign_ok(words : Array[Word]) -> Bool {
  match words {
    [] => true
    [first, ..] =>
      match first.plain() {
        Some(n) => takes_assignments(n)
        None => false
      }
  }
}

///|
fn all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if !c.is_ascii_digit() {
      return false
    }
  }
  true
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
/// Whether an operator is one of the connectors between commands rather than
/// a redirection. A redirection after a connector is fine (`cmd && > f` runs a
/// redirect-only command); two connectors in a row are not.
fn is_control_operator(op : String) -> Bool {
  match op {
    "&&" | "||" | "|" | "|&" | "&" | ";" | ";;" | ";&" | ";;&" | ";|" => true
    _ => false
  }
}

///|
/// A connector has to be followed by a command. Measured: both shells refuse
/// `cmd &&& x`, `cmd ||| x`, `cmd && || x`, `cmd | | x` and `cmd & & x`.
/// zsh is the lenient one here: it takes `cmd && ; x` and `cmd ; ; x`, so an
/// empty command between separators is allowed there and nowhere else.
fn Parser::check_operator_sequence(self : Parser) -> Unit {
  if self.cur is TNewline || self.cur is TEof {
    return
  }
  match self.cur {
    TOp(op) =>
      if is_control_operator(op) && !(self.lex.dialect is Zsh && op == ";") {
        self.lex.fail("unexpected operator after operator")
      }
    _ => ()
  }
}

///|
/// Whether the token after the current one opens a `{ ... }` group.
fn Parser::next_is_group_body(self : Parser) -> Bool {
  match self.peek_tok() {
    TWord(w) => w.plain() == Some("{")
    _ => false
  }
}

///|
/// Words that only continue or close a construct. With nothing open they are
/// errors in both shells, so they must not be read as commands. bash also
/// refuses `in` while zsh runs a command by that name (measured); inside
/// `for` and `case` these words never reach the dispatcher.
fn is_stray_keyword(kw : String, dialect : Dialect) -> Bool {
  match kw {
    "do" | "done" | "then" | "fi" | "elif" | "else" | "esac" => true
    "in" => dialect is Bash
    _ => false
  }
}

///|
/// A token-stream position, so a speculative skip can be undone. The `for` loop
/// needs one: it may skip separators before a body, but a csh-style loop such
/// as `foreach x (a b); body; end` has no body of its own, and eating the `;`
/// then leaves the caller without the separator it needs.
struct Mark {
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
/// Whether a command carries nothing at all: `()`, or an empty `;`.
fn is_empty_command(c : Cmd) -> Bool {
  match c {
    Simple(s) =>
      s.assigns.length() == 0 &&
      s.words.length() == 0 &&
      s.redirects.length() == 0
    _ => false
  }
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
    ">>" | "&>>" | ">>&" => RAppend
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
fn is_valid_name(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i, c in s {
    if i == 0 {
      if !is_name_start(c) {
        return false
      }
    } else if !is_name_char(c) {
      return false
    }
  }
  true
}

///|
/// `NAME=value` and `NAME+=value` are assignments only at the head of a
/// simple command; `echo a=1` is just two words.

///|
/// `NAME=value`, `NAME+=value`, `NAME[subscript]=value`: all three are
/// assignment words in bash, and the subscript form is where `a[$i]=x` hides a
/// hole in the *target* rather than the value.
pub fn split_assignment(
  w : Word,
) -> (String, Bool, Array[WordPart], Array[WordPart])? {
  match w.parts {
    [Lit(first), .. rest] =>
      match first.find("=") {
        None =>
          // `NAME[subscript]=value` / `NAME[subscript]+=value`
          match w.parts {
            [Lit(name), Subscript(index), Lit(rhs), .. tail] =>
              if is_valid_name(name) {
                let mut append = false
                let mut body = rhs
                if body.has_prefix("+=") {
                  append = true
                  body = body.unsafe_substring(start=2, end=body.length())
                } else if body.has_prefix("=") {
                  body = body.unsafe_substring(start=1, end=body.length())
                } else {
                  return None
                }
                let value : Array[WordPart] = []
                if body.length() > 0 {
                  value.push(Lit(body))
                }
                for p in tail {
                  value.push(p)
                }
                Some((name, append, index, value))
              } else {
                None
              }
            _ => None
          }
        Some(i) => {
          let mut name = first.unsafe_substring(start=0, end=i)
          let mut append = false
          if name.has_suffix("+") {
            append = true
            name = name.unsafe_substring(start=0, end=name.length() - 1)
          }
          if !is_valid_name(name) {
            return None
          }
          let value : Array[WordPart] = []
          let vtext = first.unsafe_substring(start=i + 1, end=first.length())
          if vtext.length() > 0 {
            value.push(Lit(vtext))
          }
          for p in rest {
            value.push(p)
          }
          Some((name, append, [], value))
        }
      }
    _ => None
  }
}

///|
/// Is the next token this operator, glued to the current one? Used for `((`,
/// which is arithmetic only without a space between the parens.
fn Parser::next_is_adjacent(self : Parser, op : String) -> Bool {
  match self.peek_tok() {
    TOp(o) => o == op && self.la_start == self.cur_start + 1
    _ => false
  }
}

///|
/// Whether a word is the `{varname}` descriptor prefix bash and zsh accept
/// before a redirect: `{fd}<file`, `exec {fd}>out`. The descriptor number is
/// assigned at run time, so for an audit only the redirect's target matters.
fn is_named_fd(text : String) -> Bool {
  if text.length() < 3 || !text.has_prefix("{") || !text.ends_with("}") {
    return false
  }
  let name = text.unsafe_substring(start=1, end=text.length() - 1)
  let mut i = 0
  for c in name {
    if i == 0 {
      if !is_name_start(c) {
        return false
      }
    } else if !is_name_char(c) {
      return false
    }
    i += 1
  }
  i > 0
}

///|
/// `2>&1` is a redirect on fd 2 only when the digit is glued to the operator;
/// `echo 2 > f` is just a word and a redirect on stdout.
fn Parser::fd_adjacent(self : Parser, w : Word) -> Bool {
  self.la_start == self.cur_start + w.raw.length()
}

///|
fn Parser::parse_simple(self : Parser) -> Cmd {
  let assigns : Array[Assign] = []
  let words : Array[Word] = []
  let redirs : Array[Redirect] = []
  for ;; {
    match self.cur {
      TWord(w) => {
        if self.peek_is_redirect() && self.fd_adjacent(w) {
          match w.plain() {
            Some(text) =>
              if all_digits(text) {
                self.advance()
                redirs.push(self.parse_redirect(Some(parse_fd(text))))
                continue
              } else if is_named_fd(text) {
                self.advance()
                redirs.push(self.parse_redirect(None))
                continue
              }
            _ => ()
          }
        }
        // Assignments at the head of a command, plus anywhere inside the
        // argument list of a declaration builtin.
        if assign_ok(words) {
          match split_assignment(w) {
            Some((name, append, index, value)) => {
              self.advance()
              // `a=(1 2 3)` and `a=([k]=v)` are array assignments: the value
              // is a word list, and its holes still have to be seen.
              let from_array = value.length() == 0 && self.cur is TOp("(")
              if from_array {
                self.advance()
                let mut closed = false
                for ;; {
                  match self.cur {
                    TWord(item) => {
                      for p in item.parts {
                        value.push(p)
                      }
                      self.advance()
                    }
                    TOp(")") => {
                      self.advance()
                      closed = true
                      break
                    }
                    TEof => break
                    _ => self.advance()
                  }
                }
                if !closed {
                  // `arr=(1` never closes: both shells refuse it, so accepting
                  // it would report a command that cannot run.
                  self.lex.fail("expected ) to close the array assignment")
                }
              }
              assigns.push({ name, append, array: from_array, index, value, })
              continue
            }
            None => ()
          }
        }
      }
      TOp(op) => {
        if is_redirect_op(op) {
          redirs.push(self.parse_redirect(None))
          continue
        }
        break
      }
      _ => break
    }
    match self.cur {
      TWord(w) => {
        // zsh reads `}` as a reserved word wherever it appears, not as an
        // argument, so a group needs no separator before its closing brace:
        // `{ echo a }` is fine there and a syntax error in bash.
        if self.lex.dialect is Zsh && w.plain() == Some("}") {
          break
        }
        // An assignment leaves the parser at a command position in zsh, so a
        // `{` straight after one is the construct's brace body and not an
        // argument: `if x=1 { : }` parses there. Only a condition asks for
        // that reading, so it stays behind `brace_body`.
        if self.brace_body && words.length() == 0 && self.at_body_brace() {
          break
        }
        words.push(w)
        self.advance()
      }
      _ => break
    }
  }
  Cmd::Simple({ assigns, words, redirects: redirs, })
}
