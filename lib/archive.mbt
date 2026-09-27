///|
/// The archive programs: `tar` and the compressors.
///
/// Both decide what they touch from their own option letters rather than from a
/// plain operand list, so they get their own scan instead of the generic one.
/// Every line below was measured against the real binary; see the comments on
/// each function for what was run and what came back.

///|
/// The value of `-f`/`-C` when a tar command writes them without a dash, and
/// the words left over for the members. In the old-style form the values are
/// the words after the cluster, taken in the order their letters appear:
/// `tar cf out dir` and `tar xfC in.tgz dest`.
fn tar_take_cluster_values(
  cluster : String,
  args : Array[PathArg],
) -> (PathArg?, PathArg?, Array[PathArg]) {
  let mut archive : PathArg? = None
  let mut dir : PathArg? = None
  let mut i = 0
  for k in 0..<cluster.length() {
    match cluster.get_char(k) {
      Some('f') =>
        if i < args.length() {
          archive = Some(args[i])
          i += 1
        }
      Some('C') =>
        if i < args.length() {
          dir = Some(args[i])
          i += 1
        }
      _ => ()
    }
  }
  (archive, dir, args[i:].to_owned())
}

///|
/// The operation letters a tar command carries, gathered from both spellings:
/// the dashed options through the option table, and the old-style cluster.
/// Only whole option names map to a letter here. The old code folded the raw
/// flag text into one string and tested it with `contains`, so `--create` read
/// as the letter `c` on purpose and `--exclude` would have read as extract.
fn tar_operation_letters(scan : ArgScan, cluster : String) -> String {
  let sb = StringBuilder()
  for o in scan.opts {
    match o {
      "-c" | "-r" | "-u" | "-x" | "-t" | "-A" =>
        sb.write_string(o.unsafe_substring(start=1, end=2))
      "--create" => sb.write_string("c")
      "--append" => sb.write_string("r")
      "--update" => sb.write_string("u")
      "--extract" | "--get" => sb.write_string("x")
      "--list" => sb.write_string("t")
      "--catenate" | "--concatenate" => sb.write_string("A")
      _ => ()
    }
  }
  sb.write_string(cluster)
  sb.to_string()
}

///|
/// tar's old-style form writes its options without a dash, and only in the
/// first argument. That is tar's own rule, not a guess: measured, `tar dir`
/// and `tar abc` both make GNU tar read the word as options (`old option 'b'
/// requires an argument`). What used to be wrong was where this tool applied
/// it: to the first leftover *operand*, where the `out` that `-f` consumes
/// looked like a cluster and the real member `dir` looked like the archive.
fn tar_old_style_word(items : Array[PathArg]) -> String? {
  match items {
    [head, ..] =>
      if head.text.length() > 0 &&
        !head.text.has_prefix("-") &&
        head.text.to_string().all(fn(c) { c.is_ascii_alphabetic() }) {
        Some(head.text)
      } else {
        None
      }
    [] => None
  }
}

///|
/// The letters of an old-style cluster this tool can account for. tar's short
/// options are `AcdrtuxGnSkUWOmpsMBiajJzZhPlRvwo` plus the thirteen that take
/// a value, `bCfFgHIKLNTVX` (from `tar --usage`). Everything listed here takes
/// no value or is one of the two value letters modelled above (`f`, `C`), so a
/// cluster made of them splits exactly. `d` (--diff) is an operation this tool
/// does not model and is left out; so are the value letters it cannot place,
/// because a cluster with one of those cannot be split into options and
/// operands without guessing (`tar ab` says "old option 'b' requires an
/// argument").
fn tar_cluster_letters() -> String {
  "AcrtuxGnSkUWOmpsMBiajJzZhPlRvwofC"
}

