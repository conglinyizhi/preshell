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
  /// The directory that relative paths in this report are relative to, when
  /// the command line itself changed into one. None means "no cwd change was
  /// modelled": relative paths are then relative to whatever directory the
  /// command runs in, which is the caller's knowledge, not this tool's.
  cwd : String?
} derive(Debug, Eq, ToJson)

///|
struct Collector {
  items : Array[Effect]
  roots : Array[String]
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
) -> Unit {
  let resolved = match kind {
    Read | Write | Delete => self.resolve(target)
    _ => target
  }
  self.items.push({ kind, target: resolved, dynamic, line, })
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
  self.push(Exec, n, false, line)
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
    | "grep"
    | "rg"
    | "awk"
    | "sort"
    | "wc"
    | "diff"
    | "source"
    | "." => reads(operands)
    "sed" =>
      // The first operand is the script; the rest are files.
      if flags.any(fn(f) { f.has_prefix("-i") }) && operands.length() > 1 {
        writes(operands[1:].to_array())
      } else if operands.length() > 1 {
        reads(operands[1:].to_array())
      }
    "tee" | "touch" | "truncate" | "mkdir" | "chmod" | "chown" =>
      writes(operands)
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
      match flag_value(items, ["-C", "--directory"]) {
        Some(d) => self.push(Write, d, false, line)
        None =>
          self.push(Unknown, "tar: extraction point not given", true, line)
      }
      // `tar xzf a.tgz`: the first operand is an option cluster, not a path.
      reads(drop_short_flag_cluster(operands))
    }
    "unzip" => {
      match flag_value(items, ["-d"]) {
        Some(d) => self.push(Write, d, false, line)
        None =>
          self.push(Unknown, "unzip: extraction point not given", true, line)
      }
      reads(operands)
    }
    "curl" | "wget" | "nc" | "ssh" | "scp" | "git" | "pip" | "npm" => {
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
    "eval" => self.recurse_static(s, n, line)
    "make"
    | "cmake"
    | "ninja"
    | "cargo"
    | "go"
    | "npm"
    | "pnpm"
    | "yarn"
    | "mvn"
    | "gradle" =>
      // Builders decide their own writes at run time; say so instead of
      // pretending the blast radius is known.
      self.push(Unknown, n + ": build tool", true, line)
    _ =>
      if is_interpreter(n) && has_flag_text(flags, "-c") {
        self.recurse_static(s, n, line)
      }
  }
  for it in operands {
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
fn drop_short_flag_cluster(xs : Array[(String, Bool)]) -> Array[(String, Bool)] {
  if xs.length() > 0 {
    let (first, _) = xs[0]
    if first.length() > 1 &&
      first.to_string().all(fn(c) { c.is_ascii_alphabetic() }) {
      return xs[1:].to_array()
    }
  }
  xs
}
