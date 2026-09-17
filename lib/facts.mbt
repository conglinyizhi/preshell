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
fn is_downloader(n : String) -> Bool {
  match n {
    "curl" | "wget" | "fetch" | "http" | "httpie" | "aria2c" => true
    _ => false
  }
}

///|
fn has_flag(args : Array[String], flag : String) -> Bool {
  args.any(fn(a) {
    a == flag ||
    (
      a.has_prefix("-") &&
      !a.has_prefix("--") &&
      a.contains(flag.unsafe_substring(start=1, end=flag.length()))
    )
  })
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
