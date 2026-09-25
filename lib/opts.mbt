///|
/// Option-value semantics: program -> its options.
///
/// Why this is a table of its own: before it, `arg_items` only asked "does this
/// argument start with a dash", so the *value* of an option always landed on
/// the operand side. That produced both failure directions at once:
/// `sort -o out.txt in.txt` reported `out.txt` as a read, and `head -n 5`
/// reported the number `5` as a path. The root cause is the same: nothing knew
/// which options consume a value.
///
/// Rows are only added from measurement. The method is an `LD_PRELOAD` shim
/// over libc file entry points (open/openat/fopen/freopen/stat/fstatat/statx/
/// unlink/rename/link/symlink/chmod/mkdir/truncate) run against the real
/// command, logging the flag each call used; for the compressors `-c` a
/// filesystem snapshot (run, then diff the directory) settles it because the
/// binaries do not all go through libc. When unsure, leave the row out:
/// omitting one only under-reports, which is the safe direction, while a wrong
/// row invents a path.
///
/// The three spellings (`-oVAL`, clustered short options, `--long=VAL`) are
/// split by `scan_args`, not listed row by row.

///|
/// What an option does with a value.
pub(all) enum OptVal {
  /// Takes no value.
  NoVal
  /// Takes a value that is not a path: a number, a pattern, a delimiter, a
  /// suffix, a field list, ...
  NotPath
  /// Takes a value that is a read path. `--reference` (stat only) is recorded
  /// here too: a stat is a read.
  ReadPath
  /// Takes a value that is a write path.
  WritePath
  /// Takes a value that is a path, but which direction it counts in depends on
  /// the mode the program was invoked in. tar's `-f` is the archive that
  /// create/append/update write and extract/list read, and its `-C` is the
  /// directory members are read from on create and written into on extract.
  /// The value is recorded here so it does not land on the operand side; the
  /// effects layer is what gives it a direction.
  Path
  /// Takes a value that is a directory; file operands are written inside it.
  TargetDir
  /// Optional value that must be attached (`-iSUF`, `--long=SUF`); on its own
  /// it does not consume the next token. The value is not a path.
  Attached
} derive(Debug, Eq)

///|
pub(all) struct OptSpec {
  name : String
  val : OptVal
} derive(Debug, Eq)

///|
pub(all) struct ProgOpts {
  specs : Array[OptSpec]
  /// Options that send the output to stdout: the operands stay read-only
  /// instead of being rewritten in place (gzip -c).
  to_stdout : Array[String]
  /// Options that carry the pattern/script, so the first operand is no longer
  /// a pattern but a file (grep -f, sed -e).
  from_option : Array[String]
} derive(Debug, Eq)

///|
fn opt(name : String, val : OptVal) -> OptSpec {
  { name, val, }
}

///|
fn prog(
  specs : Array[OptSpec],
  to_stdout? : Array[String] = [],
  from_option? : Array[String] = [],
) -> ProgOpts {
  { specs, to_stdout, from_option, }
}

