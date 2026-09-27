///|
/// The wrappers: programs whose work is running another program.
///
/// `env`, `nice`, `nohup`, `timeout`, `stdbuf`, `setsid`, `xargs` and `command`
/// all end in execvp, so the command they run is the real subject of the report
/// and this file is what finds it. The options a wrapper takes are its own, not
/// the inner program's, which is why they are listed here rather than guessed.

///|
/// Programs that run another program and hand it their own command line.
/// Measured with the shim: `env rm -rf victim.txt`, `timeout 5 rm -f x`,
/// `nice -n 5 rm`, `nohup rm`, `stdbuf -oL rm`, `setsid rm`, `command rm` and
/// `xargs rm` all end up deleting the file they are handed. Before this, each
/// of them reported only "an unmodelled program ran", which is true and says
/// nothing about what it ran.
fn is_wrapper(n : String) -> Bool {
  match n {
    "env"
    | "nice"
    | "nohup"
    | "timeout"
    | "stdbuf"
    | "setsid"
    | "command"
    | "xargs" => true
    _ => false
  }
}

///|
/// The wrapper's own options that take the next word as their value. The
/// lists are measured against the real program (`nice -n 5 rm`, `timeout -s
/// KILL 5 rm`, `env -u FOO rm`, `env -a argv0 rm`, `stdbuf -o L rm`,
/// `xargs -I{} rm`, ...). `setsid -c` is deliberately absent: it is --ctty and
/// takes no value, so consuming the next word after it would eat the command.
fn wrapper_value_opts(n : String) -> Array[String] {
  match n {
    "env" =>
      [
        "-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "--argv0",
      ]
    "timeout" => ["-s", "--signal", "-k", "--kill-after"]
    "nice" => ["-n", "--adjustment"]
    "stdbuf" => ["-i", "-o", "-e", "--input", "--output", "--error"]
    "xargs" =>
      [
        "-E", "-I", "-L", "-n", "-P", "-s", "-d", "-a", "--eof", "--replace", "--max-lines",
        "--max-args", "--max-procs", "--max-chars", "--delimiter", "--arg-file",
      ]
    _ => []
  }
}

///|
/// Whether this word is `NAME=VALUE` before an `env` command name. It is part
/// of the environment, not the program to run: `env FOO=1 rm x` runs rm.
fn is_env_assign(t : String) -> Bool {
  match t.find("=") {
    Some(eq) =>
      eq > 0 &&
      !t.unsafe_substring(start=0, end=eq).contains("/") &&
      is_valid_name(t.unsafe_substring(start=0, end=eq))
    None => false
  }
}

///|
/// Where the program a wrapper runs starts, or None when `n` is not a wrapper.
/// The wrapper's own options are skipped, an `env` assignment is skipped, and
/// `timeout`'s DURATION is skipped because it is a number, not a command.
fn wrapper_target(n : String, words : Array[Word]) -> Wrapped? {
  if !is_wrapper(n) {
    return None
  }
  let value_opts = wrapper_value_opts(n)
  // timeout's first non-option word is its DURATION.
  let mut prologue = if n == "timeout" { 1 } else { 0 }
  let mut i = 1
  while i < words.length() {
    let t = words[i].literal_text()
    if t == "--" {
      i += 1
      break
    }
    if !t.has_prefix("-") || t == "-" {
      if n == "env" && is_env_assign(t) {
        i += 1
        continue
      }
      if prologue > 0 {
        prologue -= 1
        i += 1
        continue
      }
      break
    }
    // `command -v rm` asks where rm is; it does not run it. Measured: the
    // file the argument names is still there afterwards.
    if n == "command" && (t == "-v" || t == "-V") {
      return Some(Wrapped::Nothing)
    }
    // `env -S "rm -rf x"` runs the string, not a word of its own.
    if n == "env" && (t == "-S" || t == "--split-string") {
      return Some(Wrapped::FromString)
    }
    i += 1 + wrapper_option_extra_words(value_opts, t)
  }
  if i >= words.length() {
    // `env` on its own prints the environment and runs nothing.
    return Some(Wrapped::Nothing)
  }
  Some(Wrapped::Command(i))
}

