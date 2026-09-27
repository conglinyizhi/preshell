// What the command line says its own parameters hold.
//
// Nothing outside the input is read: `$HOME` stays a hole because its value is
// not in the text, while `x=dist && rm -rf $x` is a fact this tool can state.
// That is why the rules here are narrow — a value substituted wrongly turns a
// hole into a confident wrong path, and a wrong path costs the caller more than
// a missing one.
//
// Scope follows the shell, the same way cwd.mbt follows it. A subshell, a
// command substitution and each element of a multi-command pipeline get a copy.
// An `if`, a loop body and a case body share the table while they run, and every
// name written inside one is dropped when it ends: `if c; then x=a; fi; rm $x`
// really does remove `a`, but only when the condition held, so the honest
// report is a hole rather than the value from one branch.
//
// Measured against bash 5.3, which is what decides each of these:
// `x=old; x=new echo "$x"` prints `old` (words expand before the assignments in
// front of a command take effect), `x=old; (x=sub); echo $x` prints `old`, and
// `x=old; for f in a b; do x=c; done; echo $x` prints `c` (a loop body runs in
// this shell, so what it set is dropped here rather than kept).

///|
/// Whether this text can stand in for a parameter with the shell doing nothing
/// else to it that this tool does not model.
///
/// Blanks are allowed, and split wherever the value lands unquoted: that is
/// fields.mbt's job, and it is the whole difference between `rm $x` and
/// `rm "$x"`. Glob characters are out because the fields they land in are
/// expanded against the file system, which this tool never reads. `$` and a
/// backtick would be another expansion, `~` another expansion at the head of a
/// word, and `{}` brace expansion — none of which happens to an expansion
/// result, but none of which this file is prepared to promise either. `=` is out
/// because a word that becomes `NAME=VALUE` in command position is an
/// assignment rather than a program. Other control characters are out with the
/// blanks that are not separators. Empty text is out: it is no argument
/// unquoted and one empty argument quoted, and this returns a single answer.
fn is_bindable_text(text : String) -> Bool {
  if text.length() == 0 {
    return false
  }
  for c in text {
    if c < ' ' && c != '\t' && c != '\n' {
      return false
    }
    match c {
      '*' | '?' | '[' | ']' | '{' | '}' | '$' | '`' | '~' | '=' => return false
      _ => ()
    }
  }
  true
}

///|
/// How many words a `for` list may have before its body is no longer walked
/// once per word. Unrolling is linear in the word count and multiplies the
/// effects of the body, so a list longer than this keeps the old answer — a
/// hole — instead of filling the effect list with copies of the same body.
fn max_unroll() -> Int {
  64
}

///|
/// How many values one name may hold before the tool stops tracking it. A set is
/// what the value *may* be, so a bigger one is still honest — just not worth
/// carrying, and the answer falls back to the plain hole.
fn max_values() -> Int {
  8
}

///|
/// How many paths one hole may name before the list stops being useful. Same
/// reasoning: past this the hole says everything the list would.
fn max_candidates() -> Int {
  8
}

///|
/// The values a name may hold, or None when the command line said nothing about
/// it. One value is a fact; more than one is a set of possibilities, which is
/// what a branch or a loop leaves behind.
fn lookup_values(
  binds : Array[(String, Array[String])],
  name : String,
) -> Array[String]? {
  for pair in binds {
    let (n, values) = pair
    if n == name {
      return Some(values)
    }
  }
  None
}

///|
/// The single value a name holds, or None when it holds several. Substitution
/// needs this one: putting several values into one word is what `candidates` is
/// for, not what a target is.
fn single_value(
  binds : Array[(String, Array[String])],
  name : String,
) -> String? {
  match lookup_values(binds, name) {
    Some(values) => if values.length() == 1 { Some(values[0]) } else { None }
    None => None
  }
}

