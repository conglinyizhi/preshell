///|
/// Which shell the input declares, when it declares one.
///
/// This matters because the tool parses **bash** semantics and nothing else. A
/// script that says `#!/bin/zsh` may use syntax bash reads differently, and
/// saying "Complete, nothing unusual" about it would be a claim the tool cannot
/// back up. So the declaration is read and, when it names something this tool
/// does not model, reported as an issue.
///
/// `sh`, `dash` and `bash` are not flagged: bash is the superset the tool
/// parses, and a POSIX script is the common case that has to keep working
/// without noise.
pub fn declared_shell(src : String) -> String? {
  let first_line = match src.find("\n") {
    Some(i) => src.unsafe_substring(start=0, end=i)
    None => src
  }
  if !first_line.has_prefix("#!") {
    return None
  }
  let words = first_line
    .unsafe_substring(start=2, end=first_line.length())
    .trim()
    .split(" ")
    .to_array()
  let parts : Array[String] = []
  for w in words {
    if w.length() > 0 {
      parts.push(w.to_owned())
    }
  }
  if parts.length() == 0 {
    return None
  }
  // `#!/usr/bin/env bash` names the shell in the next word.
  let name = if basename(parts[0]) == "env" && parts.length() > 1 {
    parts[1]
  } else {
    basename(parts[0])
  }
  // Strip arguments like the `-e` in `#!/bin/sh -e`.
  if name == "" {
    None
  } else {
    Some(name)
  }
}

///|
fn basename(p : String) -> String {
  match p.rev_find("/") {
    Some(i) => p.unsafe_substring(start=i + 1, end=p.length())
    None => p
  }
}

///|
/// Shells this tool parses. bash is the reference; sh and dash are close enough
/// that a POSIX script has to keep working without a warning on every file.
fn is_modelled_shell(name : String) -> Bool {
  match name {
    "sh" | "bash" | "dash" => true
    _ => false
  }
}

///|
/// The note to attach when a script declares a shell this tool does not model.

///|
/// What to tell the caller about the shell the input declares, when the
/// dialect being read is a different one.
///
/// Two cases, because they are not the same statement: a shell this tool *can*
/// read but was not asked to (the caller picked another dialect, so the note is
/// about that choice), and a shell no dialect here covers at all (where the
/// caveat is that the grammar is simply not the one being parsed).
fn declared_shell_note(src : String, dialect : Dialect) -> Array[String] {
  match declared_shell(src) {
    Some(name) =>
      if is_modelled_shell(name) ||
        Dialect::from_shell_name(name) == Some(dialect) {
        []
      } else {
        match Dialect::from_shell_name(name) {
          Some(_) =>
            [
              "this input declares " +
              name +
              " but was read as " +
              dialect_name(dialect) +
              ": the answer may not match what " +
              name +
              " does with it",
            ]
          None =>
            [
              "this input declares " +
              name +
              ", which is not a shell this tool reads: the analysis assumes " +
              dialect_name(dialect) +
              " and may not match what it does",
            ]
        }
      }
    None => []
  }
}

///|
fn dialect_name(d : Dialect) -> String {
  match d {
    Bash => "bash"
    Zsh => "zsh"
  }
}
