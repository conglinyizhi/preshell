///|
/// The simple command: its words, its prefixes, its assignments, and the
/// checkers that decide whether a word is a name, an assignment or a stray
/// operator.
///
/// This is where the messy half of the grammar lives. A word can be an
/// assignment and a command at once, a function definition can be written three
/// ways, and the two dialects disagree about which of those are legal at all —
/// so the rules are read from the shells' own behaviour and the shapes that are
/// not modelled are refused rather than guessed at.

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
                let mut stray = false
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
                    // An array body is a word list, not a command list:
                    // measured on bash 5.3 and zsh 5.9.2, both refuse a bare
                    // `(`, `&`, `&&` or `|` in there (`x=(a && b)`,
                    // `x=(a (b))`), and both refuse a redirect
                    // (`x=(a > f)`). Newlines and comments stay fine.
                    TOp(";") =>
                      // `;` separates commands, not words, so this one is
                      // dialect-bound: bash refuses `x=(a;b)`, zsh runs it.
                      if self.lex.dialect is Zsh {
                        self.advance()
                      } else {
                        stray = true
                        break
                      }
                    TOp("(") | TOp("&") | TOp("&&") | TOp("||") | TOp("|") => {
                      stray = true
                      break
                    }
                    TOp(op) =>
                      if is_redirect_op(op) {
                        stray = true
                        break
                      } else {
                        self.advance()
                      }
                    _ => self.advance()
                  }
                }
                if stray {
                  // A word list that ran into a command operator: naming the
                  // word list is more use than blaming the missing `)`.
                  self.lex.fail("expected a word list in the array assignment")
                } else if !closed {
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
          let body = self.parse_command()
          // `f()` with nothing after it is refused by both shells (measured),
          // and bash wants a compound command as the body: `f() echo hi` and
          // `f() :` are syntax errors there, while zsh runs both.
          if is_empty_command(body) {
            self.lex.fail("expected a body after the function definition")
          }
          if self.lex.dialect is Bash && body is Simple(_) {
            self.lex.fail("expected a compound command as the function body")
          }
          return Cmd::FuncDef(name~, body~, keyword=false)
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
/// The operators that close a `case` branch: bash spells the plain one `;;` and
/// adds `;;&` for "keep testing the next pattern", zsh spells those `;|` and
/// `;&`.
fn is_case_terminator(op : String) -> Bool {
  match op {
    ";;" | ";&" | ";;&" | ";|" => true
    _ => false
  }
}

///|
/// A connector has to be followed by a command. Measured: both shells refuse
/// `cmd &&& x`, `cmd ||| x`, `cmd && || x`, `cmd | | x` and `cmd & & x`.
/// zsh is the lenient one here: it takes `cmd && ; x` and `cmd ; ; x`, so an
/// empty command between separators is allowed there and nowhere else.
///
/// `after` is the connector that was just consumed, and it settles one shape:
/// a `case` terminator may close the branch straight after a `;` or an `&`
/// (measured, `case x in a) : ; ;; esac` and `case x in a) : & ;; esac` both
/// run there), while `&&`, `||` and `|` in that place are refused by both
/// shells. Same reading as the zsh exception above: an empty command is fine
/// only where the shell does not demand a right-hand side.
fn Parser::check_operator_sequence(self : Parser, after : String) -> Unit {
  if self.cur is TNewline || self.cur is TEof {
    return
  }
  match self.cur {
    TOp(op) =>
      if is_control_operator(op) &&
        !(self.lex.dialect is Zsh && op == ";") &&
        !(is_case_terminator(op) && (after == ";" || after == "&")) {
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
/// Is the next token this operator, glued to the current one? Used for `((`,
/// which is arithmetic only without a space between the parens.
fn Parser::next_is_adjacent(self : Parser, op : String) -> Bool {
  match self.peek_tok() {
    TOp(o) => o == op && self.la_start == self.cur_start + 1
    _ => false
  }
}
