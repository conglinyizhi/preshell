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
  /// The paths this target could be, when the command line left a name with more
  /// than one possible value: `if c; then x=a; else x=b; fi; rm $x` deletes one
  /// of two paths. Empty for a target that is what it says. This is a set of
  /// *possibilities*, not a list of things that happen: nothing here is a fact
  /// on its own, and `target` stays the hole it was.
  candidates : Array[String]
  /// The reference the target was written as, when a value the command line set
  /// went into it: `$x` for `/usr/bin/jq` in `x=/usr/bin/jq; $x -n 1`. Absent
  /// when the target is what the word says, which is why this is an `Option` and
  /// not an empty string: the caller looks it up in the command text by exact
  /// match, and an empty one would match every literal path.
  origin : String?
  /// True when the target is not a closed set: it has a hole or a glob.
  dynamic : Bool
  /// Only meaningful for `Exec`. False means: this program ran, and what it
  /// touches is decided inside it, so everything else in this report is a
  /// *lower bound*. `git pull` writing `.git/` is not missing from the answer
  /// by oversight; it is outside what this tool models, and saying so is the
  /// point.
  modeled : Bool
  line : Int
  /// The text this program reads as its own source, when the command line
  /// carries it and the caller asked for payloads (`--payload`). Absent
  /// otherwise, including for every program that does not interpret its
  /// arguments. See payload.mbt.
  payload : Payload?
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

///|
struct Collector {
  /// Every effect the report holds, in the order it found them. The same fact is
  /// only in here once (see `Collector::seen`).
  items : Array[Effect]
  /// One hash per item, parallel to it, so the duplicate check is a comparison of
  /// integers most of the time.
  hashes : Array[Int]
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
  /// What the command line established for its own parameters: the values each
  /// name may hold, and the scopes that decide how far that reaches. See
  /// bind.mbt.
  mut binds : Array[(String, Array[String])]
  /// How many bytes of a program's own source text to carry, or None when the
  /// caller did not ask for payloads at all. See payload.mbt.
  payload_max : Int?
}

///|
pub fn impact(
  seq : Seq,
  dialect? : Dialect = Bash,
  base_cwd? : String? = None,
  payload_max? : Int? = None,
) -> Impact {
  let c : Collector = {
    items: [],
    hashes: [],
    roots: [],
    dropped: 0,
    uncertain: false,
    depth: 0,
    dialect,
    vars: [],
    binds: [],
    payload_max,
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
/// Whether this exact effect is already in the report.
///
/// The hash is a prefilter only: equality is decided on the fields, so a
/// collision costs one comparison and nothing else.
fn Collector::seen(self : Collector, e : Effect) -> Bool {
  let h = effect_hash(e)
  for i, hh in self.hashes {
    if hh == h && same_effect(self.items[i], e) {
      return true
    }
  }
  false
}

///|
fn effect_hash(e : Effect) -> Int {
  let mut h = 16777619
  h = (h ^ e.line) * 16777619
  h = (h ^ kind_code(e.kind)) * 16777619
  h = (h ^ (if e.dynamic { 1 } else { 0 })) * 16777619
  h = (h ^ (if e.modeled { 1 } else { 0 })) * 16777619
  h = (h ^ e.vars.length()) * 16777619
  h = (h ^ e.candidates.length()) * 16777619
  for c in e.target {
    h = (h ^ c.to_int()) * 16777619
  }
  // Two commands on one line can name the same program and run different
  // source: `python3 -c a; python3 -c b`. Without payloads they are the same
  // fact and collapse (that is what dedupe is for); with them they are two.
  match e.payload {
    None => ()
    Some(p) =>
      for c in p.text {
        h = (h ^ c.to_int()) * 16777619
      }
  }
  h
}

///|
fn kind_code(k : EffectKind) -> Int {
  match k {
    Exec => 1
    Read => 2
    Write => 3
    Delete => 4
    Net => 5
    Spawn => 6
    Unknown => 7
  }
}

///|
/// The same fact: every field a caller could read, so nothing distinct is
/// collapsed by accident.
fn same_effect(a : Effect, b : Effect) -> Bool {
  a.kind == b.kind &&
  a.target == b.target &&
  a.line == b.line &&
  a.dynamic == b.dynamic &&
  a.modeled == b.modeled &&
  a.payload == b.payload &&
  same_strings(a.vars, b.vars) &&
  same_strings(a.candidates, b.candidates)
}

///|
fn same_strings(a : Array[String], b : Array[String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i += 1
  }
  true
}

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
  candidates? : Array[String] = [],
  origin? : String? = None,
  payload? : Payload? = None,
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
  let effect : Effect = {
    kind,
    target: resolved,
    vars,
    // The candidates are paths like the target, so they are anchored the same
    // way: an unrooted target (`$HOME/x`) leaves them as written too.
    candidates: if unrooted {
      candidates
    } else {
      let out : Array[String] = []
      for c in candidates {
        out.push(self.resolve(c))
      }
      out
    },
    dynamic,
    modeled,
    line,
    payload,
    origin,
  }
  // The same fact twice is one fact: a loop body is walked once per word, so
  // `for f in a b; do rm x; done` reaches here with `Delete x` on the same line
  // twice, and a caller reading two identical lines learns nothing the first
  // one did not say. Collapsing it here rather than at the end also keeps the
  // duplicates from eating the effect budget. Two effects that differ in any
  // way, including the line they came from, are both kept.
  if self.seen(effect) {
    return
  }
  if self.items.length() >= max_effects() {
    self.dropped = self.dropped + 1
    self.uncertain = true
    // Roots still accumulate: they are cheap, deduplicated, and they are the
    // part a caller most often acts on.
  } else {
    self.hashes.push(effect_hash(effect))
    self.items.push(effect)
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
/// One redirection: the target is a path for `>` and `<`, plain data for a
/// here-document, and its holes always matter.

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
