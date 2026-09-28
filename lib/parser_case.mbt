///|
/// The `case` construct: its subject, its pattern lists, and the two zsh-only
/// shapes that come with them.
///
/// Both exceptions live here because both are about the same question — where
/// does a pattern list end. zsh takes the subject in parentheses, and it takes a
/// pattern that is itself one balanced `(...)` group without a closing paren of
/// its own; bash reads that same text as the list's paren and refuses nothing.
/// The patterns are words and not commands, which is what the lexer's
/// `in_casepat` state is for, so it is set and cleared here and nowhere else.

///|
/// True when the pattern list we just read is zsh's parenthesised pattern: the
/// whole pattern is one balanced `(...)` group, so the `)` that just closed the
/// group does double duty as the list's own closing paren.
///
/// Measured: zsh 5.9.2 accepts `case $x in (gnu) echo hi ;; esac` and
/// `case $x in (net|open)bsd*) echo hi ;; esac` — `(gnu)` and `gnu` mean the
/// same thing there. Its parser has a branch for exactly this shape (Src/parse.c
/// marks it "Hack here"): it fires when the first pattern is one balanced
/// `(...)` and what follows is neither `)` nor `|`, and strips the outer pair.
/// bash reads the same text as the pattern list's own paren, so this stays
/// zsh-only.
fn Parser::pattern_is_group(self : Parser, patterns : Array[Word]) -> Bool {
  if !(self.lex.dialect is Zsh) || patterns.length() != 1 {
    return false
  }
  let parts = patterns[0].parts
  if parts.length() < 2 {
    return false
  }
  let opens = match parts[0] {
    Glob("(") => true
    _ => false
  }
  if !opens {
    return false
  }
  let mut depth = 0
  for p in parts {
    match p {
      Glob("(") => depth += 1
      Glob(")") => {
        depth -= 1
        if depth < 0 {
          return false
        }
      }
      _ => ()
    }
  }
  depth == 0
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
    } else if !self.pattern_is_group(patterns) {
      // Measured on bash 5.3 and zsh 5.9.2: both refuse a pattern list whose
      // `)` is missing. `case x in a : ;; esac` and `case x in a) :;; junk
      // esac` are the same defect — the trailing `junk` is read as the next
      // pattern list — so one rule covers both shapes. The one exception is
      // zsh's parenthesised pattern, see `pattern_is_group`.
      self.lex.fail("expected ) to close the case pattern")
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
