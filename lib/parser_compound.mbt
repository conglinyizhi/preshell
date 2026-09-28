///|
/// The compound commands: `if`, `for`, `while`/`until`, `case`, `repeat`, the
/// function definitions and the csh-style loop header.
///
/// They are separated from the sequence parser because their bodies are where
/// the grammar is least uniform: the two dialects disagree about how a body is
/// ended, and the audit has to walk each body exactly as the shell would —
/// `repeat 3 { rm -rf x }` reports the write, and a body that is never walked is
/// a fact missing from the answer rather than a smaller one.

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
  // the zsh dialect only (measured against both shells). A second name makes
  // the loop name list a rotation rather than a value, so the first name is
  // dropped: keeping it would say `a` holds each word of the list in turn, and
  // it holds every other word.
  let mut extra_names = false
  if self.lex.dialect is Zsh {
    for ;; {
      match self.cur {
        TWord(w) =>
          match w.plain() {
            Some(s) =>
              if s.length() > 0 && !is_command_word(s) {
                extra_names = true
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
  if extra_names {
    name = ""
  }
  let words : Array[Word] = []
  // Whether the loop named an explicit word list (`in ...` or `( ... )`). That
  // is what decides the body-less case at the end: `for i in a` cannot run in
  // either shell, while `for i` is a valid zsh loop over `$@` that does
  // nothing, and bash refuses even that.
  let mut had_words = false
  // Whether the word list came from the csh spelling's parens. In zsh that is
  // also what allows a body with no `do` after it.
  let mut in_parens = false
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
      // `for x ( a b )`: the parens belong to the word list, and the body may
      // follow without any `do` (see parse_csh_body).
      had_words = true
      in_parens = true
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
  // In zsh's csh spelling the body may follow the word list with no `do` at all:
  // measured, `for x (a b) echo $x` runs `echo` per word, and the separators
  // after the list belong to that shape rather than to the caller.
  let csh_body = in_parens &&
    self.lex.dialect is Zsh &&
    !foreach &&
    !(self.reserved() == Some("do") ||
    self.reserved() == Some("{") ||
    self.reserved() == Some("end"))
  if !foreach &&
    !csh_body &&
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
  } else if csh_body {
    self.parse_csh_body()
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
/// The body of zsh's csh spelling, which needs no `do`: `for x (a b) echo $x`.
///
/// The body is one command list and it ends at the first `;` or newline that is
/// not inside a nested construct. Measured against zsh 5.9.2:
///
/// - `for x (a b) echo $x; echo after` prints `a`, `b`, `after`, so the `after`
///   is not part of the body, while `for x (a b) echo $x && echo yes` keeps the
///   `&&` in it and prints `a yes b yes`
/// - `for x (a b) if true; then echo $x; fi` is one body, because the `;` inside
///   the `if` belongs to the `if`
/// - `&` ends the body and puts the whole loop in the background: measured,
///   `for x (a b) echo $x & echo two` prints `two` first
/// - a body on the next line counts (`for x (a b)` then a newline then
///   `echo $x`), and no body at all is legal: `for x (a b)` runs nothing
///
/// bash refuses every one of these shapes, so this stays zsh-only.
fn Parser::parse_csh_body(self : Parser) -> Seq {
  let items : Array[AndOr] = []
  for ;; {
    if self.cur is TEof {
      break
    }
    let before = self.lex.pos
    let pipeline = self.parse_pipeline()
    // A `&&` or `||` chain stays in the body. Everything else — `;`, a newline,
    // `&`, the end of the input — ends it, and that separator is left alone for
    // the list that called us: `for x (a b) echo $x & echo two` backgrounds the
    // whole loop, which is only true if the `&` is still there to be read.
    let op = match self.cur {
      TOp("&&") => {
        self.advance()
        self.check_operator_sequence("&&")
        And
      }
      TOp("||") => {
        self.advance()
        self.check_operator_sequence("||")
        Or
      }
      _ => {
        items.push({ pipeline, op: Semi, })
        break
      }
    }
    items.push({ pipeline, op, })
    if self.lex.pos == before {
      self.advance()
    }
  }
  { items, }
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
  if self.lex.dialect is Bash {
    if is_empty_command(body) {
      self.lex.fail("expected a body after the function definition")
    }
    if body is Simple(_) {
      // bash wants a compound command: measured, `function f echo hi` is a
      // syntax error there while zsh runs it.
      self.lex.fail("expected a compound command as the function body")
    }
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
