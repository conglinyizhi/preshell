///|
/// Reading an argument list against the option tables in opt_tables.mbt.
///
/// The three spellings a value can take — `-oVAL`, a clustered short option,
/// `--long=VAL` — are split apart here and nowhere else, which is why the tables
/// do not list them row by row. What comes out is an ordered view of the words
/// plus a name-indexed view of the values, so a program's own semantics can ask
/// "what did -o get" without walking the words again.

///|
/// A value an option consumed, kept with its direction so the effect layer does
/// not have to re-parse anything.
pub(all) struct OptValue {
  opt : String
  val : OptVal
  text : String
  dynamic : Bool
  /// Whether the value may turn out to be absolute, and the variables it reads.
  /// A value carved out of the word (`-of.txt`) decides the first for itself;
  /// a value that is its own word (`-o f.txt`) inherits the word's answer.
  unrooted : Bool
  vars : Array[String]
  /// The reference this value was written as, when a value went into it.
  origin : String?
} derive(Debug, Eq)

///|
pub(all) struct ArgScan {
  /// Option tokens as written, same as the pre-table split. The narrow text
  /// checks (`find -exec`, `tar --create`) still read this.
  flags : Array[String]
  /// Recognised option names, with attached values split off (`-oout.txt` ->
  /// `-o`). Cases like `sed -i` are looked up here.
  opts : Array[String]
  /// Operands: everything that is neither an option nor a value it consumed.
  operands : Array[PathArg]
  values : Array[OptValue]
  /// The value of the target-directory option and whether it is a closed set,
  /// when the program has one. The flag matters: `cp -t $D a.txt` writes into
  /// a directory this tool cannot name, so the derived write is dynamic too.
  target_dir : PathArg?
  to_stdout : Bool
  from_option : Bool
} derive(Debug, Eq)

///|

///|
/// The same value as a path argument, for callers that push it as a path.
pub fn OptValue::to_path_arg(self : OptValue) -> PathArg {
  {
    text: self.text,
    dynamic: self.dynamic,
    unrooted: self.unrooted,
    vars: self.vars,
    origin: self.origin,
  }
}

///|
pub fn has_table(p : ProgOpts) -> Bool {
  p.specs.length() > 0
}

///|
fn spec_of(specs : Array[OptSpec], name : String) -> OptSpec? {
  for s in specs {
    if s.name == name {
      return Some(s)
    }
  }
  None
}

///|
fn empty_scan(
  flags : Array[String],
  opts : Array[String],
  operands : Array[PathArg],
  values : Array[OptValue],
  target_dir : PathArg?,
  to_stdout : Bool,
  from_option : Bool,
) -> ArgScan {
  { flags, opts, operands, values, target_dir, to_stdout, from_option, }
}

///|
/// The split used before the table existed: any argument starting with a dash
/// is a flag, the rest are operands. Programs with no table keep this exactly.
pub fn scan_legacy(items : Array[PathArg]) -> ArgScan {
  let flags : Array[String] = []
  let operands : Array[PathArg] = []
  for it in items {
    if it.text.has_prefix("-") {
      flags.push(it.text)
    } else if it.text != "" {
      operands.push(it)
    }
  }
  empty_scan(flags, [], operands, [], None, false, false)
}

///|
/// Record a consumed value unless it is empty (an empty write target would be
/// an invented path). Returns whether it names a target directory.
fn note_value(
  values : Array[OptValue],
  name : String,
  val : OptVal,
  arg : PathArg,
) -> Bool {
  match val {
    NoVal => ()
    _ =>
      if arg.text != "" {
        values.push({
          opt: name,
          val,
          text: arg.text,
          dynamic: arg.dynamic,
          unrooted: arg.unrooted,
          vars: arg.vars,
          origin: arg.origin,
        })
      }
  }
  match val {
    TargetDir => arg.text != ""
    _ => false
  }
}

///|
/// The path argument an option value stands for, given the word it was read
/// from. An attached value (`-of.txt`, `--file=a`) is carved out of the word, so
/// its own first segment decides whether the base can be applied; the word's
/// variables still apply to it either way.
pub fn value_arg(source : PathArg, text : String) -> PathArg {
  {
    text,
    dynamic: source.dynamic,
    unrooted: value_head_unresolved(text, source.dynamic),
    vars: source.vars,
    origin: source.origin,
  }
}