///|
/// tar does three different things depending on its operation letter, and it
/// writes somewhere different in each: create, append and update write the
/// archive, extract writes into -C (or the cwd), list only reads.
///
/// Measured with the shim:
///
/// - `tar -czf out dir` creates `out` and opens `dir`
/// - `tar --create --file=arc.tar dir` creates `arc.tar`
/// - `tar rf arc.tar new.txt` opens `arc.tar` for writing, reads `new.txt`
/// - `tar czf - dir` creates no file: the archive is stdout
/// - `tar xzf in.tgz -C out` opens `in.tgz`, writes inside `out`
/// - `tar tf arc.tar` only opens `arc.tar`
/// - `tar --help`, `tar --version`, `tar -f a.tar` and `tar` open nothing
fn Collector::tar_effects(
  self : Collector,
  scan : ArgScan,
  items : Array[PathArg],
  operands : Array[PathArg],
  flags : Array[String],
  line : Int,
) -> Unit {
  if flags.contains("--help") || flags.contains("--version") {
    return
  }
  let mut cluster = ""
  let mut args = operands
  let mut cluster_archive : PathArg? = None
  let mut cluster_dir : PathArg? = None
  match tar_old_style_word(items) {
    Some(w) => {
      if !w.to_string().all(fn(c) { tar_cluster_letters().contains_char(c) }) {
        self.push(
          Unknown,
          "tar: old-style option cluster not modelled",
          true,
          line,
        )
        return
      }
      cluster = w
      if operands.length() > 0 {
        args = operands[1:].to_owned()
      }
      // A bare `-` is the archive on stdout (`tar czf - dir`). The option
      // scanner reads it as a flag, so it is missing from `operands`, and the
      // cluster's value letters have to see it where it was written.
      if flags.contains("-") {
        let merged : Array[PathArg] = [PathArg::lit("-")]
        for it in args {
          merged.push(it)
        }
        args = merged
      }
      let (a, d, rest) = tar_take_cluster_values(cluster, args)
      cluster_archive = a
      cluster_dir = d
      args = rest
    }
    None => ()
  }
  let letters = tar_operation_letters(scan, cluster)
  let archive_written = letters.contains("c") ||
    letters.contains("r") ||
    letters.contains("u") ||
    letters.contains("A")
  let listing = letters.contains("t")
  let extracting = letters.contains("x")
  if !archive_written && !listing && !extracting {
    // Measured: `tar -f a.tar` and `tar` exit 2 without opening anything
    // ("you must specify one of -Acdtrux").
    self.push(Unknown, "tar: no operation letter was given", true, line)
    return
  }
  let archive = match value_entry_of(scan, ["-f", "--file"]) {
    Some(v) => Some(v.to_path_arg())
    None => cluster_archive
  }
  let dir = match value_entry_of(scan, ["-C", "--directory"]) {
    Some(v) => Some(v.to_path_arg())
    None => cluster_dir
  }
  if archive_written {
    match archive {
      Some(a) => if a.text != "-" { self.push_path(Write, a, line) }
      None =>
        self.push(
          Unknown,
          "tar: the archive name is not on the command line",
          true,
          line,
        )
    }
    for it in args {
      self.push_path(Read, it, line)
    }
  } else if listing {
    // The operands of a list run are member names inside the archive, not
    // paths on disk, so only the archive itself is read.
    match archive {
      Some(a) => if a.text != "-" { self.push_path(Read, a, line) }
      None => ()
    }
  } else {
    match dir {
      Some(d) => self.push_path(Write, d, line)
      None =>
        self.push(
          Unknown,
          "tar: extraction point is the working directory",
          true,
          line,
        )
    }
    match archive {
      Some(a) => if a.text != "-" { self.push_path(Read, a, line) }
      None => ()
    }
  }
}

///|
/// The suffixes a compressor appends, and the ones it strips when
/// decompressing. Measured: each is a plain string glued to the whole operand,
/// path prefix and all (`gzip sub/f.txt` writes `sub/f.txt.gz`), and zstd also
/// reads back `.zstd`.
fn compressor_suffixes(n : String, decompress : Bool) -> Array[String] {
  match n {
    "gzip" | "gunzip" => [".gz"]
    "bzip2" | "bunzip2" => [".bz2"]
    "xz" | "unxz" => [".xz"]
    "zstd" | "unzstd" => if decompress { [".zst", ".zstd"] } else { [".zst"] }
    _ => []
  }
}

///|
fn strip_suffix(t : String, suffixes : Array[PathArg]) -> String? {
  for it in suffixes {
    let s = it.text
    if s.length() > 0 && t.has_suffix(s) && t.length() > s.length() {
      return Some(t.unsafe_substring(start=0, end=t.length() - s.length()))
    }
  }
  None
}

///|
fn any_dynamic(xs : Array[PathArg]) -> Bool {
  xs.any(fn(it) { it.dynamic })
}