///|
/// Whether an xargs command uses a replacement string (`-I{}`, `--replace=`,
/// or the old `-i`). Every argument that spells it becomes a placeholder for
/// the input, so the command's argv cannot be read as literal paths.
fn xargs_replaces(words : Array[Word]) -> Bool {
  for i, w in words {
    if i == 0 {
      continue
    }
    let t = w.literal_text()
    if t.has_prefix("-I") || t.has_prefix("-i") || t.has_prefix("--replace") {
      return true
    }
  }
  false
}

///|
/// Wrappers that exec a file: `env`, `nice`, `nohup`, `timeout`, `stdbuf`,
/// `setsid` and `xargs` all end in execvp, so a shell word cannot be the
/// program they run. `cd` and `eval` are the two whose effects would be
/// invented if followed: a moved working directory and a parsed string for a
/// command that fails. `command` is the exception, it runs builtins in the
/// current shell.
fn wrapper_runs_shell_words(n : String) -> Bool {
  n == "command"
}

///|
/// Wrappers nest for free: the inner command goes back through classify, so
/// `env timeout 5 rm -f x` and `nice -n 5 xargs rm` work the same way.
fn Collector::wrapper_effects(
  self : Collector,
  n : String,
  s : SimpleCmd,
  target : Wrapped,
  line : Int,
) -> Unit {
  // The wrapper itself runs and touches nothing of its own.
  self.push(Exec, n, false, line, origin=words_origin(s.words))
  match target {
    Wrapped::Nothing => ()
    Wrapped::FromString =>
      self.push(
        Unknown,
        n + ": the command line is inside a string option",
        true,
        line,
      )
    Wrapped::Command(i) => {
      if self.depth >= max_wrapper_depth() {
        self.push(Unknown, n + ": wrapper depth limit", true, line)
        return
      }
      let inner = s.words[i:].to_owned()
      let name = inner[0].literal_text()
      if n == "xargs" {
        // -a/--arg-file: the list is read from a file instead of stdin, and
        // that file is a path. Measured: `xargs -a list rm` opens list.
        match option_word_value(s.words, ["-a", "--arg-file"]) {
          Some(f) => self.push_path(Read, f, line)
          None => ()
        }
        if xargs_replaces(s.words) {
          // -I/--replace (and the old -i) substitute each input line into
          // every occurrence of a string in the command. Those words are
          // placeholders, not paths: following `xargs -I{} rm {}` reported
          // `{}` as a file to delete.
          self.push(
            Exec,
            name,
            false,
            line,
            modeled=false,
            origin=words_origin(inner),
          )
          self.push(
            Unknown,
            "xargs: the replaced arguments come from its input",
            true,
            line,
          )
          return
        }
      }
      if !wrapper_runs_shell_words(n) && (name == "cd" || name == "eval") {
        self.push(
          Exec,
          name,
          false,
          line,
          modeled=false,
          origin=words_origin(inner),
        )
      } else {
        // The outer command's redirections come along, because they are what
        // the inner program reads: `env python3 - <<'PY'` hands the body to
        // python3, and a payload search that cannot see it reports nothing.
        // Walking them twice is harmless: the second visit is the same fact on
        // the same line, which dedupe already collapses.
        let cmd : SimpleCmd = {
          assigns: [],
          words: inner,
          redirects: s.redirects,
        }
        self.depth += 1
        self.classify(name, cmd, line)
        self.depth -= 1
      }
      if n == "xargs" {
        // The words xargs appends come from its input, which this tool does
        // not read. The fixed part above still counts; this says what is
        // missing from it.
        self.push(
          Unknown,
          "xargs: the argument list comes from its input",
          true,
          line,
        )
      }
    }
  }
}