///|
/// Split an argument list using the table: values are consumed, operands are
/// what is left. Unknown short options are treated as taking no value (the
/// safe direction) but the scan continues, so `-no out.txt` still finds `-o`.
pub fn scan_args(p : ProgOpts, items : Array[PathArg]) -> ArgScan {
  let flags : Array[String] = []
  let opts : Array[String] = []
  let operands : Array[PathArg] = []
  let values : Array[OptValue] = []
  let mut target_dir : PathArg? = None
  let mut i = 0
  while i < items.length() {
    let item = items[i]
    let t = item.text
    if t.has_prefix("-") {
      flags.push(t)
      if t.has_prefix("--") && t.length() > 2 {
        match t.find("=") {
          Some(eq) => {
            let name = t.unsafe_substring(start=0, end=eq)
            let text = t.unsafe_substring(start=eq + 1, end=t.length())
            match spec_of(p.specs, name) {
              Some(s) => {
                opts.push(name)
                if note_value(values, name, s.val, value_arg(item, text)) {
                  target_dir = Some(value_arg(item, text))
                }
              }
              None => ()
            }
          }
          None =>
            match spec_of(p.specs, t) {
              Some(s) =>
                match s.val {
                  NoVal | Attached => opts.push(t)
                  _ => {
                    opts.push(t)
                    if i + 1 < items.length() {
                      i += 1
                      let value = items[i]
                      if note_value(values, t, s.val, value) {
                        target_dir = Some(value)
                      }
                    }
                  }
                }
              None => ()
            }
        }
      } else {
        let mut k = 1
        while k < t.length() {
          let name = "-" + t.unsafe_substring(start=k, end=k + 1)
          match spec_of(p.specs, name) {
            Some(s) =>
              match s.val {
                NoVal => {
                  opts.push(name)
                  k += 1
                }
                Attached => {
                  opts.push(name)
                  let rest = t.unsafe_substring(start=k + 1, end=t.length())
                  ignore(note_value(values, name, s.val, value_arg(item, rest)))
                  k = t.length()
                }
                _ => {
                  opts.push(name)
                  let rest = t.unsafe_substring(start=k + 1, end=t.length())
                  if rest != "" {
                    let value = value_arg(item, rest)
                    if note_value(values, name, s.val, value) {
                      target_dir = Some(value)
                    }
                  } else if i + 1 < items.length() {
                    i += 1
                    let value = items[i]
                    if note_value(values, name, s.val, value) {
                      target_dir = Some(value)
                    }
                  }
                  k = t.length()
                }
              }
            None => k += 1
          }
        }
      }
    } else if t != "" {
      operands.push(items[i])
    }
    i += 1
  }
  let to_stdout = opts.any(fn(o) { p.to_stdout.contains(o) })
  let from_option = opts.any(fn(o) { p.from_option.contains(o) })
  empty_scan(flags, opts, operands, values, target_dir, to_stdout, from_option)
}

///|
/// The text of a value consumed by one of `names`, if the option was used with
/// one. Used to derive paths the tool names itself, like sed's backup file.
pub fn value_of(scan : ArgScan, names : Array[String]) -> String? {
  for v in scan.values {
    if names.contains(v.opt) && v.text != "" {
      return Some(v.text)
    }
  }
  None
}

///|
/// The same value with its hole flag kept. It matters when the tool derives a
/// second path from it: `tar -czf $A dir` writes an archive nobody can name,
/// and `gzip -S $S f.txt` writes a product whose name depends on the suffix,
/// so both derived paths have to stay dynamic.
pub fn value_entry_of(scan : ArgScan, names : Array[String]) -> OptValue? {
  for v in scan.values {
    if names.contains(v.opt) && v.text != "" {
      return Some(v)
    }
  }
  None
}

///|
/// Where a file operand lands when written into the directory named by `-t`.
/// Measured: `cp -t destdir sub/a.txt` writes `destdir/a.txt` (basename), and
/// `cp -t destdir/ a.txt` writes `destdir/a.txt` (no doubled slash).
pub fn join_dir(dir : String, file : String) -> String {
  let base = basename(file)
  if base == "" {
    dir
  } else if dir.has_suffix("/") {
    dir + base
  } else {
    dir + "/" + base
  }
}
