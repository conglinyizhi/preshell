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
/// Record what `name` may hold. An **empty** list means "the command line wrote
/// this name, with something this tool cannot name" (`x=$HOME/y`, `x=$(date)`,
/// `read x`), which is not the same as never having touched it: an untouched
/// name may be unset, while this one holds something. `candidates` depends on
/// that difference — see `poison_value`.
fn Collector::bind_set(
  self : Collector,
  name : String,
  values : Array[String],
) -> Unit {
  if name.length() == 0 || values.length() > max_values() {
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
/// Note that `name` now holds something this tool cannot name. The name stays in
/// the table with no values rather than disappearing, because "written, value
/// unknown" and "never written" are different facts: the first one rules out the
/// candidate list (`the value is one of these` would be a lie), the second one
/// does not.
fn Collector::poison_value(self : Collector, name : String) -> Unit {
  self.bind_set(name, [])
}

///|
/// Forget that `name` was ever written: this is what `unset` does. What the name
/// holds is then up to the caller's environment, which is a different state from
/// `poison_value`.
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
      // Either side holding something unnameable makes the whole name
      // unnameable: `if c; then x=/a; else x=$HOME/s; fi` leaves no set that
      // could be called exhaustive.
      Some(more) =>
        if values.length() == 0 || more.length() == 0 {
          out.clear()
        } else {
          push_unique(out, more)
        }
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
      // It holds something now, and which something is not modelled: poison it
      // rather than dropping it, so a candidate list built over it is ruled out.
      None => kept.push((name, []))
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
