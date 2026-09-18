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
}

///|
pub fn Parser::Parser(lex : Lexer) -> Parser {
  let cur = lex.next()
  { lex, cur, cur_start: lex.tok_start, la: None, la_start: 0, depth: 0, }
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
  if (stop.ops.length() > 0 || stop.words.length() > 0) && self.cur is TEof {
    let what = if label == "" { "construct" } else { label }
    // Point at where the construct opened: end of input is where the parser
    // noticed, not where the problem is.
    self.lex.fail_at("unexpected end of input in " + what, started_at)
  }
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
      Some(And)
    }
    TOp("||") => {
      self.advance()
      Some(Or)
    }
    TOp("&") => {
      self.advance()
      Some(Amp)
    }
    TOp(";") => {
      self.advance()
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
      if self.next_is_adjacent("(") && self.lex.is_arith_at(self.cur_start) {
        let start = self.cur_start + 2
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
        Some("repeat") => self.parse_repeat()
        Some("while") => self.parse_loop(false)
        Some("until") => self.parse_loop(true)
        Some("for") => self.parse_for()
        Some("select") => self.parse_for()
        Some("case") => self.parse_case()
        Some("function") => self.parse_function_kw()
        Some("time") => {
          self.advance()
          self.parse_command()
        }
        Some("coproc") => {
          self.advance()
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
          if self.reserved() == Some("always") {
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
  for ;; {
    match self.cur {
      TEof => break
      TWord(w) => if w.plain() == Some("]]") { break } else { self.advance() }
      _ => self.advance()
    }
  }
  let raw = self.lex.slice(start, self.cur_start)
  if self.reserved() == Some("]]") {
    self.advance()
  } else {
    self.lex.fail("unexpected end of input in [[ ]]")
  }
  Cmd::Cond(raw)
}

///|
fn Parser::parse_if(self : Parser) -> Cmd {
  self.advance()
  let cond = self.parse_seq_in({ words: ["then"], ops: [], }, "if")
  if self.reserved() == Some("then") {
    self.advance()
  }
  let then_ = self.parse_seq_in(
    { words: ["elif", "else", "fi"], ops: [], },
    "if",
  )
  let elifs : Array[(Seq, Seq)] = []
  for ;; {
    if self.reserved() == Some("elif") {
      self.advance()
      let c = self.parse_seq_in({ words: ["then"], ops: [], }, "if")
      if self.reserved() == Some("then") {
        self.advance()
      }
      let b = self.parse_seq_in(
        { words: ["elif", "else", "fi"], ops: [], },
        "if",
      )
      elifs.push((c, b))
    } else {
      break
    }
  }
  let else_ = if self.reserved() == Some("else") {
    self.advance()
    Some(self.parse_seq_in({ words: ["fi"], ops: [], }, "if"))
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
  self.skip_newlines()
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
  let cond = self.parse_seq_in({ words: ["do"], ops: [], }, "loop")
  if self.reserved() == Some("do") {
    self.advance()
  }
  let body = self.parse_seq_in({ words: ["done"], ops: [], }, "loop")
  if self.reserved() == Some("done") {
    self.advance()
  }
  Cmd::Loop(until~, cond~, body~)
}

///|
fn Parser::parse_for(self : Parser) -> Cmd {
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
  if self.cur is TOp("(") && self.next_is_adjacent("(") {
    // `for ((...))` requires arithmetic: bash errors out here instead of
    // falling back to subshells (parse.y:parse_dparen, the FOR case).
    if !self.lex.is_arith_at(self.cur_start) {
      self.lex.fail("expected an arithmetic expression after for ((")
    }
    // for ((init; cond; step)) -- the condition may itself contain parens
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
  } else {
    if self.lex.dialect is Zsh && self.cur is TOp("(") {
      // `for x ( a b )`: the parens belong to the word list.
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
      self.advance()
      for ;; {
        match self.cur {
          TWord(w) => {
            words.push(w)
            self.advance()
          }
          _ => break
        }
      }
    }
    if self.cur is TOp(";") {
      self.advance()
    }
  }
  self.lex.in_for_words = false
  self.skip_newlines()
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
  Cmd::For(name~, words~, body~)
}

///|
fn Parser::parse_case(self : Parser) -> Cmd {
  self.advance()
  let subject = match self.cur {
    TWord(w) => {
      self.advance()
      w
    }
    _ => empty_word(self.lex.line)
  }
  self.skip_newlines()
  if self.reserved() == Some("in") {
    // From here the patterns are words: zsh reads `(net|open)bsd*)` as one
    // pattern with a glob group in it, not as the pattern list's own paren
    // followed by two alternatives.
    self.lex.in_casepat = true
    self.advance()
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
  Cmd::FuncDef(name~, body~, keyword=true)
}

///|
fn Parser::parse_simple_or_funcdef(self : Parser, w : Word) -> Cmd {
  // `name()` is a function definition; `name=(...)` is an array assignment,
  // and bash happily accepts function names that are not identifiers (`:`).
  let is_assign = match split_assignment(w) {
    Some(_) => true
    None => false
  }
  match w.plain() {
    Some(name) =>
      if !is_assign {
        match self.peek_tok() {
          TOp("(") => {
            self.advance()
            self.advance()
            if self.cur is TOp(")") {
              self.advance()
              return Cmd::FuncDef(
                name~,
                body=self.parse_command(),
                keyword=false,
              )
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
    None => ()
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
            Some(digits) if all_digits(digits) => {
              self.advance()
              redirs.push(self.parse_redirect(Some(parse_fd(digits))))
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
                      break
                    }
                    TEof => break
                    _ => self.advance()
                  }
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
        words.push(w)
        self.advance()
      }
      _ => break
    }
  }
  Cmd::Simple({ assigns, words, redirects: redirs, })
}
