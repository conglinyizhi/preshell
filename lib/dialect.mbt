///|
/// Which shell's grammar to read.
///
/// The audit layer does not care about this: what a command touches is the same
/// question in either shell, so `effects` / `paths` / `facts` are shared. Only
/// lexing and parsing differ, and this is consulted there and nowhere else.
pub(all) enum Dialect {
  Bash
  Zsh
} derive(Debug, Eq, ToJson)

///|
/// Read a dialect from an interpreter name. Returns `None` for shells whose
/// grammar is not modelled at all (fish, csh, python...), which is a different
/// answer from "bash": those inputs must not be read with bash rules either.
pub fn Dialect::from_shell_name(name : String) -> Dialect? {
  match name {
    "bash"
    | "sh"
    | "dash"
    | "ash"
    | "ksh"
    | "ksh93"
    | "mksh"
    | "posh"
    | "yash" => Some(Bash)
    "zsh" => Some(Zsh)
    _ => None
  }
}
