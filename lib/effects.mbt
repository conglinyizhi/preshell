///|
/// Effects are the "what does this command touch" layer: a normalized,
/// syntax-independent summary of a command line. It is deliberately coarser
/// than the AST and deliberately honest about what it cannot know.
pub(all) enum EffectKind {
  Exec // a program is started
  Read // a path is opened for reading
  Write // a path is created or modified
  Delete // a path is removed
  Net // something leaves the machine
  Spawn // a program whose real name comes from data (piped into a shell)
  Unknown // a hole we refuse to guess
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Effect {
  kind : EffectKind
  target : String
  /// True when the target is not a closed set: it has a hole or a glob.
  dynamic : Bool
  /// Only meaningful for `Exec`. False means: this program ran, and what it
  /// touches is decided inside it, so everything else in this report is a
  /// *lower bound*. `git pull` writing `.git/` is not missing from the answer
  /// by oversight; it is outside what this tool models, and saying so is the
  /// point.
  modeled : Bool
  line : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Impact {
  effects : Array[Effect]
  /// Directories that would be modified, normalized. This is the blast radius
  /// a caller can actually lock.
  write_roots : Array[String]
  /// True when any exec/write/delete/spawn target is not a closed set,
  /// i.e. the blast radius cannot be bounded by this summary alone.
  uncertain : Bool
  /// How many effects were found but not listed (see max_effects). Any drop
  /// forces `uncertain`.
  effects_dropped : Int
  /// The directory that relative paths in this report are relative to, when
  /// the command line itself changed into one. None means "no cwd change was
  /// modelled": relative paths are then relative to whatever directory the
  /// command runs in, which is the caller's knowledge, not this tool's.
  cwd : String?
} derive(Debug, Eq, ToJson)

///|
/// Drop the operand that a known flag already consumed, so a value like the
/// `-C dir` of tar is not reported twice: once as the write target and once as
/// a path the command reads.
fn drop_flag_value(
  xs : Array[(String, Bool)],
  value : String?,
) -> Array[(String, Bool)] {
  match value {
    None => xs
    Some(v) =>
      xs.filter(fn(it) {
        let (t, _) = it
        t != v
      })
  }
}

///|
/// The operands that come before the first flag. For commands like `find`,
/// whose later arguments are predicates rather than paths (`-name '*.mbt'`),
/// only the leading ones are files.
fn leading_operands(items : Array[(String, Bool)]) -> Array[(String, Bool)] {
  let out : Array[(String, Bool)] = []
  for it in items {
    let (t, _) = it
    if t.has_prefix("-") {
      break
    }
    if t != "" {
      out.push(it)
    }
  }
  out
}

///|
/// Programs with no file behaviour of their own: they are pure text or shell
/// state, and any file they touch is touched through a redirection, which the
/// report captures separately.
///
/// This is a claim about the program, so the rule for adding a name is the same
/// as everywhere else here: **when unsure, leave it out**. An omitted program
/// becomes unmodelled, which is the safe direction; a wrongly included one
/// silently under-reports.
fn is_pure(n : String) -> Bool {
  match n {
    // text producers and tests
    "echo"
    | "printf"
    | "true"
    | "false"
    | ":"
    | "test"
    | "["
    | "[["
    | "seq"
    | "expr"
    | "basename"
    | "tr"
    | "dirname"
    | "tty"
    | "sleep" => true
    // system questions, no file arguments
    "pwd"
    | "date"
    | "id"
    | "whoami"
    | "uname"
    | "hostname"
    | "printenv"
    | "umask" => true
    // shell state
    "export"
    | "unset"
    | "set"
    | "shift"
    | "exit"
    | "return"
    | "break"
    | "continue"
    | "trap"
    | "wait"
    | "local"
    | "declare"
    | "typeset"
    | "readonly"
    | "let"
    | "read"
    | "alias"
    | "unalias"
    | "hash"
    | "jobs"
    | "fg"
    | "bg"
    | "kill" => true
    _ => false
  }
}

///|

///|
/// Programs whose *arguments are the files they touch*. This list is closed on
/// purpose, and it stays short for a reason: it is only the set of programs
/// whose whole job is file manipulation, so modelling them needs no knowledge
/// of any application.
///
/// Everything else — interpreters, build tools, package managers, anything
/// written by someone else — is reported as unmodelled. Enumerating what
/// `node`, `python` or `docker` touch means reading the scripts and images they
/// are given, which is not a bounded project; marking them is.
fn is_path_modeled(n : String) -> Bool {
  match n {
    "cat"
    | "head"
    | "tail"
    | "less"
    | "more"
    | "grep"
    | "rg"
    | "awk"
    | "sort"
    | "wc"
    | "diff"
    | "readlink"
    | "stat"
    | "file"
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
    | "tee"
    | "touch"
    | "truncate"
    | "mkdir"
    | "rmdir"
    | "ln"
    | "install"
    | "split"
    | "csplit"
    | "chmod"
    | "chown"
    | "chgrp"
    | "rm"
    | "unlink"
    | "shred"
    | "cp"
    | "mv"
    | "rsync"
    | "sed"
    | "dd"
    | "tar"
    | "unzip"
    | "zip"
    | "gzip"
    | "gunzip"
    | "bzip2"
    | "xz"
    | "zstd"
    | "source"
    | "."
    | "ls"
    | "du"
    | "df"
    | "tree"
    | "realpath"
    | "find" => true
    _ => false
  }
}

///|
/// Programs that talk to the network. Kept apart from the path-modelled set:
/// `git status` is neither a network call nor a file operation this tool can
/// follow, and lumping it in here would mislabel both.
fn is_network_modeled(n : String) -> Bool {
  match n {
    "curl"
    | "wget"
    | "nc"
    | "ncat"
    | "ssh"
    | "scp"
    | "sftp"
    | "telnet"
    | "ping"
    | "dig" => true
    _ => false
  }
}

///|
/// How many effects a report carries. Effects are the answer, not diagnostics,
/// so the cap is generous — but it exists: a 360KB input of nested `if` used to
/// produce 39k effects and a 2.8MB answer, which is not something to hand a
/// caller that is going to paste it somewhere. `effects_dropped` says how many
/// were left out, and dropping any forces `uncertain`, because a partial effect
/// list is not a smaller answer.
fn max_effects() -> Int {
  4096
}

///|
struct Collector {
  items : Array[Effect]
  roots : Array[String]
  mut dropped : Int
  mut uncertain : Bool
  mut depth : Int
  /// Directory the command line itself moved into, or None when it has not
  /// moved or could not be modelled. See cwd.mbt.
  mut cwd : String?
}

///|
pub fn impact(seq : Seq) -> Impact {
  let c : Collector = {
    items: [],
    roots: [],
    dropped: 0,
    uncertain: false,
    depth: 0,
    cwd: None,
  }
  c.walk_seq(seq)
  {
    effects: c.items,
    write_roots: c.roots,
    uncertain: c.uncertain,
    cwd: c.cwd,
    effects_dropped: c.dropped,
  }
}

///|

///|
/// Resolve path-shaped targets through the directories the command line itself
/// changed into, so that `cd /tmp && rm -rf x` reports `/tmp/x` and not a bare
/// `x` the caller has to guess about.
fn Collector::push(
  self : Collector,
  kind : EffectKind,
  target : String,
  dynamic : Bool,
  line : Int,
  modeled? : Bool = true,
) -> Unit {
  let resolved = match kind {
    Read | Write | Delete => self.resolve(target)
    _ => target
  }
  if self.items.length() >= max_effects() {
    self.dropped = self.dropped + 1
    self.uncertain = true
    // Roots still accumulate: they are cheap, deduplicated, and they are the
    // part a caller most often acts on.
  } else {
    self.items.push({ kind, target: resolved, dynamic, modeled, line, })
  }
  if dynamic &&
    (
      kind is Write ||
      kind is Delete ||
      kind is Exec ||
      kind is Spawn ||
      kind is Unknown
    ) {
    self.uncertain = true
  }
  // A program whose behaviour we do not model puts everything below it out of
  // reach: the report is a lower bound, and the caller has to be able to see
  // that without reading the effect list closely.
  if !modeled {
    self.uncertain = true
  }
  if kind is Write || kind is Delete {
    let d = parent_dir(resolved)
    if !self.roots.contains(d) {
      self.roots.push(d)
    }
  }
}

///|
fn Collector::walk_seq(self : Collector, seq : Seq) -> Unit {
  for item in seq.items {
    self.walk_pipeline(item.pipeline)
  }
}

///|
fn Collector::walk_pipeline(self : Collector, p : Pipeline) -> Unit {
  // Each element of a multi-command pipeline runs in its own subshell, so a
  // `cd` inside one of them does not move the next one.
  let shared = p.cmds.length() == 1
  for i, c in p.cmds {
    let saved = self.saved_cwd()
    self.walk_cmd(c)
    match c {
      Cmd::Simple(s) =>
        match command_name(s) {
          Some(name) =>
            // A program fed from a pipe is started, but what it runs is data.
            if i > 0 && is_interpreter(name) {
              self.push(Spawn, name, true, line_of(s))
            }
          None => ()
        }
      _ => ()
    }
    if !shared {
      self.restore_cwd(saved)
    }
  }
}

///|
fn Collector::walk_cmd(self : Collector, cmd : Cmd) -> Unit {
  match cmd {
    Cmd::Simple(s) => self.walk_simple(s)
    Cmd::Subshell(seq) => {
      // `(cd /tmp; rm x)` moves only the subshell's own directory.
      let saved = self.saved_cwd()
      self.walk_seq(seq)
      self.restore_cwd(saved)
    }
    Cmd::Group(seq) => self.walk_seq(seq)
    Cmd::AnonFunc(body~, args~, redirects~) => {
      // The body runs now, with those words as its arguments, so neither part
      // is optional: a command substitution inside an argument is a real
      // command, and the redirects apply to the call.
      self.walk_cmd(body)
      for w in args {
        self.walk_word(w)
      }
      for r in redirects {
        self.redirect_effects(r)
      }
    }
    Cmd::Always(inner~, always~) => {
      // Both blocks run, so both contribute: the finally block is not optional.
      self.walk_seq(inner)
      self.walk_seq(always)
    }
    Cmd::If(cond~, then_~, elifs~, else_~) => {
      self.walk_seq(cond)
      self.walk_seq(then_)
      for pair in elifs {
        let (c, b) = pair
        self.walk_seq(c)
        self.walk_seq(b)
      }
      match else_ {
        Some(e) => self.walk_seq(e)
        None => ()
      }
    }
    Cmd::Loop(cond~, body~, ..) => {
      self.walk_seq(cond)
      self.walk_seq(body)
    }
    Cmd::For(body~, words~, ..) => {
      for w in words {
        self.note_holes(w)
      }
      self.walk_seq(body)
    }
    Cmd::Case(subject~, items~) => {
      self.note_holes(subject)
      for it in items {
        for p in it.patterns {
          self.note_holes(p)
        }
        self.walk_seq(it.body)
      }
    }
    Cmd::FuncDef(body~, ..) =>
      self.walk_seq(Seq::{
        items: [{ pipeline: { negated: false, cmds: [body], }, op: Semi, }],
      })
    Cmd::Arith(_) | Cmd::Cond(_) => ()
    Cmd::Redirected(inner~, redirects~) => {
      self.walk_cmd(inner)
      for r in redirects {
        self.redirect_effects(r)
      }
    }
  }
}

///|
/// A hole in a position we cannot evaluate is reported instead of guessed.
fn Collector::note_holes(self : Collector, w : Word) -> Unit {
  if w.has_hole() {
    self.push(Unknown, w.literal_text(), true, w.line)
  }
}

///|
/// One part of an assignment: nested commands are real commands, and a hole
/// anywhere in the assignment (index or value) makes its target uncertain.
fn Collector::scan_assign_part(
  self : Collector,
  name : String,
  p : WordPart,
  line : Int,
) -> Unit {
  match p {
    CmdSub(seq) | ProcSub(_, seq) => {
      // `x=$(cd /tmp; rm y)` moves only the substitution's directory: the
      // command after it is still relative to where we were.
      let saved = self.saved_cwd()
      self.walk_seq(seq)
      self.restore_cwd(saved)
      self.note_temp_file(p, line)
    }
    Param(_) | ArithSub(_) => self.push(Unknown, "${" + name + "}", true, line)
    DQuote(inner) | Subscript(inner) =>
      for q in inner {
        self.scan_assign_part(name, q, line)
      }
    _ => ()
  }
}

///|
/// One redirection: the target is a path for `>` and `<`, plain data for a
/// here-document, and its holes always matter.

///|
/// Whether a dup target names a descriptor rather than a file: `2`, `1-`, `-`.
fn is_fd_word(t : String) -> Bool {
  if t == "-" {
    return true
  }
  let trimmed = if t.ends_with("-") {
    t.unsafe_substring(start=0, end=t.length() - 1)
  } else {
    t
  }
  trimmed.length() > 0 && all_digits(trimmed)
}

///|
fn Collector::redirect_effects(self : Collector, r : Redirect) -> Unit {
  let line = r.target.line
  let dynamic_target = r.target.static_text() == None
  let t = r.target.literal_text()
  match r.op {
    ROut | RAppend | RClobber | RInOut =>
      self.push(
        Write,
        if t == "" {
          "<unknown>"
        } else {
          t
        },
        dynamic_target,
        line,
      )
    RIn => self.push(Read, t, dynamic_target, line)
    // `>&word` duplicates a descriptor when word is one, and writes the file
    // otherwise. Measured: `bash -c 'echo hi >& out'` and the same in zsh both
    // write a file called out, and we used to report nothing at all.
    RDupOut =>
      if !is_fd_word(t) {
        self.push(
          Write,
          if t == "" {
            "<unknown>"
          } else {
            t
          },
          dynamic_target,
          line,
        )
      }
    // `<&word` with a word that is not a descriptor is an error at run time in
    // bash, so there is no path to report.
    RDupIn => ()
    // A here-document body is data, not a path; only its holes matter.
    RHereDoc | RHereDocStrip | RHereString =>
      match r.body {
        Some(b) =>
          if b.contains("$(") || b.contains("`") {
            self.push(Unknown, "here-document body", true, line)
          }
        None => ()
      }
    _ => ()
  }
  self.walk_word(r.target)
}

///|
fn Collector::walk_simple(self : Collector, s : SimpleCmd) -> Unit {
  let line = line_of(s)
  for a in s.assigns {
    for p in a.index {
      self.scan_assign_part(a.name, p, line)
    }
    for p in a.value {
      self.scan_assign_part(a.name, p, line)
    }
  }
  for r in s.redirects {
    self.redirect_effects(r)
  }
  for w in s.words {
    self.walk_word(w)
  }
  match command_name(s) {
    None =>
      if s.words.length() > 0 {
        self.push(Exec, s.words[0].literal_text(), true, line)
      }
    Some(n) => self.classify(n, s, line)
  }
}

///|
/// Walk a word: command substitutions inside it are real commands.
fn Collector::walk_word(self : Collector, w : Word) -> Unit {
  // A command substitution is its own process: a `cd` inside it is gone by the
  // time the surrounding command line continues.
  for seq in w.subcommands() {
    let saved = self.saved_cwd()
    self.walk_seq(seq)
    self.restore_cwd(saved)
  }
  for p in w.parts {
    self.note_temp_file(p, w.line)
  }
}

///|
/// zsh's `=(cmd)` writes the command's output to a real file under $TMPPREFIX
/// and substitutes its path, so a file does appear on disk. That is a write,
/// and it is reported even though the name cannot be known in advance: the
/// target is the template zsh fills in, marked uncertain like any other value
/// we cannot resolve. `<(cmd)` and `>(cmd)` are pipes and name no path.
fn Collector::note_temp_file(
  self : Collector,
  p : WordPart,
  line : Int,
) -> Unit {
  match p {
    ProcSub('=', _) => self.push(Write, "/tmp/zshXXXXXX", true, line)
    _ => ()
  }
}

///|
/// Text plus "is this value a closed set" for every argument. Keeping the two
/// together is what lets a hole in one argument stay localized instead of
/// pessimizing the whole command line.
fn arg_items(s : SimpleCmd) -> Array[(String, Bool)] {
  let out : Array[(String, Bool)] = []
  for i, w in s.words {
    if i == 0 {
      continue
    }
    out.push((w.literal_text(), w.has_hole() || w.has_glob()))
  }
  out
}

///|
fn Collector::classify(
  self : Collector,
  n : String,
  s : SimpleCmd,
  line : Int,
) -> Unit {
  let items = arg_items(s)
  let flags : Array[String] = []
  let operands : Array[(String, Bool)] = []
  for it in items {
    let (t, _) = it
    if t.has_prefix("-") {
      flags.push(t)
    } else if t != "" {
      operands.push(it)
    }
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
  self.push(Exec, n, false, line, modeled~)
  if !modeled {
    // Nothing else can be said about it, and saying nothing would read as
    // "touches nothing".
    return
  }
  let writes = fn(xs : Array[(String, Bool)]) {
    for it in xs {
      let (t, d) = it
      self.push(Write, t, d, line)
    }
  }
  let reads = fn(xs : Array[(String, Bool)]) {
    for it in xs {
      let (t, d) = it
      self.push(Read, t, d, line)
    }
  }
  match n {
    "rm" | "rmdir" | "unlink" | "shred" =>
      for it in operands {
        let (t, d) = it
        self.push(Delete, t, d, line)
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
      // The first operand is the pattern or the script, and the rest are
      // files. Reporting the pattern as a path the command reads is the kind
      // of false positive that makes a caller stop trusting the report.
      let rest = if operands.length() > 1 {
        operands[1:].to_array()
      } else {
        []
      }
      if n == "sed" && flags.any(fn(f) { f.has_prefix("-i") }) {
        writes(rest)
      } else {
        reads(rest)
      }
    }
    "tee" | "touch" | "truncate" | "mkdir" => writes(operands)
    "chmod" | "chown" | "chgrp" =>
      // The first operand is the mode, the owner or the group; the rest are
      // files. Reporting `644` as a written path is the kind of invented fact
      // that makes a report untrustworthy.
      writes(if operands.length() > 1 { operands[1:].to_array() } else { [] })
    "ln" =>
      // `ln target link`: the last operand is what gets created.
      if operands.length() > 0 {
        let n_op = operands.length()
        for i, it in operands {
          let (t, d) = it
          if i == n_op - 1 {
            self.push(Write, t, d, line)
          } else {
            self.push(Read, t, d, line)
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
    "cp" | "mv" | "install" | "rsync" => {
      let n_op = operands.length()
      for i, it in operands {
        let (t, d) = it
        if i == n_op - 1 {
          self.push(Write, t, d, line)
        } else {
          self.push(Read, t, d, line)
        }
      }
    }
    "zip" =>
      // `zip archive.zip members...`: the archive is written, the members read.
      match operands {
        [(t, d), .. rest] => {
          self.push(Write, t, d, line)
          for it in rest {
            let (m, md) = it
            self.push(Read, m, md, line)
          }
        }
        [] => ()
      }
    "gzip" | "bzip2" | "xz" | "zstd" =>
      // These rewrite their operand in place unless told otherwise, so the
      // first operand is both read and written.
      match operands {
        [(t, d), ..] => {
          self.push(Read, t, d, line)
          self.push(Write, t, d, line)
        }
        [] => ()
      }
    "dd" =>
      for it in items {
        let (t, _) = it
        if t.has_prefix("of=") {
          self.push(
            Write,
            t.unsafe_substring(start=3, end=t.length()),
            false,
            line,
          )
        }
        if t.has_prefix("if=") {
          self.push(
            Read,
            t.unsafe_substring(start=3, end=t.length()),
            false,
            line,
          )
        }
      }
    "tar" => {
      // tar does three different things depending on its mode flag, and it
      // writes somewhere different in each: create writes the archive, extract
      // writes into -C (or the cwd), list only reads.
      let dest = flag_value(items, ["-C", "--directory"])
      // The mode letter can arrive as `-czf` or as the classic no-dash form
      // `czf`, and both spellings are common in the wild.
      let cluster = match short_flag_cluster(operands) {
        Some(c) => c
        None => ""
      }
      let dashed = flags.fold(init="", (acc, f) => acc + f)
      let letters = cluster + dashed
      let archive_written = letters.contains("c") ||
        flags.any(fn(f) { f == "--create" })
      let listing = letters.contains("t") || flags.any(fn(f) { f == "--list" })
      let args = drop_flag_value(drop_short_flag_cluster(operands), dest)
      if archive_written {
        match args {
          [(t, d), .. members] => {
            self.push(Write, t, d, line)
            for it in members {
              let (m, md) = it
              self.push(Read, m, md, line)
            }
          }
          [] => ()
        }
      } else {
        match dest {
          Some(d) => if !listing { self.push(Write, d, false, line) }
          None =>
            if !listing {
              self.push(
                Unknown,
                "tar: extraction point is the working directory",
                true,
                line,
              )
            }
        }
        reads(args)
      }
    }
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
        let (t, _) = it
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
          let (h, hd) = it
          if h.contains(":") || h.contains("@") {
            self.push(Net, h, hd, line)
          }
        }
      } else if n == "ssh" ||
        n == "telnet" ||
        n == "ping" ||
        n == "dig" ||
        n == "nc" ||
        n == "ncat" {
        match operands {
          [(t, d), ..] => self.push(Net, t, d, line)
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
          match first {
            (t, false) =>
              if t == "-" || t == "~" || t.has_prefix("~") {
                None
              } else {
                Some(t)
              }
            (_, true) => None
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
    "grep" | "rg" | "awk" | "sed" =>
      if operands.length() > 1 {
        operands[1:].to_array()
      } else {
        []
      }
    "find" => leading_operands(items)
    _ => operands
  }
  for it in checked {
    let (t, d) = it
    if d && !t.has_prefix("-") {
      self.push(Unknown, t, true, line)
    }
  }
}

///|
/// The value that follows one of `names` in an argument list, if present.
fn flag_value(items : Array[(String, Bool)], names : Array[String]) -> String? {
  for i, it in items {
    let (t, _) = it
    for n in names {
      if t == n && i + 1 < items.length() {
        let (v, _) = items[i + 1]
        return Some(v)
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
      let (seq, _) = parse(script)
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

///|
/// Without a per-command option table we cannot tell `xzf` from a filename.
/// This is the narrow case of a general gap: an option string that does not
/// start with `-` is indistinguishable from a path operand.
fn short_flag_cluster(xs : Array[(String, Bool)]) -> String? {
  if xs.length() > 0 {
    let (first, _) = xs[0]
    if first.length() > 1 &&
      first.to_string().all(fn(c) { c.is_ascii_alphabetic() }) {
      return Some(first)
    }
  }
  None
}

///|
fn drop_short_flag_cluster(xs : Array[(String, Bool)]) -> Array[(String, Bool)] {
  match short_flag_cluster(xs) {
    Some(_) => xs[1:].to_array()
    None => xs
  }
}