///|
/// The table. Programs absent from it keep the old "starts with a dash" split,
/// so adding a row is the only way behaviour changes.
pub fn opts_of(n : String) -> ProgOpts {
  match n {
    // sort -o writes, -k/-t take numbers or separators. Measured with the
    // shim: `sort -o out.txt in.txt` -> R:in.txt W:out.txt in all three
    // spellings, `sort -k 2 data.txt` -> R:data.txt.
    "sort" =>
      prog([
        opt("-k", NotPath),
        opt("--key", NotPath),
        opt("-t", NotPath),
        opt("--field-separator", NotPath),
        opt("-o", WritePath),
        opt("--output", WritePath),
      ])
    // head -n 5 / head -n5 / head --lines=5 -> R:data.txt only.
    "head" =>
      prog([
        opt("-n", NotPath),
        opt("--lines", NotPath),
        opt("-c", NotPath),
        opt("--bytes", NotPath),
      ])
    // tail -n 5 / -c 3 / -s 1; all numbers, none a path.
    "tail" =>
      prog([
        opt("-n", NotPath),
        opt("--lines", NotPath),
        opt("-c", NotPath),
        opt("--bytes", NotPath),
        opt("-s", NotPath),
        opt("--sleep-interval", NotPath),
      ])
    // diff -U 3 a.txt b.txt -> R:a.txt R:b.txt; the 3 is not touched.
    "diff" =>
      prog([
        opt("-U", NotPath),
        opt("--unified", NotPath),
        opt("-C", NotPath),
        opt("--context", NotPath),
      ])
    // cut -d ' ' -f 2 -> R:data.txt; neither the space nor the 2 is a path.
    "cut" =>
      prog([
        opt("-d", NotPath),
        opt("--delimiter", NotPath),
        opt("-f", NotPath),
        opt("--fields", NotPath),
        opt("-c", NotPath),
        opt("--characters", NotPath),
        opt("-b", NotPath),
        opt("--bytes", NotPath),
      ])
    // uniq -f 1 / -s 1 / -w 2 -> R:data.txt.
    "uniq" =>
      prog([
        opt("-f", NotPath),
        opt("--skip-fields", NotPath),
        opt("-s", NotPath),
        opt("--skip-chars", NotPath),
        opt("-w", NotPath),
        opt("--check-chars", NotPath),
      ])
    // join has short options only: --join-field does not exist (measured:
    // `join --join-field=1` is rejected). -1/-2/-j/-o/-t all take numbers or
    // separators; `join -1 1 -2 1 a.txt b.txt` -> R:a.txt R:b.txt.
    "join" =>
      prog([
        opt("-1", NotPath),
        opt("-2", NotPath),
        opt("-j", NotPath),
        opt("-o", NotPath),
        opt("-t", NotPath),
      ])
    // grep -f pats.txt data.txt -> R:pats.txt R:data.txt; --file=... same.
    // -e also means the pattern is not an operand, so `grep -e foo data.txt`
    // must report R:data.txt instead of dropping it as "the pattern".
    "grep" =>
      prog(
        [
          opt("-f", ReadPath),
          opt("--file", ReadPath),
          opt("-e", NotPath),
          opt("--regexp", NotPath),
          opt("-m", NotPath),
          opt("--max-count", NotPath),
          opt("-A", NotPath),
          opt("--after-context", NotPath),
          opt("-B", NotPath),
          opt("--before-context", NotPath),
          opt("-C", NotPath),
          opt("--context", NotPath),
        ],
        from_option=["-f", "--file", "-e", "--regexp"],
      )
    // rg shares grep's shape: -f/--file reads a pattern file, and the other
    // values (context counts, type/glob filters, replacement text) are not
    // paths. Measured: `rg -A 2 foo data.txt` -> R:data.txt, `rg -f pats.txt
    // data.txt` -> R:pats.txt R:data.txt.
    "rg" =>
      prog(
        [
          opt("-f", ReadPath),
          opt("--file", ReadPath),
          opt("-e", NotPath),
          opt("--regexp", NotPath),
          opt("-m", NotPath),
          opt("--max-count", NotPath),
          opt("-A", NotPath),
          opt("--after-context", NotPath),
          opt("-B", NotPath),
          opt("--before-context", NotPath),
          opt("-C", NotPath),
          opt("--context", NotPath),
          opt("-t", NotPath),
          opt("--type", NotPath),
          opt("-g", NotPath),
          opt("--glob", NotPath),
          opt("-j", NotPath),
          opt("--threads", NotPath),
          opt("-r", NotPath),
          opt("--replace", NotPath),
        ],
        from_option=["-f", "--file", "-e", "--regexp"],
      )
    // awk -f prog.awk in.txt -> R:prog.awk R:in.txt. -v and -F take
    // assignments / separators (`awk -v x=1`, `awk -F:`).
    "awk" =>
      prog(
        [
          opt("-f", ReadPath),
          opt("--file", ReadPath),
          opt("-v", NotPath),
          opt("--assign", NotPath),
          opt("-F", NotPath),
          opt("--field-separator", NotPath),
        ],
        from_option=["-f", "--file"],
      )
    // sed -f script.sed data.txt -> R:script.sed R:data.txt.
    // sed -i.bak 's/a/b/' data.txt -> W:data.txt W:data.txt.bak; the suffix
    // must be attached (`sed -i .bak ...` treats .bak as the script).
    "sed" =>
      prog(
        [
          opt("-f", ReadPath),
          opt("--file", ReadPath),
          opt("-e", NotPath),
          opt("--expression", NotPath),
          opt("-i", Attached),
          opt("--in-place", Attached),
        ],
        from_option=["-f", "--file", "-e", "--expression"],
      )
    // cp/mv/install/ln -t DIR: operands go inside DIR under their basename.
    // `cp -t destdir sub/a.txt` -> W:destdir/a.txt, and `-t destdir/` does not
    // double the slash. mv deletes the source instead of reading it.
    // -S/--suffix is a suffix string, not a path (`ln -S .bak a.txt b.txt`
    // creates b.txt.bak); --backup takes an optional attached control word.
    "cp" =>
      prog([
        opt("-t", TargetDir),
        opt("--target-directory", TargetDir),
        opt("-S", NotPath),
        opt("--suffix", NotPath),
        opt("--backup", Attached),
      ])
    "mv" =>
      prog([
        opt("-t", TargetDir),
        opt("--target-directory", TargetDir),
        opt("-S", NotPath),
        opt("--suffix", NotPath),
        opt("--backup", Attached),
      ])
    "install" =>
      prog([
        opt("-t", TargetDir),
        opt("--target-directory", TargetDir),
        opt("-m", NotPath),
        opt("--mode", NotPath),
        opt("-o", NotPath),
        opt("--owner", NotPath),
        opt("-g", NotPath),
        opt("--group", NotPath),
        opt("-S", NotPath),
        opt("--suffix", NotPath),
        opt("--backup", Attached),
      ])
    "ln" =>
      prog([
        opt("-t", TargetDir),
        opt("--target-directory", TargetDir),
        opt("-S", NotPath),
        opt("--suffix", NotPath),
        opt("--backup", Attached),
      ])
    // chmod --reference=ref.txt d.txt -> stat ref.txt, write d.txt. Same for
    // chown/chgrp (measured as the owner changing the group).
    "chmod" | "chown" | "chgrp" => prog([opt("--reference", ReadPath)])
    // touch -r ref.txt data.txt -> stat ref.txt, write data.txt; -d/-t take a
    // timestamp, not a path.
    "touch" =>
      prog([
        opt("-r", ReadPath),
        opt("--reference", ReadPath),
        opt("-d", NotPath),
        opt("--date", NotPath),
        opt("-t", NotPath),
      ])
    // truncate -r ref.txt data.txt -> stat ref.txt, write data.txt; -s takes a
    // size.
    "truncate" =>
      prog([
        opt("-r", ReadPath),
        opt("--reference", ReadPath),
        opt("-s", NotPath),
        opt("--size", NotPath),
      ])
    // tar's operation letter decides what its arguments mean: create, append
    // and update write the archive that -f names, extract writes into -C, and
    // list only reads. -f and -C are therefore recorded as plain paths whose
    // direction the effects layer gives them.
    //
    // The operation letters are listed so mode detection reads option names
    // instead of matching substrings: the old `letters.contains("c")` over
    // concatenated raw text read `--create` as create by accident, and would
    // have read `--checkpoint` the same way.
    //
    // --exclude and -X/--exclude-from are here because their values are not
    // paths (a pattern) or are paths of their own (a pattern list); without
    // the rows `--exclude zz dir` reported `zz` as a member tar reads.
    "tar" =>
      prog([
        opt("-f", Path),
        opt("--file", Path),
        opt("-C", Path),
        opt("--directory", Path),
        opt("--exclude", NotPath),
        opt("-X", ReadPath),
        opt("--exclude-from", ReadPath),
        opt("-c", NoVal),
        opt("-r", NoVal),
        opt("-u", NoVal),
        opt("-x", NoVal),
        opt("-t", NoVal),
        opt("-A", NoVal),
        opt("--create", NoVal),
        opt("--append", NoVal),
        opt("--update", NoVal),
        opt("--extract", NoVal),
        opt("--get", NoVal),
        opt("--list", NoVal),
        opt("--catenate", NoVal),
        opt("--concatenate", NoVal),
      ])
    // Compressors: -c/--stdout means the operand is only read, nothing is
    // written (snapshot: `gzip -c f.txt` leaves f.txt and adds no file).
    // gzip/xz -S/--suffix is a suffix, not a path.
    //
    // -d/--decompress is the other direction (gunzip/bunzip2/unxz/unzstd are
    // that mode under another name), -k/--keep leaves the source in place,
    // -t/--test and -l/--list only read, and -r/--recursive derives its
    // products from directory entries rather than from the operand.
    "gzip" =>
      prog(
        [
          opt("-c", NoVal),
          opt("--stdout", NoVal),
          opt("-S", NotPath),
          opt("--suffix", NotPath),
          opt("-d", NoVal),
          opt("--decompress", NoVal),
          opt("--uncompress", NoVal),
          opt("-k", NoVal),
          opt("--keep", NoVal),
          opt("-t", NoVal),
          opt("--test", NoVal),
          opt("-l", NoVal),
          opt("--list", NoVal),
          opt("-r", NoVal),
          opt("--recursive", NoVal),
        ],
        to_stdout=["-c", "--stdout"],
      )
    "bzip2" =>
      prog(
        [
          opt("-c", NoVal),
          opt("--stdout", NoVal),
          opt("-d", NoVal),
          opt("--decompress", NoVal),
          opt("-k", NoVal),
          opt("--keep", NoVal),
          opt("-t", NoVal),
          opt("--test", NoVal),
        ],
        to_stdout=["-c", "--stdout"],
      )
    // xz -T/--threads takes a count in both spellings (`xz -T 2 f.txt` and
    // `xz --threads 2 f.txt`, measured: `2` is never a path).
    "xz" =>
      prog(
        [
          opt("-c", NoVal),
          opt("--stdout", NoVal),
          opt("-S", NotPath),
          opt("--suffix", NotPath),
          opt("-d", NoVal),
          opt("--decompress", NoVal),
          opt("--uncompress", NoVal),
          opt("-k", NoVal),
          opt("--keep", NoVal),
          opt("-t", NoVal),
          opt("--test", NoVal),
          opt("-l", NoVal),
          opt("--list", NoVal),
          opt("-T", NotPath),
          opt("--threads", NotPath),
        ],
        to_stdout=["-c", "--stdout"],
      )
    // zstd -T is attached-only (measured: `zstd -T 2 f.txt` reads `2` as an
    // input file and fails), while --threads also takes a separate count.
    "zstd" =>
      prog(
        [
          opt("-c", NoVal),
          opt("--stdout", NoVal),
          opt("-d", NoVal),
          opt("--decompress", NoVal),
          opt("--uncompress", NoVal),
          opt("-k", NoVal),
          opt("--keep", NoVal),
          opt("-t", NoVal),
          opt("--test", NoVal),
          opt("-l", NoVal),
          opt("--list", NoVal),
          opt("--rm", NoVal),
          opt("-T", Attached),
          opt("--threads", NotPath),
        ],
        to_stdout=["-c", "--stdout"],
      )
    _ => prog([])
  }
}

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
  let base = basename_of(file)
  if base == "" {
    dir
  } else if dir.has_suffix("/") {
    dir + base
  } else {
    dir + "/" + base
  }
}

///|
/// Last path segment: `sub/a.txt` -> `a.txt`, `a.txt/` -> `a.txt`, `/` -> ``.
fn basename_of(p : String) -> String {
  let mut end = p.length()
  while end > 0 && p.unsafe_substring(start=end - 1, end~) == "/" {
    end -= 1
  }
  let trimmed = p.unsafe_substring(start=0, end~)
  match trimmed.rev_find("/") {
    Some(i) => trimmed.unsafe_substring(start=i + 1, end=trimmed.length())
    None => trimmed
  }
}
