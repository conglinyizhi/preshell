///|
/// Which program does what: the dispatcher that turns a command word into
/// effects.
///
/// Each entry is a claim about one program or one family of them, and the entry
/// exists only when the behaviour was measured or read off the program's own
/// documentation. A program with no entry falls through to the generic operand
/// model, and one whose behaviour is unbounded is reported unmodelled rather
/// than guessed at — saying "we do not model this" is a fact, and it is the one
/// that keeps the effect list from reading as complete when it is not.
///
/// The scanning helpers at the bottom (`leading_operands`, `flag_value`,
/// `drop_flag_value`, `has_flag_text`) are deliberately coarse: modelling how
/// every program parses its own arguments is a project of its own, and getting
/// it wrong is the main source of false paths.

///|
fn Collector::classify(
  self : Collector,
  n : String,
  s : SimpleCmd,
  line : Int,
) -> Unit { // A wrapper runs the program it is handed, so that program is the real
  // subject of the report: `env rm -rf x` deletes x, and reporting only "env
  // ran, unmodelled" says nothing about it.
  match wrapper_target(n, s.words) {
    Some(target) => {
      self.wrapper_effects(n, s, target, line)
      return
    }
    None => ()
  }
  // Programs whose effect is decided by a flag or a subcommand rather than by
  // an operand list get their own branch (lib/tools.mbt). Each one returns
  // early: mixing them with the operand model would invent paths.
  match n {
    "find" => {
      self.find_effects(s, line)
      return
    }
    "sqlite3" => {
      self.sqlite_effects(s, line)
      return
    }
    "make" | "gmake" => {
      self.make_effects(s, line)
      return
    }
    "docker" | "podman" => {
      self.container_effects(n, s, line)
      return
    }
    // A delegation (`uv run CMD`, `npx CMD`, `cargo run`) is its own fact:
    // the command line hands control to a program whose own language decides
    // what happens, and that is out of scope rather than half-modelled.
    // Package managers first: when `uv`/`npm` is *not* delegating, the
    // measured table still applies to what is left.
    "uv" | "pip" | "pip3" | "npm" | "pnpm" | "yarn" | "bun" => {
      if self.runner_effects(n, s, line) {
        return
      }
      self.package_effects(n, s, line)
      return
    }
    // Runners only: not delegating means we do not model them at all
    // (`go test`, `cargo build`), which the generic path below reports.
    "poetry"
    | "pdm"
    | "pipx"
    | "npx"
    | "bunx"
    | "go"
    | "cargo"
    | "dotnet"
    | "deno"
    | "conda" => if self.runner_effects(n, s, line) { return }
    _ => ()
  }
  // git gets its own table (lib/git.mbt): which paths a subcommand touches is
  // a measured fact per subcommand, not something to derive from operands, and
  // a subcommand we do not model has to come back unmodelled rather than
  // half-modelled.
  if n == "git" {
    self.git_effects(s, line)
    return
  }
  let items = arg_items(s)
  // Option values are the table's business (lib/opts.mbt): an option that
  // consumes a value must not leave it on the operand side. Programs without
  // a table keep the old "starts with a dash" split exactly.
  let po = opts_of(n)
  let scan = if has_table(po) {
    scan_args(po, items)
  } else {
    scan_legacy(items)
  }
  let flags = scan.flags
  let operands = scan.operands
  // The first operand of grep/awk/sed is a pattern or a script, unless the
  // pattern came from -f/-e; then every operand is a file.
  let script_operands = if scan.from_option {
    operands
  } else if operands.length() > 1 {
    operands[1:].to_owned()
  } else {
    []
  }
  // `find -exec` runs another program, so the whole command goes opaque:
  // reporting the directory it walks would miss the command it runs.
  let runs_another = flags.any(fn(f) {
    f == "-exec" ||
    f == "-execdir" ||
    f == "-ok" ||
    f == "-okdir" ||
    f == "-delete"
  })
  // `-c` recursion only makes sense for shells: a Python `-c` string is
  // Python, and parsing it as shell would invent commands that never run.
  let recurses = (is_shell(n) && has_flag_text(flags, "-c")) || n == "eval"
  // Which programs this tool claims to understand. Anything else runs, and
  // what it touches is decided inside it: that is reported as unmodelled, and
  // it is what keeps this from being an unbounded enumeration problem.
  let modeled = !runs_another &&
    (
      is_pure(n) ||
      is_path_modeled(n) ||
      is_network_modeled(n) ||
      recurses ||
      n == "cd"
    )
  self.push(
    Exec,
    n,
    false,
    line,
    modeled~,
    origin=words_origin(s.words),
    // The words after the program are what it reads its source from. A command
    // word that was substituted in has its args in the same list, so this works
    // for `x=python3; $x -c …` too.
    payload=self.payload_for(n, s.words[1:], s.redirects),
  )
  if !modeled {
    // Nothing else can be said about it, and saying nothing would read as
    // "touches nothing".
    return
  }
  // A value the table says is a path counts in the direction it was given:
  // sort -o writes its value, grep -f reads it, cp -t only names a directory.
  for v in scan.values {
    match v.val {
      ReadPath | TargetDir => self.push(Read, v.text, v.dynamic, line)
      WritePath => self.push(Write, v.text, v.dynamic, line)
      _ => ()
    }
  }
  let writes = fn(xs : Array[PathArg]) {
    for it in xs {
      self.push_path(Write, it, line)
    }
  }
  let reads = fn(xs : Array[PathArg]) {
    for it in xs {
      self.push_path(Read, it, line)
    }
  }
  match n {
    "rm" | "rmdir" | "unlink" | "shred" =>
      for it in operands {
        self.push_path(Delete, it, line)
      }
    "cat"
    | "head"
    | "tail"
    | "less"
    | "more"
    | "sort"
    | "wc"
    | "diff"
    | "source"
    | "."
    | "stat"
    | "file"
    | "readlink"
    | "md5sum"
    | "sha256sum"
    | "base64"
    | "strings"
    | "xxd"
    | "cut"
    | "uniq"
    | "comm"
    | "join"
    | "paste"
    | "expand"
    | "fold"
    | "nl"
    | "od"
    | "ls"
    | "du"
    | "df"
    | "tree"
    | "realpath" => reads(operands)
    "find" =>
      // Predicates are not paths: only the starting points are.
      reads(leading_operands(items))
    "grep" | "rg" | "awk" | "sed" => {
      let in_place = n == "sed" &&
        (scan.opts.contains("-i") || scan.opts.contains("--in-place"))
      if in_place {
        writes(script_operands)
        // `sed -i.bak 's/a/b/' data.txt` also writes data.txt.bak. The suffix
        // has to be attached; a bare -i makes no backup.
        match value_of(scan, ["-i", "--in-place"]) {
          Some(suffix) =>
            for it in script_operands {
              self.push_path(Write, it.plus_suffix(suffix), line)
            }
          None => ()
        }
      } else {
        reads(script_operands)
      }
    }
    "tee" | "touch" | "truncate" | "mkdir" => writes(operands)
    "chmod" | "chown" | "chgrp" => {
      // The first operand is the mode, the owner or the group; the rest are
      // files. With --reference the mode/owner comes from an option, so every
      // operand is a file. Reporting `644` as a written path is the kind of
      // invented fact that makes a report untrustworthy.
      let files = if scan.opts.contains("--reference") {
        operands
      } else if operands.length() > 1 {
        operands[1:].to_owned()
      } else {
        []
      }
      writes(files)
    }
    "ln" =>
      match scan.target_dir {
        // `ln -t dir a`: the link is created inside dir, under the basename.
        // The directory's own hole (or its glob) makes the link dynamic.
        Some(dir) =>
          for it in operands {
            self.push_path(Read, it, line)
            self.push_path(Write, it.in_dir(dir), line)
          }
        // `ln target link`: the last operand is what gets created.
        None =>
          if operands.length() > 0 {
            let n_op = operands.length()
            for i, it in operands {
              if i == n_op - 1 {
                self.push_path(Write, it, line)
              } else {
                self.push_path(Read, it, line)
              }
            }
          }
      }
    "split" | "csplit" => {
      // The input is read; the outputs are named by the tool (xaa, xab, ...),
      // which is not something this table can derive.
      reads(operands)
      if operands.length() > 0 {
        self.push(Unknown, n + ": output file names are derived", true, line)
      }
    }
    "cp" | "mv" | "install" | "rsync" =>
      match scan.target_dir {
        // `cp -t dir a b` writes dir/a and dir/b. mv removes the sources
        // instead of reading them (measured: D:a.txt W:destdir/a.txt).
        // The directory's own hole (or its glob) makes the write dynamic.
        Some(dir) =>
          for it in operands {
            if n == "mv" {
              self.push_path(Delete, it, line)
            } else {
              self.push_path(Read, it, line)
            }
            self.push_path(Write, it.in_dir(dir), line)
          }
        None => {
          let n_op = operands.length()
          for i, it in operands {
            if i == n_op - 1 {
              self.push_path(Write, it, line)
            } else {
              self.push_path(Read, it, line)
            }
          }
        }
      }
    "zip" =>
      // `zip archive.zip members...`: the archive is written, the members read.
      match operands {
        [head, .. rest] => {
          self.push_path(Write, head, line)
          for it in rest {
            self.push_path(Read, it, line)
          }
        }
        [] => ()
      }
    "gzip"
    | "gunzip"
    | "bzip2"
    | "bunzip2"
    | "xz"
    | "unxz"
    | "zstd"
    | "unzstd" => self.compressor_effects(n, scan, operands, line)
    "dd" =>
      for it in items {
        let t = it.text
        if t.has_prefix("of=") {
          let value = t.unsafe_substring(start=3, end=t.length())
          self.push(
            Write,
            value,
            it.dynamic,
            line,
            unrooted=value_head_unresolved(value, it.dynamic),
            vars=it.vars,
          )
        }
        if t.has_prefix("if=") {
          let value = t.unsafe_substring(start=3, end=t.length())
          self.push(
            Read,
            value,
            it.dynamic,
            line,
            unrooted=value_head_unresolved(value, it.dynamic),
            vars=it.vars,
          )
        }
      }
    "tar" => self.tar_effects(scan, items, operands, flags, line)
    "unzip" => {
      let dest = flag_value(items, ["-d"])
      match dest {
        Some(d) => self.push(Write, d, false, line)
        None =>
          self.push(
            Unknown,
            "unzip: extraction point is the working directory",
            true,
            line,
          )
      }
      reads(drop_flag_value(operands, dest))
    }
    "curl"
    | "wget"
    | "nc"
    | "ncat"
    | "ssh"
    | "scp"
    | "sftp"
    | "telnet"
    | "ping"
    | "dig" => {
      for it in items {
        let t = it.text
        if t.has_prefix("http://") ||
          t.has_prefix("https://") ||
          t.has_prefix("git@") {
          self.push(Net, t, false, line)
        }
      }
      if n == "curl" || n == "wget" {
        match flag_value(items, ["-o", "-O", "--output", "--output-document"]) {
          Some(o) => self.push(Write, o, false, line)
          None => ()
        }
      }
      // A host argument is also something leaving the machine, and it does not
      // start with http. For the file-transfer tools the host is the operand
      // carrying a colon or an at-sign; for the rest, the first operand.
      if n == "scp" || n == "sftp" {
        for it in operands {
          if it.text.contains(":") || it.text.contains("@") {
            self.push(Net, it.text, it.dynamic, line)
          }
        }
      } else if n == "ssh" ||
        n == "telnet" ||
        n == "ping" ||
        n == "dig" ||
        n == "nc" ||
        n == "ncat" {
        match operands {
          [head, ..] => self.push(Net, head.text, head.dynamic, line)
          [] => ()
        }
      }
    }
    "cd" => {
      // `cd` is not an effect on a file, it is a change to how every later
      // relative path in this command line reads. Track it, and say so when
      // the destination cannot be worked out.
      let dest : String? = match operands {
        [first, ..] =>
          // A destination that is a hole (`$DIR`) or an expansion (`~`) is not
          // a directory this tool can name, so the base becomes unknown.
          if first.dynamic || first.unrooted {
            None
          } else {
            Some(first.text)
          }
        [] => None
      }
      self.change_dir(dest, line)
    }
    _ => if recurses { self.recurse_static(s, n, line) }
  }
  // Only the operands this command treats as paths get the hole check;
  // otherwise a pattern like `-name "*.mbt"` is reported as an unknown path.
  let checked = match n {
    "grep" | "rg" | "awk" | "sed" => script_operands
    "find" => leading_operands(items)
    _ => operands
  }
  for it in checked {
    if it.dynamic && !it.text.has_prefix("-") {
      // The same operand the path effects already reported, so it carries the
      // same variables: one unresolved path, one set of names.
      self.push_path(Unknown, it, line)
    }
  }
}

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
/// `eval "..."` and `sh -c "..."` with a static string: the string is a real
/// command line, so it gets parsed and folded into the same summary.
fn Collector::recurse_static(
  self : Collector,
  s : SimpleCmd,
  n : String,
  line : Int,
) -> Unit {
  if self.depth >= 4 {
    self.push(Unknown, "eval depth limit", true, line)
    return
  }
  match eval_script(s, n) {
    Some(script) => {
      // A shell named on the command line decides the inner grammar; `eval`
      // keeps the one we are already reading.
      let inner_dialect = match Dialect::from_shell_name(n) {
        Some(d) => d
        None => self.dialect
      }
      let (seq, _) = parse_dialect(script, inner_dialect)
      // `bash -c "cd /tmp; rm x"` runs in its own process.
      let saved = self.saved_cwd()
      self.depth += 1
      self.walk_seq(seq)
      self.depth -= 1
      self.restore_cwd(saved)
    }
    None => self.push(Spawn, n, true, line)
  }
}
