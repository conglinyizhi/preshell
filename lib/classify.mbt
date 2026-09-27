///|
/// Which program does what: the dispatcher that turns a command word into
/// effects.
///
/// It is a dispatcher and nothing more — the shape to read here is which
/// programs have an entry at all, and which fall through to the generic operand
/// model.
///
/// Each entry is a claim about one program or one family of them, and the entry
/// exists only when the behaviour was measured or read off the program's own
/// documentation. A program with no entry falls through to the generic operand
/// model, and one whose behaviour is unbounded is reported unmodelled rather
/// than guessed at — saying "we do not model this" is a fact, and it is the one
/// that keeps the effect list from reading as complete when it is not.
///
/// The behaviour behind the dispatch is in programs.mbt, one function per family
/// of commands; the helpers that scan an argument list are in options.mbt. This
/// file keeps the two decisions that come before either: whether the command is a
/// wrapper that runs something else, and whether it is a program whose effect is
/// decided by a flag or subcommand rather than by an operand list (tools.mbt).

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
  // Which family the command belongs to decides its effects. The families
  // themselves are in programs.mbt, one function each; what is left here is the
  // dispatch, so a reader can see at a glance which programs this tool has an
  // opinion about and which it does not.
  match n {
    "rm" | "rmdir" | "unlink" | "shred" =>
      self.delete_operand_effects(operands, line)
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
    | "realpath" => self.read_operand_effects(operands, line)
    "find" => self.find_operand_effects(items, line)
    "grep" | "rg" | "awk" | "sed" =>
      self.script_effects(n, scan, script_operands, line)
    "tee" | "touch" | "truncate" | "mkdir" =>
      self.write_operand_effects(operands, line)
    "chmod" | "chown" | "chgrp" => self.mode_effects(operands, scan, line)
    "ln" => self.link_effects(operands, scan, line)
    "split" | "csplit" => self.split_effects(n, operands, line)
    "cp" | "mv" | "install" | "rsync" =>
      self.copy_effects(n, operands, scan, line)
    "zip" => self.zip_effects(operands, line)
    "gzip"
    | "gunzip"
    | "bzip2"
    | "bunzip2"
    | "xz"
    | "unxz"
    | "zstd"
    | "unzstd" => self.compressor_effects(n, scan, operands, line)
    "dd" => self.dd_effects(items, line)
    "tar" => self.tar_effects(scan, items, operands, flags, line)
    "unzip" => self.unzip_effects(items, operands, line)
    "curl"
    | "wget"
    | "nc"
    | "ncat"
    | "ssh"
    | "scp"
    | "sftp"
    | "telnet"
    | "ping"
    | "dig" => self.net_effects(n, items, operands, line)
    "cd" => self.cd_effects(operands, line)
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
