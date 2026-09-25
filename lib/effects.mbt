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
  /// The variables this target reads, in order, deduplicated. The tool never
  /// reads the environment, so this is what it can hand over instead: a caller
  /// that knows `HOME` can finish `$HOME/x` itself. Empty for anything that is
  /// not a path, and for paths that are already closed.
  vars : Array[String]
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
  /// Every variable the paths in this report read, deduplicated. A caller about
  /// to run the command in a sandbox can look at this list instead of reading
  /// every effect: it is the set of values it has to supply or reject.
  vars : Array[String]
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
    | "bunzip2"
    | "xz"
    | "unxz"
    | "zstd"
    | "unzstd"
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
  /// Grammar the surrounding command line is being read with. A nested script
  /// (`eval`, `zsh -c`) has to be read with it too, or a zsh-only construct
  /// inside gets read as bash and the effects come out wrong.
  dialect : Dialect
  /// Directory the command line itself moved into, or None when it has not
  /// moved or could not be modelled. See cwd.mbt.
  mut cwd : String?
  /// Union of the variables the reported paths read, in first-seen order.
  vars : Array[String]
}

///|
pub fn impact(
  seq : Seq,
  dialect? : Dialect = Bash,
  base_cwd? : String? = None,
) -> Impact {
  let c : Collector = {
    items: [],
    roots: [],
    dropped: 0,
    uncertain: false,
    depth: 0,
    dialect,
    vars: [],
    // The base is where relative paths are resolved from. `--cwd` supplies it
    // for a command line that does not `cd` itself; it is a starting point, not
    // a move, so it never shows up as an effect.
    cwd: match base_cwd {
      None => None
      Some(dir) => Some(normalize_path(dir))
    },
  }
  c.walk_seq(seq)
  {
    effects: c.items,
    write_roots: c.roots,
    uncertain: c.uncertain,
    vars: c.vars,
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
  unrooted? : Bool = false,
  vars? : Array[String] = [],
) -> Unit {
  let resolved = match kind {
    Read | Write | Delete =>
      // A path whose first segment is expanded at run time may itself be
      // absolute: `$HOME/x` is `/home/u/x`, not `<cwd>/$HOME/x` (bash 5.3
      // manual, "Expansion": the value of a parameter is used as it stands).
      // The base cannot be applied on top of it, so the text is reported as
      // written and the caller, who knows the value, finishes the job.
      if unrooted {
        target
      } else {
        self.resolve(target)
      }
    _ => target
  }
  for v in vars {
    if !self.vars.contains(v) {
      self.vars.push(v)
    }
  }
  if self.items.length() >= max_effects() {
    self.dropped = self.dropped + 1
    self.uncertain = true
    // Roots still accumulate: they are cheap, deduplicated, and they are the
    // part a caller most often acts on.
  } else {
    self.items.push({ kind, target: resolved, vars, dynamic, modeled, line, })
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
    Cmd::Arith(_) => ()
    Cmd::Cond(subs~, ..) =>
      // The condition text touches nothing, but a `$(...)` inside it runs.
      for seq in subs {
        let saved = self.saved_cwd()
        self.walk_seq(seq)
        self.restore_cwd(saved)
      }
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
    // Same word as the path effects below it, so it must carry the same
    // variables: `$X/y` is one unresolved path, not two unrelated facts.
    self.push_path(Unknown, PathArg::of(w), w.line)
  }
}

///|
/// Push a path that came from a word, carrying everything that was read off it.
///
/// This is the only way a path effect should be added: the text, the closed-set
/// flag, whether it may be anchored, and the variables it reads are four facts
/// about one word, and splitting them apart is how `'$X/y'` gets mistaken for an
/// expansion.
fn Collector::push_path(
  self : Collector,
  kind : EffectKind,
  arg : PathArg,
  line : Int,
) -> Unit {
  self.push(
    kind,
    arg.text,
    arg.dynamic,
    line,
    unrooted=arg.unrooted,
    vars=arg.vars,
  )
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
  let trimmed = if t.has_suffix("-") {
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
        // The program name itself is a hole (`$CMD --help`): the caller can
        // resolve it with the value it knows, so hand the name over.
        self.push_path(Exec, PathArg::of(s.words[0]), line)
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
fn arg_items(s : SimpleCmd) -> Array[PathArg] {
  let out : Array[PathArg] = []
  for i, w in s.words {
    if i == 0 {
      continue
    }
    out.push(PathArg::of(w))
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
  // A wrapper runs the program it is handed, so that program is the real
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
      self.container_effects(s, line)
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
    | "deno" => if self.runner_effects(n, s, line) { return }
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
  self.push(Exec, n, false, line, modeled~)
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

///|
/// What a wrapper does with the words after it.
priv enum Wrapped {
  /// It runs no program: a bare `env`, or `command -v` which only asks where
  /// a name is.
  Nothing
  /// The command starts at this index of the wrapper's own argument list.
  Command(Int)
  /// The command line lives inside a string option (`env -S "rm -rf x"`),
  /// which this tool does not take apart.
  FromString
}

///|
/// Programs that run another program and hand it their own command line.
/// Measured with the shim: `env rm -rf victim.txt`, `timeout 5 rm -f x`,
/// `nice -n 5 rm`, `nohup rm`, `stdbuf -oL rm`, `setsid rm`, `command rm` and
/// `xargs rm` all end up deleting the file they are handed. Before this, each
/// of them reported only "an unmodelled program ran", which is true and says
/// nothing about what it ran.
fn is_wrapper(n : String) -> Bool {
  match n {
    "env"
    | "nice"
    | "nohup"
    | "timeout"
    | "stdbuf"
    | "setsid"
    | "command"
    | "xargs" => true
    _ => false
  }
}

///|
/// The wrapper's own options that take the next word as their value. The
/// lists are measured against the real program (`nice -n 5 rm`, `timeout -s
/// KILL 5 rm`, `env -u FOO rm`, `env -a argv0 rm`, `stdbuf -o L rm`,
/// `xargs -I{} rm`, ...). `setsid -c` is deliberately absent: it is --ctty and
/// takes no value, so consuming the next word after it would eat the command.
fn wrapper_value_opts(n : String) -> Array[String] {
  match n {
    "env" =>
      [
        "-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "--argv0",
      ]
    "timeout" => ["-s", "--signal", "-k", "--kill-after"]
    "nice" => ["-n", "--adjustment"]
    "stdbuf" => ["-i", "-o", "-e", "--input", "--output", "--error"]
    "xargs" =>
      [
        "-E", "-I", "-L", "-n", "-P", "-s", "-d", "-a", "--eof", "--replace", "--max-lines",
        "--max-args", "--max-procs", "--max-chars", "--delimiter", "--arg-file",
      ]
    _ => []
  }
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
/// Whether this word is `NAME=VALUE` before an `env` command name. It is part
/// of the environment, not the program to run: `env FOO=1 rm x` runs rm.
fn is_env_assign(t : String) -> Bool {
  match t.find("=") {
    Some(eq) =>
      eq > 0 &&
      !t.unsafe_substring(start=0, end=eq).contains("/") &&
      is_name_text(t.unsafe_substring(start=0, end=eq))
    None => false
  }
}

///|
fn is_name_text(t : String) -> Bool {
  if t.length() == 0 {
    return false
  }
  let first = match t.get_char(0) {
    Some(c) => c.is_ascii_alphabetic() || c == '_'
    None => false
  }
  first &&
  t
  .to_string()
  .all(fn(c) { c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_' })
}

///|
/// Where the program a wrapper runs starts, or None when `n` is not a wrapper.
/// The wrapper's own options are skipped, an `env` assignment is skipped, and
/// `timeout`'s DURATION is skipped because it is a number, not a command.
fn wrapper_target(n : String, words : Array[Word]) -> Wrapped? {
  if !is_wrapper(n) {
    return None
  }
  let value_opts = wrapper_value_opts(n)
  // timeout's first non-option word is its DURATION.
  let mut prologue = if n == "timeout" { 1 } else { 0 }
  let mut i = 1
  while i < words.length() {
    let t = words[i].literal_text()
    if t == "--" {
      i += 1
      break
    }
    if !t.has_prefix("-") || t == "-" {
      if n == "env" && is_env_assign(t) {
        i += 1
        continue
      }
      if prologue > 0 {
        prologue -= 1
        i += 1
        continue
      }
      break
    }
    // `command -v rm` asks where rm is; it does not run it. Measured: the
    // file the argument names is still there afterwards.
    if n == "command" && (t == "-v" || t == "-V") {
      return Some(Wrapped::Nothing)
    }
    // `env -S "rm -rf x"` runs the string, not a word of its own.
    if n == "env" && (t == "-S" || t == "--split-string") {
      return Some(Wrapped::FromString)
    }
    i += 1 + wrapper_option_extra_words(value_opts, t)
  }
  if i >= words.length() {
    // `env` on its own prints the environment and runs nothing.
    return Some(Wrapped::Nothing)
  }
  Some(Wrapped::Command(i))
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

///|
/// Whether an xargs command uses a replacement string (`-I{}`, `--replace=`,
/// or the old `-i`). Every argument that spells it becomes a placeholder for
/// the input, so the command's argv cannot be read as literal paths.
fn xargs_replaces(words : Array[Word]) -> Bool {
  for i, w in words {
    if i == 0 {
      continue
    }
    let t = w.literal_text()
    if t.has_prefix("-I") || t.has_prefix("-i") || t.has_prefix("--replace") {
      return true
    }
  }
  false
}

///|
/// Wrappers that exec a file: `env`, `nice`, `nohup`, `timeout`, `stdbuf`,
/// `setsid` and `xargs` all end in execvp, so a shell word cannot be the
/// program they run. `cd` and `eval` are the two whose effects would be
/// invented if followed: a moved working directory and a parsed string for a
/// command that fails. `command` is the exception, it runs builtins in the
/// current shell.
fn wrapper_runs_shell_words(n : String) -> Bool {
  n == "command"
}

///|
/// Wrappers nest for free: the inner command goes back through classify, so
/// `env timeout 5 rm -f x` and `nice -n 5 xargs rm` work the same way.
fn Collector::wrapper_effects(
  self : Collector,
  n : String,
  s : SimpleCmd,
  target : Wrapped,
  line : Int,
) -> Unit {
  // The wrapper itself runs and touches nothing of its own.
  self.push(Exec, n, false, line)
  match target {
    Wrapped::Nothing => ()
    Wrapped::FromString =>
      self.push(
        Unknown,
        n + ": the command line is inside a string option",
        true,
        line,
      )
    Wrapped::Command(i) => {
      if self.depth >= max_wrapper_depth() {
        self.push(Unknown, n + ": wrapper depth limit", true, line)
        return
      }
      let inner = s.words[i:].to_owned()
      let name = inner[0].literal_text()
      if n == "xargs" {
        // -a/--arg-file: the list is read from a file instead of stdin, and
        // that file is a path. Measured: `xargs -a list rm` opens list.
        match option_word_value(s.words, ["-a", "--arg-file"]) {
          Some(f) => self.push_path(Read, f, line)
          None => ()
        }
        if xargs_replaces(s.words) {
          // -I/--replace (and the old -i) substitute each input line into
          // every occurrence of a string in the command. Those words are
          // placeholders, not paths: following `xargs -I{} rm {}` reported
          // `{}` as a file to delete.
          self.push(Exec, name, false, line, modeled=false)
          self.push(
            Unknown,
            "xargs: the replaced arguments come from its input",
            true,
            line,
          )
          return
        }
      }
      if !wrapper_runs_shell_words(n) && (name == "cd" || name == "eval") {
        self.push(Exec, name, false, line, modeled=false)
      } else {
        let cmd : SimpleCmd = { assigns: [], words: inner, redirects: [], }
        self.depth += 1
        self.classify(name, cmd, line)
        self.depth -= 1
      }
      if n == "xargs" {
        // The words xargs appends come from its input, which this tool does
        // not read. The fixed part above still counts; this says what is
        // missing from it.
        self.push(
          Unknown,
          "xargs: the argument list comes from its input",
          true,
          line,
        )
      }
    }
  }
}

///|
/// Wrapper nesting is bounded like every other recursion here: a command line
/// of 10000 `env` words must not decide whether this process survives.
fn max_wrapper_depth() -> Int {
  16
}
