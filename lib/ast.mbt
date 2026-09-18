///|
/// A fragment of a shell word.  We never expand anything: the auditor only
/// needs to know whether a word is *static* (fully determined by the text) or
/// carries a hole the shell will fill in at run time.
pub(all) enum WordPart {
  Lit(String) // literal text, escapes already resolved
  SQuote(String) // '...'  -- literal text
  DQuote(Array[WordPart]) // "..."  -- may contain holes
  Param(String) // $name, ${...}, $1, $@  -- run-time hole
  CmdSub(Seq) // $(...) or `...`  -- a nested command, audited recursively
  ArithSub(String) // $((...))  -- run-time value
  ProcSub(Char, Seq) // <(...) or >(...)
  Glob(String) // unquoted * ? [...] -- matches many paths
  Subscript(Array[WordPart]) // name[...] -- array subscript, quotes and all
  Tilde(String) // ~ or ~user
} derive(Debug, Eq, ToJson)

///|
/// A shell word plus enough source position to point at it later.
pub(all) struct Word {
  parts : Array[WordPart]
  raw : String
  line : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) enum RedirOp {
  RIn // <
  ROut // >
  RAppend // >>
  RInOut // <>
  RDupIn // <&
  RDupOut // >&
  RHereDoc // <<
  RHereDocStrip // <<-
  RHereString // <<<
  RClobber // >|
} derive(Debug, Eq, ToJson)

///|
/// `body` is filled in later by the lexer: a here-document body can only be
/// collected once the newline ending the current line has been seen.
pub(all) struct Redirect {
  fd : Int?
  op : RedirOp
  target : Word
  mut body : String?
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Assign {
  name : String
  append : Bool
  /// True for the `name=(...)` form, which is bash/ksh only: a POSIX shell
  /// rejects it, so a script declaring sh that uses one will not run there.
  array : Bool
  /// The subscript parts of `name[...]=value`; empty for a plain assignment.
  /// `a[$i]=x` carries a hole here, and the audit has to see it.
  index : Array[WordPart]
  value : Array[WordPart]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct SimpleCmd {
  assigns : Array[Assign]
  words : Array[Word]
  redirects : Array[Redirect]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct CaseItem {
  patterns : Array[Word]
  body : Seq
  fallthrough : Int // 0 = ;;  1 = ;&  2 = ;;&
} derive(Debug, Eq, ToJson)

///|
pub(all) enum Cmd {
  Simple(SimpleCmd)
  Subshell(Seq)
  Group(Seq)
  If(cond~ : Seq, then_~ : Seq, elifs~ : Array[(Seq, Seq)], else_~ : Seq?)
  Loop(until~ : Bool, cond~ : Seq, body~ : Seq)
  For(name~ : String, words~ : Array[Word], body~ : Seq)
  Case(subject~ : Word, items~ : Array[CaseItem])
  /// `keyword` is true for the `function name` form, which is bash/ksh only;
  /// the plain `name()` form is POSIX and must not be reported as a bashism.
  FuncDef(name~ : String, body~ : Cmd, keyword~ : Bool)
  /// zsh: `{ body } always { fin }`, the block that runs either way.
  Always(inner~ : Seq, always~ : Seq)
  /// zsh: `() { body } arg...` -- an anonymous function. It runs right there,
  /// with the words after the body as its arguments, so both the body and
  /// anything inside those words are commands that really run. bash refuses the
  /// whole form.
  AnonFunc(body~ : Cmd, args~ : Array[Word], redirects~ : Array[Redirect])
  Arith(String)
  /// `[[ ... ]]`. The condition text is opaque to an audit -- patterns and
  /// parameters touch no paths -- but command substitutions inside it do run,
  /// so they are carried separately. Dropping them made
  /// `[[ -f "$(cat secret.txt)" ]]` report nothing at all.
  Cond(raw~ : String, subs~ : Array[Seq])
  /// Any compound command may carry its own redirections:
  /// `( ls ) 2>/dev/null`, `{ echo x; } >&2`, `while ...; done < file`.
  /// bash spells this as `shell_command redirection_list`.
  Redirected(inner~ : Cmd, redirects~ : Array[Redirect])
} derive(Debug, Eq, ToJson)

///|
pub(all) enum BinOp {
  Pipe // |
  PipeErr // |&
  And // &&
  Or // ||
  Semi // ; or newline
  Amp // &
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Pipeline {
  negated : Bool
  cmds : Array[Cmd]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct AndOr {
  pipeline : Pipeline
  op : BinOp // separator that follows this pipeline
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Seq {
  items : Array[AndOr]
} derive(Debug, Eq, ToJson)

///|
pub fn Seq::empty() -> Seq {
  { items: [], }
}

///|
pub fn Seq::length(self : Seq) -> Int {
  self.items.length()
}
