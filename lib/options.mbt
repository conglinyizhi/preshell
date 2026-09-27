///|
/// Reading a program's own options.
///
/// Deliberately coarse: modelling how every program parses its own arguments is
/// a project of its own, and getting it wrong is the main source of false paths.
/// So these helpers answer only the questions the impact layer actually asks —
/// does this flag appear, what is the first operand, which word is a flag's
/// value, how many words does a flag swallow — and where the answer matters,
/// the caller reports an `Unknown` rather than a confident wrong path.
///
/// Two callers reach for the same shapes: the command table in classify.mbt
/// (`find -name PATTERN`, `tar -f FILE`) and the wrappers in wrapper.mbt, which
/// have to skip their own options to find the program they run. The lists of
/// value-taking options are passed in rather than baked in here, because they
/// belong to the program being read (`runner_value_opts` in tools.mbt is the
/// same idea for the runners).

///|
/// The value that follows one of `names` in an argument list, if present.
fn flag_value(items : Array[PathArg], names : Array[String]) -> String? {
  for i, it in items {
    let t = it.text
    for n in names {
      if t == n && i + 1 < items.length() {
        return Some(items[i + 1].text)
      }
      if t.has_prefix(n + "=") {
        return Some(t.unsafe_substring(start=n.length() + 1, end=t.length()))
      }
    }
  }
  None
}

///|
fn has_flag_text(flags : Array[String], f : String) -> Bool {
  flags.any(fn(x) {
    x == f || (x.has_prefix("-") && !x.has_prefix("--") && x.contains(f))
  })
}

///|
/// Drop the operand that a known flag already consumed, so a value like the
/// `-C dir` of tar is not reported twice: once as the write target and once as
/// a path the command reads.
fn drop_flag_value(xs : Array[PathArg], value : String?) -> Array[PathArg] {
  match value {
    None => xs
    Some(v) => xs.filter(fn(it) { it.text != v })
  }
}

///|
/// The operands that come before the first flag. For commands like `find`,
/// whose later arguments are predicates rather than paths (`-name '*.mbt'`),
/// only the leading ones are files.
fn leading_operands(items : Array[PathArg]) -> Array[PathArg] {
  let out : Array[PathArg] = []
  for it in items {
    if it.text.has_prefix("-") {
      break
    }
    if it.text != "" {
      out.push(it)
    }
  }
  out
}

///|
/// How many words one option token takes with it: 0 when the value is glued to
/// the token (`-n1`, `--unset=FOO`) or the option takes none, 1 when the value
/// is the next word. A short cluster can carry a value letter anywhere, so it
/// is walked letter by letter.
fn wrapper_option_extra_words(value_opts : Array[String], t : String) -> Int {
  if t.has_prefix("--") {
    match t.find("=") {
      Some(_) => 0
      None => if value_opts.contains(t) { 1 } else { 0 }
    }
  } else {
    let mut k = 1
    while k < t.length() {
      let name = "-" + t.unsafe_substring(start=k, end=k + 1)
      if value_opts.contains(name) {
        return if k + 1 < t.length() { 0 } else { 1 }
      }
      k += 1
    }
    0
  }
}

///|
/// The value of one of `names` in a raw word list, with its hole flag, for the
/// three spellings `-a list`, `-alist` and `--arg-file=list`. Wrappers are
/// scanned from their words rather than from the option table, so the one path
/// option they have (`xargs -a`) is found here.
fn option_word_value(words : Array[Word], names : Array[String]) -> PathArg? {
  for i, w in words {
    let t = w.literal_text()
    for n in names {
      if t == n && i + 1 < words.length() {
        return Some(PathArg::of(words[i + 1]))
      }
      if t.has_prefix(n + "=") {
        let value = t.unsafe_substring(start=n.length() + 1, end=t.length())
        return Some(value_arg(PathArg::of(w), value))
      }
      if !n.has_prefix("--") && t.has_prefix(n) && t.length() > n.length() {
        let value = t.unsafe_substring(start=n.length(), end=t.length())
        return Some(value_arg(PathArg::of(w), value))
      }
    }
  }
  None
}
