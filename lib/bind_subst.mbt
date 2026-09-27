///|
/// Substituting a value the command line set back into a word.
///
/// This is the half of the binding layer that produces text: a name whose value
/// is known is replaced by it, and the resulting word is what the report names
/// and what later effects are built from. The value only goes in when
/// `is_bindable_text` says the shell would do nothing else to it — blanks are
/// allowed and split later (fields.mbt), globs and further expansions are not,
/// because a value substituted wrongly turns a hole into a confident wrong path.
///
/// The word keeps the reference it was written as (`origin`), so a caller can
/// still match the effect against the command text it handed over.

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
  //
  // `origin` is that spelling: the reference the value replaced. A word that was
  // already substituted keeps the reference it had first (`y=$x; rm $y` reports
  // `$y`, the thing in the command text), so a chain of assignments still points
  // at something the caller can find.
  {
    parts,
    raw: parts_text(parts),
    line: self.line,
    origin: match self.origin {
      Some(o) => Some(o)
      None => Some(parts_text(self.parts))
    },
  }
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