///|
fn Collector::bind_set(
  self : Collector,
  name : String,
  values : Array[String],
) -> Unit {
  if name.length() == 0 ||
    values.length() == 0 ||
    values.length() > max_values() {
    return
  }
  let mut i = 0
  while i < self.binds.length() {
    let (n, _) = self.binds[i]
    if n == name {
      self.binds[i] = (name, values)
      return
    }
    i += 1
  }
  self.binds.push((name, values))
}

///|
/// Record that `name` holds `value`, as the one value it holds.
fn Collector::bind_value(
  self : Collector,
  name : String,
  value : String,
) -> Unit {
  self.bind_set(name, [value])
}

///|
/// Forget what `name` held. Everything that can write a parameter goes through
/// here when the new value is not something this tool can name: an unknown
/// value is a hole, a stale one would be a lie.
fn Collector::drop_value(self : Collector, name : String) -> Unit {
  let kept : Array[(String, Array[String])] = []
  for pair in self.binds {
    let (n, _) = pair
    if n != name {
      kept.push(pair)
    }
  }
  self.binds = kept
}

///|
fn copy_binds(
  binds : Array[(String, Array[String])],
) -> Array[(String, Array[String])] {
  let out : Array[(String, Array[String])] = []
  for pair in binds {
    out.push(pair)
  }
  out
}

///|

///|
fn copy_strings(values : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for v in values {
    out.push(v)
  }
  out
}

///|
fn push_unique(out : Array[String], more : Array[String]) -> Unit {
  for v in more {
    if !out.contains(v) {
      out.push(v)
    }
  }
}

///|
/// The table as it stands, for a construct that has to join several futures.
fn Collector::snapshot(self : Collector) -> Array[(String, Array[String])] {
  copy_binds(self.binds)
}

///|
fn Collector::restore(
  self : Collector,
  state : Array[(String, Array[String])],
) -> Unit {
  self.binds = copy_binds(state)
}

