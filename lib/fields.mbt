// Word splitting: what the shell does to an unquoted expansion before a command
// sees its arguments.
//
// This is the other half of bind.mbt. Once a value may hold a blank — and it may,
// there is nothing special about `x="a b"` — where the value lands decides how
// many words there are: `rm $x` is two arguments and `rm "$x"` is one, and the
// second one names a file whose name really has a space in it. Measuring that
// difference is the whole point of this file.
//
// The rules are the manual's "Word Splitting" and subst.c's `list_string`
// (reached from `word_split`, subst.c:12362), each one checked against bash 5.3.

///|
/// The characters that separate fields when nothing changed IFS: the shell splits
/// on space, tab and newline.
fn default_ifs() -> String {
  " \t\n"
}

///|
fn ifs_has(ifs : String, c : Char) -> Bool {
  for x in ifs {
    if x == c {
      return true
    }
  }
  false
}

///|
/// The value `IFS` holds, taken from the values the command line set. The tool
/// never reads the environment, so an IFS that came from outside is the default
/// one — which is also what an unset IFS means.
///
/// None means the command line left IFS with several possible values (`if c;
/// then IFS=:; fi`): which characters split is then not knowable, and no value is
/// put in at all rather than one that splits the wrong way.
fn Collector::ifs_chars(self : Collector) -> String? {
  match lookup_values(self.binds, "IFS") {
    Some(values) => if values.length() == 1 { Some(values[0]) } else { None }
    None => Some(default_ifs())
  }
}

///|
/// The names a word reads outside quotes. A name inside `"..."` never splits, so
/// it is not listed.
fn unquoted_names(w : Word) -> Array[String] {
  let out : Array[String] = []
  for p in w.parts {
    match p {
      Param(name) => if !out.contains(name) { out.push(name) }
      _ => ()
    }
  }
  out
}

///|
/// Whether putting this value in changes how many words there are: a value with an
/// IFS character in it is split, and an empty one disappears.
fn value_splits(value : String, ifs : String) -> Bool {
  if value.length() == 0 {
    return true
  }
  for c in value {
    if ifs_has(ifs, c) {
      return true
    }
  }
  false
}

///|
/// Split one expanded value the way an unquoted expansion is split.
///
/// Measured against bash 5.3, with `printf '<%s>'` over each case:
///
/// - a run of IFS whitespace delimits a field, and whitespace at either end of
///   the value delimits nothing: `" a "` is one field and `" a  b "` is two
/// - a non-whitespace IFS character delimits a field on its own and swallows the
///   whitespace beside it: with `IFS=:` `"a: b"` is one field `" b"`, and with
///   `IFS=" :"` it is two fields `a` and `b`
/// - such a character at the start of the value makes an empty field (`:a` is
///   `""` and `a`) and at the end it does not (`a:` is one field, `::` is two
///   empty ones)
/// - an empty IFS turns splitting off: the value stays one field
fn split_fields(value : String, ifs : String) -> Array[String] {
  let out : Array[String] = []
  if ifs.length() == 0 {
    out.push(value)
    return out
  }
  let mut cur : StringBuilder? = None
  for c in value {
    if !ifs_has(ifs, c) {
      match cur {
        Some(sb) => sb.write_char(c)
        None => {
          let sb = StringBuilder()
          sb.write_char(c)
          cur = Some(sb)
        }
      }
      continue
    }
    if is_ifs_blank(c) {
      // Whitespace only ends a field that was being built; on its own it is
      // padding and produces nothing.
      match cur {
        Some(sb) => {
          out.push(sb.to_string())
          cur = None
        }
        None => ()
      }
      continue
    }
    // A separator in its own right: the field in hand ends here, empty or not.
    out.push(
      match cur {
        Some(sb) => sb.to_string()
        None => ""
      },
    )
    cur = None
  }
  match cur {
    Some(sb) => out.push(sb.to_string())
    None => ()
  }
  out
}

///|
/// The words this one expands to once the values the command line set are put in.
///
/// An unquoted name splits its value into fields and a quoted one does not, which
/// is the difference between `x="a b"; rm $x` (two paths) and `rm "$x"` (one path
/// with a space in it). A name whose value has no separator in it takes the plain
/// path, which is also what happens when splitting is off (`split=false`, for the
/// right-hand side of an assignment: the shell does not split there).
///
/// Two names that both have to split are left alone. The shell splits the whole
/// expanded word, and gluing the pieces of one name onto the pieces of another
/// needs the full algorithm; a hole is the honest answer instead.
fn Collector::value_words(
  self : Collector,
  w : Word,
  split? : Bool = true,
) -> Array[Word] {
  let ifs = match self.ifs_chars() {
    Some(v) => v
    // IFS itself is not decided by this command line: an unquoted name could be
    // any number of words and there is no way to say which, so the word keeps its
    // hole.
    None => {
      if unquoted_names(w).length() > 0 {
        return [w]
      }
      return [w.resolved_by(self)]
    }
  }
  let single = [w.resolved_by(self)]
  let mut splitter = -1
  let mut name = ""
  let mut count = 0
  if split {
    for i, p in w.parts {
      match p {
        Param(n) =>
          match single_value(self.binds, n) {
            Some(v) =>
              if value_splits(v, ifs) {
                count += 1
                splitter = i
                name = n
              }
            None => ()
          }
        _ => ()
      }
    }
  }
  if count == 0 {
    return if empty_after_values(w, single) { [] } else { single }
  }
  if count > 1 {
    // Left as a hole: every name in it stays unsubstituted.
    return [w]
  }
  let value = match single_value(self.binds, name) {
    Some(v) => v
    None => ""
  }
  let pieces = split_fields(value, ifs)
  let prefix = w.parts[:splitter].to_owned()
  let suffix = w.parts[splitter + 1:].to_owned()
  let out : Array[Word] = []
  if pieces.length() == 0 {
    // The value disappeared. What is left is the text around it.
    let parts : Array[WordPart] = []
    parts.append(prefix)
    parts.append(suffix)
    let built = self.finish(parts, w)
    if built.literal_text().length() > 0 {
      out.push(built)
    }
    return out
  }
  for k, piece in pieces {
    let parts : Array[WordPart] = []
    if k == 0 {
      parts.append(prefix)
    }
    parts.push(Lit(piece))
    if k == pieces.length() - 1 {
      parts.append(suffix)
    }
    let built = self.finish(parts, w)
    // A name that expands to nothing leaves no word: measured, an unquoted `$x`
    // with an empty value is not an argument at all.
    if built.literal_text().length() > 0 || piece.length() > 0 {
      out.push(built)
    }
  }
  out
}

///|
/// Build a word from parts that came out of a substitution, then put in whatever
/// else the word held: a name inside quotes does not split, but it does still
/// need its value.
fn Collector::finish(
  self : Collector,
  parts : Array[WordPart],
  w : Word,
) -> Word {
  let built : Word = {
    parts,
    raw: parts_text(parts),
    line: w.line,
    origin: None,
  }
  built.resolved_by(self)
}

///|
/// Whether a word that reads a name came out empty. A name with nothing in it is
/// no argument at all — measured, `x=""; rm "$x"` names an empty path and deletes
/// nothing — so it is left out rather than reported as an empty target.
fn empty_after_values(w : Word, resolved : Array[Word]) -> Bool {
  if w.vars().length() == 0 || resolved.length() != 1 {
    return false
  }
  resolved[0].literal_text().length() == 0
}
