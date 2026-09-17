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
  FuncDef(name~ : String, body~ : Cmd)
  Arith(String)
  Cond(String) // [[ ... ]] kept as raw text in the spike
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
