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