///|
fn sets_equal(a : Array[String], b : Array[String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for v in a {
    if !b.contains(v) {
      return false
    }
  }
  true
}

///|
/// Merge another state into this one: every value either side holds is possible.
///
/// The construct may or may not have run, so `if c; then x=b; fi` after `x=a`
/// leaves `x` as `a` or `b`, which is what the caller needs to know and is more
/// than "we forgot". A name missing from one side may be unset, and the empty
/// value stands in for that — it names no path either way, so nothing is lost by
/// spelling it that way. A set that grew past `max_values` is dropped, which is
/// the old answer.
fn Collector::join_with(
  self : Collector,
  other : Array[(String, Array[String])],
) -> Unit {
  let merged : Array[(String, Array[String])] = []
  for pair in self.binds {
    let (name, values) = pair
    let out = copy_strings(values)
    match lookup_values(other, name) {
      Some(more) => push_unique(out, more)
      None => push_unique(out, [""])
    }
    if out.length() <= max_values() {
      merged.push((name, out))
    }
  }
  for pair in other {
    let (name, values) = pair
    if lookup_values(self.binds, name) is None {
      let out = copy_strings(values)
      push_unique(out, [""])
      if out.length() <= max_values() {
        merged.push((name, out))
      }
    }
  }
  self.binds = merged
}

///|
/// Keep only the names this construct could not have written.
///
/// This is for the constructs whose iteration count is not modelled: a `while`
/// body may run any number of times, so a value it sets is not a set of
/// possibilities but an unknown, and joining one pass of it would name a set that
/// is not exhaustive.
fn Collector::drop_changed(
  self : Collector,
  base : Array[(String, Array[String])],
) -> Unit {
  let kept : Array[(String, Array[String])] = []
  for pair in base {
    let (name, values) = pair
    match lookup_values(self.binds, name) {
      Some(now) => if sets_equal(now, values) { kept.push(pair) }
      None => ()
    }
  }
  self.binds = kept
}

///|
/// Open a scope that is a separate process: a subshell, a command substitution,
/// an element of a multi-command pipeline. Returns the table to restore.
fn Collector::open_isolated(self : Collector) -> Array[(String, Array[String])] {
  copy_binds(self.binds)
}

///|
fn Collector::close_isolated(
  self : Collector,
  saved : Array[(String, Array[String])],
) -> Unit {
  self.binds = saved
}

///|
/// The word with every bound parameter replaced by its value. A name that is
/// not bound stays a hole, so a word with one name resolved and one not keeps
/// its `dynamic` flag and is reported as the one partial fact it always was.
fn Word::substituted(
  self : Word,
  binds : Array[(String, Array[String])],
) -> Word {
  if binds.length() == 0 {
    return self
  }
  let (parts, changed) = substitute_parts(self.parts, binds)
  if !changed {
    return self
  }
  // `raw` is what decides whether a word is a reserved word or `NAME=VALUE`, so
  // it is rebuilt only when the parts actually moved: for an untouched word the
  // spelling has to stay exactly as the caller wrote it.
  { parts, raw: parts_text(parts), line: self.line, }
}

///|
fn Word::resolved_by(self : Word, collector : Collector) -> Word {
  self.substituted(collector.binds)
}

///|
/// The command with every value the command line established put in place. The
/// redirect targets are words like any other, so they are resolved by the same
/// rule; an assignment's own parts are left alone, because the value they build
/// is read by `note_assign` rather than turned into a path.
fn Collector::resolved_simple(self : Collector, s : SimpleCmd) -> SimpleCmd {
  let words : Array[Word] = []
  for w in s.words {
    for e in self.value_words(w) {
      words.push(e)
    }
  }
  let redirects : Array[Redirect] = []
  for r in s.redirects {
    match self.value_words(r.target) {
      [only] =>
        redirects.push({ fd: r.fd, op: r.op, target: only, body: r.body, })
      // An unquoted redirect target that splits is an ambiguous redirect:
      // measured, bash refuses the command rather than opening anything, so the
      // target is reported as not what it says rather than as a path.
      _ =>
        redirects.push({
          fd: r.fd,
          op: r.op,
          target: r.target.as_hole(),
          body: r.body,
        })
    }
  }
  { assigns: s.assigns, words, redirects, }
}

///|
fn substitute_parts(
  parts : Array[WordPart],
  binds : Array[(String, Array[String])],
) -> (Array[WordPart], Bool) {
  let out : Array[WordPart] = []
  let mut changed = false
  let mut i = 0
  while i < parts.length() {
    let p = parts[i]
    // A brace right after a name belongs to the expansion of that name: measured,
    // `x=1; echo $x{a,b}` is `$xa` and `$xb`, so the value does not go in here and
    // the word stays a hole.
    let glued = if i + 1 < parts.length() {
      match parts[i + 1] {
        Lit(s) => s.has_prefix("{")
        _ => false
      }
    } else {
      false
    }
    match p {
      Param(name) => {
        // A name with several possible values is not put in: one word cannot hold
        // two texts, and the hole it leaves is what `candidates` hangs off.
        let bound = if glued { None } else { single_value(binds, name) }
        match bound {
          Some(v) => {
            out.push(Lit(v))
            changed = true
          }
          None => out.push(p)
        }
      }
      DQuote(inner) => {
        let (quoted, moved) = substitute_parts(inner, binds)
        if moved {
          out.push(DQuote(quoted))
          changed = true
        } else {
          out.push(p)
        }
      }
      Subscript(inner) => {
        let (index, moved) = substitute_parts(inner, binds)
        if moved {
          out.push(Subscript(index))
          changed = true
        } else {
          out.push(p)
        }
      }
      _ => out.push(p)
    }
    i += 1
  }
  (out, changed)
}

///|
/// The texts a run of parts can come out as: one when the value is known, several
/// when a name in it may hold any of them, none when something is left for the
/// shell to do (a hole, a glob, a nested command, a tilde, arithmetic).
///
/// The product is what makes `y=$x` after `if c; then x=a; else x=b; fi` leave `y`
/// with the same two possibilities rather than with nothing.
fn value_texts(
  parts : Array[WordPart],
  binds : Array[(String, Array[String])],
) -> Array[String] {
  let mut texts : Array[String] = [""]
  for p in parts {
    let next = part_texts(p, binds)
    if next.length() == 0 {
      return []
    }
    let out : Array[String] = []
    for t in texts {
      for v in next {
        out.push(t + v)
        if out.length() > max_values() {
          return []
        }
      }
    }
    texts = out
  }
  // An empty value is a value: `IFS=` turns splitting off entirely and `x=` makes
  // `$x` disappear rather than name a path, and the use sites know how to read
  // both (fields.mbt). What is refused here is text the shell would do something
  // else to.
  let out : Array[String] = []
  for t in texts {
    if t.length() == 0 || is_bindable_text(t) {
      out.push(t)
    } else {
      return []
    }
  }
  out
}

///|
/// The texts one part can be: a literal is itself, a name is its value or its
/// values, quotes are what they hold, and anything the shell would expand later
/// has no text at all.
fn part_texts(
  p : WordPart,
  binds : Array[(String, Array[String])],
) -> Array[String] {
  match p {
    Lit(s) | SQuote(s) => [s]
    Param(name) =>
      match lookup_values(binds, name) {
        Some(values) => values
        None => []
      }
    DQuote(inner) | Subscript(inner) => value_texts(inner, binds)
    _ => []
  }
}

///|
/// Read a `NAME=VALUE` assignment as the values the rest of the command line can
/// use, or drop what was known.
///
/// `x+=y`, `a[0]=y` and `name=(...)` all build on the old value or on an index,
/// so they leave the name without a value this tool can state.
fn Collector::note_assign(self : Collector, a : Assign) -> Unit {
  if a.array || a.append || a.index.length() > 0 {
    self.drop_value(a.name)
    return
  }
  let values = value_texts(a.value, self.binds)
  if values.length() == 0 {
    self.drop_value(a.name)
  } else {
    self.bind_set(a.name, values)
  }
}

///|
/// Whether a program can write a shell parameter, and how far the write goes.
///
/// An external program cannot: only these builtins reach back into the shell's
/// own variables, so this list is the whole of the risk. `.` and `eval` hand the
/// shell a command line that is not in this input, so every value is dropped
/// rather than kept across them.

///|
/// Private: this decides behaviour inside the auditor and is not part of the
/// CLI contract.
priv enum WriteKind {
  /// No shell variable is written.
  NoWrite
  /// The named arguments, after any options.
  Named
  /// The argument after `-v` (printf).
  AfterFlag
  /// Anything may have been written.
  Everything
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
/// What a `NAME=VALUE` word in a builtin's argument list does to the name.
///
/// The parser pulls those words out of the argument list into `assigns`, because
/// bash's own parser marks them assignments there (parse.y:5798, PST_ASSIGNOK,
/// and `takes_assignments` below mirrors that list). What the builtin then does
/// with the name is its own business, and measured against bash 5.3 it is not
/// always the value the word spells: `export x=a` sets `a`, `let x=a` sets the
/// arithmetic value (`0`), and `alias x=a` sets no shell variable at all.
priv enum DeclAction {
  /// Sets the name to that value: `export`, `declare`, `local`, `readonly`.
  SetsValue
  /// Writes the name, to something the word does not say: `let x=a` is `0`.
  OtherValue
  /// Writes no shell variable: `alias`, or an assignment in front of a command.
  NoVariable
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
        self.drop_value(n)
      }
    }
    AfterFlag => {
      let mut i = 1
      while i < s.words.length() {
        let t = s.words[i].literal_text()
        if t == "-v" && i + 1 < s.words.length() {
          for n in written_names([s.words[i + 1].literal_text()]) {
            self.drop_value(n)
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
        self.drop_value(n)
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