///|
/// What a compressor does to each of its operands.
///
/// Every line here is measured with the shim over the real binary in a scratch
/// directory:
///
/// - `gzip f.txt`: opens f.txt, creates f.txt.gz, unlinks f.txt
/// - `gzip -k f.txt` / `--keep`: the same, without the unlink
/// - `gzip -c f.txt`: opens f.txt only, nothing lands on disk
/// - `gunzip f.txt.gz`: opens it, creates f.txt, unlinks f.txt.gz
/// - `gzip -t f.txt.gz` / `-l`: opens it only
/// - `gzip -S .zz f.txt` writes f.txt.zz, `gunzip -S .GZ f.txt.GZ` writes f.txt
/// - `xz f.txt`, `bzip2 f.txt`: the same shape, products .xz / .bz2
/// - `zstd f.txt`: product f.txt.zst and the source STAYS in place (zstd's
///   default; only --rm removes it), and `zstd f.txt.zst` makes f.txt.zst.zst
/// - `gzip -r sub`: the products are the entries inside sub
///
/// Before this, `gzip f.txt` reported `R:f.txt W:f.txt`: a write to a file the
/// program never writes, and no sign of the file it does write or of the
/// source it removes.
fn Collector::compressor_effects(
  self : Collector,
  n : String,
  scan : ArgScan,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  let decompress = match n {
    "gunzip" | "bunzip2" | "unxz" | "unzstd" => true
    _ =>
      scan.opts.any(fn(o) {
        o == "-d" || o == "--decompress" || o == "--uncompress"
      })
  }
  // -c, -t and -l never write a file next to the operand. Measured: `gzip -t
  // f.txt.gz`, `gzip -l f.txt.gz`, `xz -l f.txt.xz`, `zstd -l f.txt.zst` and
  // `bzip2 -t f.txt.bz2` only open the operand.
  let read_only = scan.to_stdout ||
    scan.opts.any(fn(o) {
      o == "-t" || o == "--test" || o == "-l" || o == "--list"
    })
  let recursive = scan.opts.any(fn(o) { o == "-r" || o == "--recursive" })
  // zstd keeps its input unless --rm; the others remove it unless -k/--keep.
  let removes_source = if n == "zstd" || n == "unzstd" {
    scan.opts.contains("--rm")
  } else {
    !scan.opts.any(fn(o) { o == "-k" || o == "--keep" })
  }
  let suffixes : Array[PathArg] = match
    value_entry_of(scan, ["-S", "--suffix"]) {
    Some(v) => if v.text != "" { [v.to_path_arg()] } else { [] }
    None => {
      let out : Array[PathArg] = []
      for s in compressor_suffixes(n, decompress) {
        out.push(PathArg::lit(s))
      }
      out
    }
  }
  for it in operands {
    let t = it.text
    self.push_path(Read, it, line)
    if read_only || recursive || suffixes.length() == 0 {
      continue
    }
    if decompress {
      // A name that carries none of the suffixes has no product this tool can
      // name, and gzip refuses it ("unknown suffix -- ignored"), so only the
      // read is reported.
      match strip_suffix(t, suffixes) {
        Some(base) => {
          // The derived name is the operand with its suffix removed: same head,
          // same variables, and the suffixes' own holes matter too.
          let product : PathArg = {
            text: base,
            dynamic: it.dynamic || any_dynamic(suffixes),
            unrooted: it.unrooted,
            vars: it.vars,
            origin: it.origin,
          }
          self.push_path(Write, product, line)
          if removes_source {
            self.push_path(Delete, it, line)
          }
        }
        None => ()
      }
    } else {
      let first_suffix = suffixes[0]
      let suffix = first_suffix.text
      let sd = first_suffix.dynamic
      // Measured: gzip, xz and bzip2 leave a name that already carries their
      // suffix alone ("already has .gz suffix"), while zstd happily makes
      // f.txt.zst.zst.
      let already = (n != "zstd" && n != "unzstd") && t.has_suffix(suffix)
      if !already {
        self.push_path(
          Write,
          {
            text: t + suffix,
            dynamic: it.dynamic || sd,
            unrooted: it.unrooted,
            vars: it.vars,
            origin: it.origin,
          },
          line,
        )
        if removes_source {
          self.push_path(Delete, it, line)
        }
      }
    }
  }
  if recursive {
    self.push(
      Unknown,
      n + " -r: the products are the entries inside each directory",
      true,
      line,
    )
  }
}
