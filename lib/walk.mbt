///|
/// Walking the syntax tree, turning it into effects.
///
/// The collector visits a sequence, a pipeline, a command, and a simple command,
/// and each visit pushes what it learned. Nothing here decides policy: a visit
/// either reports a fact or hands the command to classify.mbt, which knows which
/// program does what.
///
/// Scope is a shell's scope: a subshell, a command substitution, a pipeline
/// element and a script handed to another shell each get their own working
/// directory and their own copy of the values the command line set.

///|
fn Collector::walk_seq(self : Collector, seq : Seq) -> Unit {
  for item in seq.items {
    self.walk_pipeline(item.pipeline)
  }
}

///|
fn Collector::walk_pipeline(self : Collector, p : Pipeline) -> Unit {
  // Each element of a multi-command pipeline runs in its own subshell, so a
  // `cd` inside one of them does not move the next one, and neither does a
  // value it sets.
  let shared = p.cmds.length() == 1
  for i, c in p.cmds {
    let saved = self.saved_cwd()
    let saved_binds = if shared { [] } else { self.open_isolated() }
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
      self.close_isolated(saved_binds)
      self.restore_cwd(saved)
    }
  }
}

///|
fn Collector::walk_cmd(self : Collector, cmd : Cmd) -> Unit {
  match cmd {
    Cmd::Simple(s) => self.walk_simple(s)
    Cmd::Subshell(seq) => {
      // `(cd /tmp; rm x)` moves only the subshell's own directory, and the
      // values it sets are gone with it.
      let saved = self.saved_cwd()
      let saved_binds = self.open_isolated()
      self.walk_seq(seq)
      self.close_isolated(saved_binds)
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
      // Exactly one branch runs, so the states they leave behind are joined
      // rather than run one after another: `if c; then x=a; else x=b; fi` leaves
      // both values possible, and `if c; then x=a; fi` on top of `x=old` leaves
      // three (the old value is one of the outcomes, because the branch may not
      // run).
      self.walk_seq(cond)
      let base = self.snapshot()
      let states : Array[Array[(String, Array[String])]] = []
      match else_ {
        Some(_) => ()
        // No `else`, so taking no branch at all is one of the outcomes. It goes
        // first, so the value from before the construct leads the set the report
        // prints.
        None => states.push(base)
      }
      self.restore(base)
      self.walk_seq(then_)
      states.push(self.snapshot())
      for pair in elifs {
        let (c, b) = pair
        self.restore(base)
        self.walk_seq(c)
        self.walk_seq(b)
        states.push(self.snapshot())
      }
      match else_ {
        Some(e) => {
          self.restore(base)
          self.walk_seq(e)
          states.push(self.snapshot())
        }
        None => ()
      }
      // The union of what the branches left. The state before the construct is
      // one of those outcomes only when no branch had to run, which is why it
      // went into `states` above rather than staying the table to join into.
      self.restore(states[0])
      for k in 1..<states.length() {
        self.join_with(states[k])
      }
    }
    Cmd::Loop(cond~, body~, ..) => {
      // How many times a `while` runs is not modelled, so a value its body sets
      // is an unknown rather than a set of possibilities: joining one pass would
      // name a set that is not exhaustive.
      self.walk_seq(cond)
      let base = self.snapshot()
      self.walk_seq(body)
      self.drop_changed(base)
    }
    Cmd::For(name~, words~, body~) => {
      // `for f in {a,b}` is a two-word list, so the braces come out before the
      // list is read as a set, and `for f in $x` splits like any other unquoted
      // expansion before that.
      let listed : Array[Word] = []
      for w in words {
        for e in w.brace_words(self.dialect) {
          for v in self.value_words(e) {
            listed.push(v)
          }
        }
      }
      match self.loop_values(name, listed) {
        Some(values) => {
          // A spelled-out word list is a closed set: the body runs once per
          // word, with the loop name holding that word. `for f in a b; do rm
          // "$f"; done` is two deletions, and reporting the one hole it used to
          // report loses both. Each iteration starts from the same state so the
          // states can be joined: `for i in a b; do x=$i; done` leaves `x` as `a`
          // or `b`, and reporting only `b` would claim the loop always ends on
          // the last word, which it does not when the body breaks out.
          let base = self.snapshot()
          let states : Array[Array[(String, Array[String])]] = []
          for v in values {
            self.restore(base)
            self.bind_value(name, v)
            self.walk_seq(body)
            states.push(self.snapshot())
          }
          // The union of what the iterations left. The state before the loop is
          // deliberately not one of the outcomes: the list is spelled out, so the
          // body runs at least once. It is a union rather than the last
          // iteration, because the body may break out of the loop before the last
          // word (`for i in a b; do x=$i; break; done` leaves `a`), and a set
          // that missed that would be claiming to be exhaustive.
          self.restore(states[0])
          for k in 1..<states.length() {
            self.join_with(states[k])
          }
          // The loop name itself is whatever the last word left, one value this
          // tool does not track, so it goes back to being unknown.
          self.drop_value(name)
        }
        None => {
          for w in listed {
            self.note_list_word(w)
          }
          let base = self.snapshot()
          self.walk_seq(body)
          self.drop_changed(base)
        }
      }
    }
    Cmd::Case(subject~, items~) => {
      self.note_holes(subject)
      for it in items {
        for p in it.patterns {
          self.note_holes(p)
        }
      }
      // Which pattern matches is not modelled, and none of them may: every body
      // is walked from the same state and the results are joined.
      let base = self.snapshot()
      let states : Array[Array[(String, Array[String])]] = [base]
      for it in items {
        self.restore(base)
        self.walk_seq(it.body)
        states.push(self.snapshot())
      }
      self.restore(states[0])
      for k in 1..<states.length() {
        self.join_with(states[k])
      }
    }
    Cmd::FuncDef(body~, ..) => {
      // The definition does not run, and whether the function is called later is
      // not modelled, so a name its body writes becomes unknown rather than a set
      // of possibilities.
      let base = self.snapshot()
      self.walk_seq(Seq::{
        items: [{ pipeline: { negated: false, cmds: [body], }, op: Semi, }],
      })
      self.drop_changed(base)
    }
    Cmd::Arith(_) => ()
    Cmd::Cond(subs~, ..) =>
      // The condition text touches nothing, but a `$(...)` inside it runs, in
      // its own process.
      for seq in subs {
        let saved = self.saved_cwd()
        let saved_binds = self.open_isolated()
        self.walk_seq(seq)
        self.close_isolated(saved_binds)
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
/// expansion. The candidates come from the same word, so they are filled in here
/// rather than left to the call sites.
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
    candidates=self.candidates_for(arg),
    origin=arg.origin,
  )
}

///|
/// The paths a hole could be, from the values the command line left possible for
/// the names in it.
///
/// A name reaches here only when it has more than one possible value: a single
/// one would already have been put into the word, and an unbound one has nothing
/// to offer. The product over several names is capped, and past the cap the hole
/// says everything the list would, so the list stays empty.
fn Collector::candidates_for(self : Collector, arg : PathArg) -> Array[String] {
  if arg.vars.length() == 0 || !arg.dynamic {
    return []
  }
  let mut texts : Array[String] = [arg.text]
  let mut fanned = false
  for name in arg.vars {
    let values = match lookup_values(self.binds, name) {
      Some(vs) => vs
      // Nothing is known about it (unset, or the caller's environment). That
      // does not make the list partial: the enumeration is over the names the
      // report can speak about, and this is not one of them.
      None => continue
    }
    if values.length() < 2 {
      // Written, but with nothing this tool can list (or with a single value it
      // refused to put in). A list built over it would miss the outcomes this
      // tool cannot name, and the promise is exhaustive or absent.
      return []
    }
    fanned = true
    let out : Array[String] = []
    for t in texts {
      for v in values {
        out.push(replace_name(t, name, v))
        if out.length() > max_candidates() {
          return []
        }
      }
    }
    texts = out
  }
  if !fanned {
    return []
  }
  // A value that is empty names no path, so it is not a candidate either.
  let out : Array[String] = []
  for t in texts {
    if t.length() > 0 && !out.contains(t) {
      out.push(t)
    }
  }
  out
}

///|
/// One name in a rendered target replaced by one of its values. The renderer
/// keeps a bare `$Xy` distinct from `${X}y` by spelling the second one with
/// braces, so a name is either `$name` or `${name}` in the text and a bare one is
/// never followed by a name character.
fn replace_name(text : String, name : String, value : String) -> String {
  let chars : Array[Char] = []
  for c in text {
    chars.push(c)
  }
  let target : Array[Char] = []
  for c in name {
    target.push(c)
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '$' {
      // `${name}`
      if i + 1 < chars.length() && chars[i + 1] == '{' {
        let mut j = i + 2
        let mut k = 0
        while j < chars.length() && k < target.length() && chars[j] == target[k] {
          j += 1
          k += 1
        }
        if k == target.length() && j < chars.length() && chars[j] == '}' {
          sb.write_string(value)
          i = j + 1
          continue
        }
      }
      // `$name`
      let mut j = i + 1
      let mut k = 0
      while j < chars.length() && k < target.length() && chars[j] == target[k] {
        j += 1
        k += 1
      }
      if k == target.length() && k > 0 {
        sb.write_string(value)
        i = j
        continue
      }
    }
    sb.write_char(chars[i])
    i += 1
  }
  sb.to_string()
}

///|
/// One part of an assignment: nested commands are real commands, and a hole
/// anywhere in the assignment (index or value) makes its target uncertain.
fn Collector::scan_assign_part(
  self : Collector,
  name : String,
  p : WordPart,
  line : Int,
  closed? : Bool = false,
) -> Unit {
  match p {
    CmdSub(seq) | ProcSub(_, seq) => {
      // `x=$(cd /tmp; rm y)` moves only the substitution's directory: the
      // command after it is still relative to where we were, and the value it
      // set never arrives here.
      let saved = self.saved_cwd()
      let saved_binds = self.open_isolated()
      self.walk_seq(seq)
      self.close_isolated(saved_binds)
      self.restore_cwd(saved)
      self.note_temp_file(p, line)
    }
    Param(_) | ArithSub(_) =>
      // `closed` means the whole value came out as text the command line
      // spelled out, in which case there is no second fact to report.
      if !closed {
        self.push(Unknown, "${" + name + "}", true, line)
      }
    DQuote(inner) | Subscript(inner) =>
      for q in inner {
        self.scan_assign_part(name, q, line, closed~)
      }
    _ => ()
  }
}

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
  // The target is a word like any other, so it carries the same facts: `>~/x`
  // is `$HOME/x` (measured: bash expands it), and a hole in it is a hole.
  let arg = PathArg::of(r.target)
  let named = if arg.text == "" {
    // A redirect with no target word is a syntax error, but the answer still
    // has to name something.
    PathArg::lit("<unknown>", dynamic=arg.dynamic)
  } else {
    arg
  }
  match r.op {
    ROut | RAppend | RClobber | RInOut => self.push_path(Write, named, line)
    RIn => self.push_path(Read, named, line)
    // `>&word` duplicates a descriptor when word is one, and writes the file
    // otherwise. Measured: `bash -c 'echo hi >& out'` and the same in zsh both
    // write a file called out, and we used to report nothing at all.
    RDupOut => if !is_fd_word(named.text) { self.push_path(Write, named, line) }
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
  // bash expands braces before it expands parameters, so `x='{a,b}'; rm $x`
  // names one file with braces in it while `rm -rf {a,b}` names two. The braces
  // therefore come out first and the values go in after.
  let s = self.brace_simple(s)
  // Values the command line established go in before the command is read, so
  // `x=dist; rm -rf $x` names a path instead of a hole. bash expands a
  // command's own words before the assignments spelled in front of it take
  // effect (measured: `x=old; x=new echo "$x"` prints `old`), so the table in
  // use here is the one from before this command.
  let s = self.resolved_simple(s)
  for a in s.assigns {
    // A value that comes out as plain text is a closed set, and the hole it
    // used to report is the same fact spelled twice.
    let closed = value_texts(a.value, self.binds).length() > 0
    for p in a.index {
      self.scan_assign_part(a.name, p, line, closed=false)
    }
    for p in a.value {
      self.scan_assign_part(a.name, p, line, closed~)
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
  // What the assignments in this statement do to the shell's own parameters.
  // A bare `x=a` statement sets it, and everything after it sees that value.
  // An assignment in front of a command does not outlive the command
  // (measured: `x=old; x=new echo hi; echo $x` prints `old`), so that case
  // leaves the table alone rather than dropping what it held — which is bash's
  // default mode, the one this tool models.
  match decl_action(s) {
    SetsValue =>
      for a in s.assigns {
        self.note_assign(a)
      }
    OtherValue =>
      for a in s.assigns {
        // `let x=a` and `declare -i x=1+2` leave a value this tool cannot name.
        self.poison_value(a.name)
      }
    NoVariable =>
      if s.words.length() == 0 {
        for a in s.assigns {
          self.note_assign(a)
        }
      }
  }
  self.note_command_writes(s)
}

///|
/// Walk a word: command substitutions inside it are real commands.
fn Collector::walk_word(self : Collector, w : Word) -> Unit {
  // A command substitution is its own process: a `cd` inside it is gone by the
  // time the surrounding command line continues, and so is a value it set.
  for seq in w.subcommands() {
    let saved = self.saved_cwd()
    let saved_binds = self.open_isolated()
    self.walk_seq(seq)
    self.close_isolated(saved_binds)
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
