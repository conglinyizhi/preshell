///|
/// Which names a command writes to.
///
/// A program that writes a name is a program whose effect on the rest of the
/// command line cannot be followed: `read x` puts something in `x` that is not
/// in the text, so every later use of `x` is a hole rather than a guess. The
/// builtin tables here are measured, and a builtin this file does not know is
/// treated as writing whatever it could be given.
///
/// The distinction that matters: a name that was written to is *unnameable*, not
/// unknown — `candidates_for` reports nothing for it rather than a short list,
/// because a list that is missing a value is worse than no list at all.

///|
/// Read a `NAME=VALUE` assignment as the values the rest of the command line can
/// use, or drop what was known.
///
/// `x+=y`, `a[0]=y` and `name=(...)` all build on the old value or on an index,
/// so they leave the name without a value this tool can state.
fn Collector::note_assign(self : Collector, a : Assign) -> Unit {
  if a.array || a.append || a.index.length() > 0 {
    self.poison_value(a.name)
    return
  }
  let values = value_texts(a.value, self.binds)
  if values.length() == 0 {
    self.poison_value(a.name)
  } else {
    self.bind_set(a.name, values)
  }
}

///|
fn write_kind(name : String) -> WriteKind {
  match name {
    "read" | "readarray" | "mapfile" | "unset" | "getopts" | "shift" => Named
    "printf" => AfterFlag
    "." | "source" | "eval" => Everything
    _ => NoWrite
  }
}

///|
/// Whether an option word is present among the arguments of a declaration
/// builtin. An option can change what the word means (`declare -i x=1+2` leaves
/// `3`), so any of them turns the whole statement off.
fn has_option_word(words : Array[Word]) -> Bool {
  for i, w in words {
    if i > 0 && w.literal_text().has_prefix("-") {
      return true
    }
  }
  false
}

///|
fn decl_action(s : SimpleCmd) -> DeclAction {
  let name = match command_name(s) {
    Some(n) => n
    None => return NoVariable
  }
  match name {
    "export" | "readonly" | "declare" | "typeset" | "local" =>
      if has_option_word(s.words) {
        OtherValue
      } else {
        SetsValue
      }
    // `let` reads every one of its words as arithmetic, so the value in the
    // word is never the value in the name. `alias` writes its own table.
    "let" => OtherValue
    _ => NoVariable
  }
}

///|
/// The names a command's own arguments say it writes: `unset x y`, `read -r x`,
/// `printf -v out`, `export FOO=1`.
fn written_names(vars : Array[String]) -> Array[String] {
  let names : Array[String] = []
  for v in vars {
    // `x[0]=v` writes the array, and the name is what is before the bracket.
    let name = match v.find("[") {
      Some(i) => v[:i].to_owned()
      None =>
        match v.find("=") {
          Some(i) => v[:i].to_owned()
          None => v
        }
    }
    if name.length() > 0 && !names.contains(name) {
      names.push(name)
    }
  }
  names
}

///|
/// Apply what a simple command says about the shell's own parameters.
///
/// A command whose name is a builtin is handled here; everything else is left
/// alone, because an external program cannot set a variable of the shell that
/// started it.
fn Collector::note_command_writes(self : Collector, s : SimpleCmd) -> Unit {
  let name = match command_name(s) {
    Some(n) => n
    None => return
  }
  match write_kind(name) {
    NoWrite => ()
    Everything => {
      let all : Array[String] = []
      for pair in self.binds {
        let (n, _) = pair
        all.push(n)
      }
      for n in all {
        self.poison_value(n)
      }
    }
    AfterFlag => {
      let mut i = 1
      while i < s.words.length() {
        let t = s.words[i].literal_text()
        if t == "-v" && i + 1 < s.words.length() {
          for n in written_names([s.words[i + 1].literal_text()]) {
            self.poison_value(n)
          }
          i += 2
        } else {
          i += 1
        }
      }
    }
    Named => {
      let args : Array[String] = []
      let mut i = 1
      while i < s.words.length() {
        let t = s.words[i].literal_text()
        // Options first, and their own arguments (`read -t 5 x`): a word that
        // starts with `-` and the word that follows a flag known to take one
        // are skipped. Anything else is a name this builtin writes.
        if t.has_prefix("-") {
          i += if t == "-t" || t == "-d" || t == "-n" || t == "-p" || t == "-u" {
            2
          } else {
            1
          }
          continue
        }
        args.push(t)
        i += 1
      }
      for n in written_names(args) {
        // `unset x` really does leave the name unset; the readers in the same
        // group (`read`, `getopts`, `mapfile`) leave it holding something this
        // tool cannot name.
        if name == "unset" {
          self.drop_value(n)
        } else {
          self.poison_value(n)
        }
      }
    }
  }
}

///|
/// The words a `for` list hands out, or None when the list is not a closed set
/// the tool can spell out. Each word has to come out as plain text with nothing
/// left for the shell to do: `for f in lib/*.ts` needs the file system, and
/// `for f in {a,b}` needs brace expansion, which is not modelled.
fn Collector::loop_values(
  self : Collector,
  name : String,
  words : Array[Word],
) -> Array[String]? {
  if name.length() == 0 || words.length() == 0 || words.length() > max_unroll() {
    return None
  }
  let out : Array[String] = []
  for w in words {
    match w.resolved_by(self).static_text() {
      Some(t) => if is_bindable_text(t) { out.push(t) } else { return None }
      None => return None
    }
  }
  Some(out)
}

///|
/// A word in the list position of a `for`: the shell expands it there the same
/// way it would as an argument, so a glob or a hole is reported instead of
/// disappearing. Saying nothing about `for f in *.ts` left the loop's own word
/// list out of the report entirely.
fn Collector::note_list_word(self : Collector, w : Word) -> Unit {
  let w = w.resolved_by(self)
  let arg = PathArg::of(w)
  if arg.dynamic && !arg.text.has_prefix("-") {
    self.push_path(Unknown, arg, w.line)
  }
}
