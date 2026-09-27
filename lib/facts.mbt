///|
/// Small facts about a parsed command that the impact extractor needs.
///
/// The distinction this file keeps: classifying *what a program is* is a fact
/// ("bash is an interpreter", "curl talks to the network"), while deciding
/// whether that is acceptable is policy and lives with the caller.
///
/// `has_flag` and the argument helpers are deliberately coarse. Modelling how
/// every program parses its own arguments is a project of its own, and getting
/// it wrong is the main source of false paths; when it matters, the honest
/// answer is an `Unknown` effect rather than a confident wrong path.
fn command_name(s : SimpleCmd) -> String? {
  match s.words {
    [w, ..] => w.static_text()
    _ => None
  }
}

///|
/// The reference the first of these words was written as, when a value the
/// command line set went into it. This is what every effect that names a program
/// carries as its `origin`: `x=/usr/bin/jq; $x -n 1` runs `/usr/bin/jq`, and `$x`
/// is the only thing in the command text a caller can match that `Exec` against
/// by text.
fn words_origin(words : Array[Word]) -> String? {
  match words {
    [w, ..] => w.origin
    _ => None
  }
}

///|
fn arg_texts(s : SimpleCmd) -> Array[String] {
  let out : Array[String] = []
  for w in s.words {
    out.push(w.literal_text())
  }
  out
}

///|
fn line_of(s : SimpleCmd) -> Int {
  match s.words {
    [w, ..] => w.line
    _ => 0
  }
}

///|

///|
/// Shells. `-c "..."` on one of these is a command line this tool can parse,
/// which is the only reason recursion is safe at all.
fn is_shell(n : String) -> Bool {
  match n {
    "bash" | "sh" | "zsh" | "dash" | "ksh" => true
    _ => false
  }
}

///|
/// Programs that run other programs or scripts. Their behaviour is decided by
/// what they are handed, not by their arguments, so they are reported as
/// unmodelled rather than guessed at.
fn is_interpreter(n : String) -> Bool {
  match n {
    "bash"
    | "sh"
    | "zsh"
    | "dash"
    | "ksh"
    | "python"
    | "python3"
    | "perl"
    | "ruby"
    | "node"
    | "php"
    | "Rscript" => true
    _ => false
  }
}

///|
/// Programs whose own arguments decide everything they touch: no path operands,
/// no network, nothing outside the string they were given. Anything else they do
/// is decided inside them, so the report is a lower bound.
///
/// This is a claim about the program, so the rule for adding a name is the same
/// as everywhere else here: **when unsure, leave it out**. An omitted program
/// becomes unmodelled, which is the safe direction; a wrongly included one
/// silently under-reports.

///|
/// Programs with no file behaviour of their own: they are pure text or shell
/// state, and any file they touch is touched through a redirection, which the
/// report captures separately.
///
/// This is a claim about the program, so the rule for adding a name is the same
/// as everywhere else here: **when unsure, leave it out**. An omitted program
/// becomes unmodelled, which is the safe direction; a wrongly included one
/// silently under-reports.
fn is_pure(n : String) -> Bool {
  match n {
    // text producers and tests
    "echo"
    | "printf"
    | "true"
    | "false"
    | ":"
    | "test"
    | "["
    | "[["
    | "seq"
    | "expr"
    | "basename"
    | "tr"
    | "dirname"
    | "tty"
    | "sleep" => true
    // system questions, no file arguments
    "pwd"
    | "date"
    | "id"
    | "whoami"
    | "uname"
    | "hostname"
    | "printenv"
    | "umask" => true
    // shell state
    "export"
    | "unset"
    | "set"
    | "shift"
    | "exit"
    | "return"
    | "break"
    | "continue"
    | "trap"
    | "wait"
    | "local"
    | "declare"
    | "typeset"
    | "readonly"
    | "let"
    | "read"
    | "alias"
    | "unalias"
    | "hash"
    | "jobs"
    | "fg"
    | "bg"
    | "kill" => true
    _ => false
  }
}

///|
/// Programs whose *arguments are the files they touch*. This list is closed on
/// purpose, and it stays short for a reason: it is only the set of programs
/// whose whole job is file manipulation, so modelling them needs no knowledge
/// of any application.
///
/// Everything else — interpreters, build tools, package managers, anything
/// written by someone else — is reported as unmodelled. Enumerating what
/// `node`, `python` or `docker` touch means reading the scripts and images they
/// are given, which is not a bounded project; marking them is.
fn is_path_modeled(n : String) -> Bool {
  match n {
    "cat"
    | "head"
    | "tail"
    | "less"
    | "more"
    | "grep"
    | "rg"
    | "awk"
    | "sort"
    | "wc"
    | "diff"
    | "readlink"
    | "stat"
    | "file"
    | "md5sum"
    | "sha256sum"
    | "base64"
    | "strings"
    | "xxd"
    | "cut"
    | "uniq"
    | "comm"
    | "join"
    | "paste"
    | "expand"
    | "fold"
    | "nl"
    | "od"
    | "tee"
    | "touch"
    | "truncate"
    | "mkdir"
    | "rmdir"
    | "ln"
    | "install"
    | "split"
    | "csplit"
    | "chmod"
    | "chown"
    | "chgrp"
    | "rm"
    | "unlink"
    | "shred"
    | "cp"
    | "mv"
    | "rsync"
    | "sed"
    | "dd"
    | "tar"
    | "unzip"
    | "zip"
    | "gzip"
    | "gunzip"
    | "bzip2"
    | "bunzip2"
    | "xz"
    | "unxz"
    | "zstd"
    | "unzstd"
    | "source"
    | "."
    | "ls"
    | "du"
    | "df"
    | "tree"
    | "realpath"
    | "find" => true
    _ => false
  }
}

///|
/// Programs that talk to the network. Kept apart from the path-modelled set:
/// `git status` is neither a network call nor a file operation this tool can
/// follow, and lumping it in here would mislabel both.
fn is_network_modeled(n : String) -> Bool {
  match n {
    "curl"
    | "wget"
    | "nc"
    | "ncat"
    | "ssh"
    | "scp"
    | "sftp"
    | "telnet"
    | "ping"
    | "dig" => true
    _ => false
  }
}

///|
/// `eval "..."` and `sh -c "..."` with a static string: the string is a real
/// command line whose effects belong to the same answer. A dynamic string
/// yields None, which the caller reports as an unknown rather than guessing.
fn eval_script(s : SimpleCmd, n : String) -> String? {
  if n == "eval" {
    let sb = StringBuilder()
    for i, w in s.words {
      if i == 0 {
        continue
      }
      let t = match w.static_text() {
        Some(t) => t
        None => return None
      }
      if i > 1 {
        sb.write_char(' ')
      }
      sb.write_string(t)
    }
    return Some(sb.to_string())
  }
  let args = arg_texts(s)
  for i, a in args {
    if a == "-c" && i + 1 < args.length() {
      return s.words[i + 1].static_text()
    }
  }
  None
}
