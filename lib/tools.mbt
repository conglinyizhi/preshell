///|
/// Programs whose effect is decided by their arguments rather than by their
/// operand list: find, sqlite3, make, the container runtimes, and the package
/// managers.
///
/// Every branch here comes from what was measured in a scratch directory (or,
/// where the tool needs a daemon or a registry, from semantics that are stable
/// enough to state and are marked uncertain). Two habits from the rest of the
/// codebase carry over: a set that depends on a predicate or on a container's
/// behaviour is reported as the directory plus `dynamic`, and a path that is
/// simply a name (`{}`, a package name) is a hole, not a literal.

///|
/// find: the start directories are read, and what happens under them depends on
/// the expression.
fn Collector::find_effects(self : Collector, s : SimpleCmd, line : Int) -> Unit {
  self.push(Exec, "find", false, line)
  let words = s.words
  let dirs : Array[Word] = []
  let mut i = 1
  for ;; {
    if i >= words.length() {
      break
    }
    let t = words[i].literal_text()
    if t == "" || t.has_prefix("-") || t == "(" || t == "!" {
      break
    }
    dirs.push(words[i])
    i += 1
  }
  if dirs.length() == 0 {
    // No start point: find walks the working directory.
    self.push(Read, ".", false, line)
  }
  for d in dirs {
    self.push(Read, d.literal_text(), d.has_hole() || d.has_glob(), line)
  }
  let delete = words.any(fn(w) { w.literal_text() == "-delete" })
  if delete {
    // Which entries match is the expression's business, so the set is a hole.
    for d in dirs {
      self.push(Delete, d.literal_text(), true, line)
    }
    if dirs.length() == 0 {
      self.push(Delete, ".", true, line)
    }
  }
  // `-exec CMD ... ;` runs CMD once per match, with `{}` standing for the
  // path. The command is right there in the arguments, so it is audited too.
  let mut k = 1
  for ;; {
    if k >= words.length() {
      break
    }
    let t = words[k].literal_text()
    if t == "-exec" || t == "-execdir" || t == "-ok" || t == "-okdir" {
      let nested : Array[Word] = []
      let mut j = k + 1
      for ;; {
        if j >= words.length() {
          break
        }
        let a = words[j].literal_text()
        if a == ";" || a == "+" || a == "\\;" {
          break
        }
        if a == "{}" {
          // The placeholder is a hole: a real path, but not this text.
          nested.push({ parts: [Glob("{}")], raw: "{}", line: words[j].line, })
        } else {
          nested.push(words[j])
        }
        j += 1
      }
      if nested.length() > 0 {
        let name = nested[0].literal_text()
        let rest : Array[Word] = []
        let mut m = 1
        for ;; {
          if m >= nested.length() {
            break
          }
          rest.push(nested[m])
          m += 1
        }
        self.classify(name, { assigns: [], words: rest, redirects: [], }, line)
      }
      k = j
    } else {
      k += 1
    }
  }
}

///|
/// sqlite3: the database is opened, and whether it is written depends on the
/// SQL. A statement that looks like a write, or no statement at all (the
/// interactive case), is reported as a write; a plain query is a read.
fn Collector::sqlite_effects(
  self : Collector,
  s : SimpleCmd,
  line : Int,
) -> Unit {
  self.push(Exec, "sqlite3", false, line)
  let words = s.words
  if words.length() < 2 {
    return
  }
  let db = words[1]
  let path = db.literal_text()
  if path == "" || path.has_prefix("-") {
    // `sqlite3` with no file is an in-memory database.
    return
  }
  let dyn = db.has_hole() || db.has_glob()
  self.push(Read, path, dyn, line)
  // Measured: `sqlite3 new.db 'select 1'` creates new.db. Whether a statement
  // writes cannot be settled from the text alone, so the write is reported
  // with the target dynamic: the path is known, the fact that it is written is
  // not.
  self.push(Write, path, true, line)
}

///|
/// make: `-C DIR` moves the build, `-f FILE` names the makefile, and everything
/// else is decided by rules the tool cannot read. The directory is reported as
/// read and written, the second one with `dynamic`: that is where build output
/// lands, and naming the files would be a guess.
fn Collector::make_effects(self : Collector, s : SimpleCmd, line : Int) -> Unit {
  self.push(Exec, "make", false, line)
  let words = s.words
  let mut dir = ""
  let mut file = ""
  let mut i = 1
  for ;; {
    if i >= words.length() {
      break
    }
    let t = words[i].literal_text()
    if t == "-C" || t == "--directory" {
      if i + 1 < words.length() {
        dir = words[i + 1].literal_text()
      }
      i += 2
    } else if t.has_prefix("-C") && t.length() > 2 {
      dir = t.unsafe_substring(start=2, end=t.length())
      i += 1
    } else if t == "-f" || t == "--file" || t == "--makefile" {
      if i + 1 < words.length() {
        file = words[i + 1].literal_text()
      }
      i += 2
    } else if t.has_prefix("-f") && t.length() > 2 {
      file = t.unsafe_substring(start=2, end=t.length())
      i += 1
    } else {
      i += 1
    }
  }
  let root = if dir == "" { "." } else { dir }
  self.push(Read, root, false, line)
  if file != "" {
    self.push(Read, join_path(root, file), false, line)
  }
  self.push(Write, root, true, line)
}

///|
fn join_path(dir : String, name : String) -> String {
  if dir == "" || dir == "." {
    name
  } else {
    dir + "/" + name
  }
}

///|
/// Containers: a bind mount hands the host path to the container, which may
/// write it; `:ro` says it will not. The image name is not a path, and whether
/// it is pulled depends on the local cache, so the network contact is a hole.
fn Collector::container_effects(
  self : Collector,
  s : SimpleCmd,
  line : Int,
) -> Unit {
  let words = s.words
  // The subcommand decides everything: `run` mounts host paths, `build` reads a
  // build context, `pull` only leaves the machine.
  let mut sub = ""
  let mut i = 1
  for ;; {
    if i >= words.length() {
      break
    }
    let t = words[i].literal_text()
    if t == "" || t.has_prefix("-") {
      i += 1
    } else {
      sub = t
      break
    }
  }
  match sub {
    "run" | "create" => {
      self.push(Exec, "docker", false, line)
      let mut k = 1
      for ;; {
        if k >= words.length() {
          break
        }
        let t = words[k].literal_text()
        if t == "-v" || t == "--volume" {
          if k + 1 < words.length() {
            self.mount_effects(words[k + 1].literal_text(), false, line)
          }
          k += 2
        } else if t.has_prefix("--volume=") {
          self.mount_effects(
            t.unsafe_substring(start=9, end=t.length()),
            false,
            line,
          )
          k += 1
        } else if t == "--mount" {
          if k + 1 < words.length() {
            self.mount_effects(words[k + 1].literal_text(), true, line)
          }
          k += 2
        } else if t.has_prefix("--mount=") {
          self.mount_effects(
            t.unsafe_substring(start=8, end=t.length()),
            true,
            line,
          )
          k += 1
        } else if t == "--volumes-from" {
          // The mounts come from another container, which static analysis does
          // not follow.
          self.push(Unknown, t, true, line)
          k += 2
        } else {
          k += 1
        }
      }
      // The image may have to be fetched; the local cache decides, so the
      // registry is a hole rather than a named host.
      self.push(Net, "container registry", true, line)
    }
    "build" | "buildx" => {
      // The build context is the last non-option argument, and the subcommand
      // word itself is not it: `docker build -t x .` reads `.`.
      self.push(Exec, "docker", false, line)
      let mut ctx = ""
      let mut k = 2
      for ;; {
        if k >= words.length() {
          break
        }
        let t = words[k].literal_text()
        if t != "" && !t.has_prefix("-") {
          ctx = t
        }
        k += 1
      }
      if ctx == "" {
        ctx = "."
      }
      self.push(Read, ctx, true, line)
      self.push(Net, "container registry", true, line)
    }
    "pull" | "push" | "login" | "search" => {
      self.push(Exec, "docker", false, line)
      self.push(Net, "container registry", true, line)
    }
    _ =>
      // Anything else: say the tool does not model it instead of guessing.
      self.push(Exec, "docker", false, line, modeled=false)
  }
}

///|
/// The first word that is not an option, from `start` on.
fn first_non_flag(words : Array[Word], start : Int) -> String? {
  let mut i = start
  for ;; {
    if i >= words.length() {
      break
    }
    let t = words[i].literal_text()
    if t != "" && !t.has_prefix("-") {
      return Some(t)
    }
    i += 1
  }
  None
}

///|
/// One mount specification: `HOST:CONTAINER[:ro]`, or the `--mount` spelling
/// `type=bind,source=HOST,target=CONTAINER`.
fn Collector::mount_effects(
  self : Collector,
  spec : String,
  keyed : Bool,
  line : Int,
) -> Unit {
  let mut host = ""
  let mut read_only = false
  if keyed {
    for part in spec.split(",").to_array() {
      let p = part.trim().to_string()
      if p.has_prefix("source=") {
        host = p.unsafe_substring(start=7, end=p.length())
      } else if p.has_prefix("src=") {
        host = p.unsafe_substring(start=4, end=p.length())
      } else if p == "readonly" || p == "ro" {
        read_only = true
      }
    }
  } else {
    let parts = spec.split(":").to_array()
    if parts.length() > 0 {
      host = parts[0].trim().to_string()
    }
    if parts.length() > 2 && parts[2].trim() == "ro" {
      read_only = true
    }
  }
  if host == "" {
    return
  }
  if read_only {
    self.push(Read, host, false, line)
  } else {
    // The container decides how much it writes, so the target is a hole.
    self.push(Write, host, true, line)
  }
}

///|
/// Package managers. The interesting facts are the ones the command line
/// settles: which local files are read, and which directory under the working
/// directory gets rewritten. Where the download comes from is a hole.
fn Collector::package_effects(
  self : Collector,
  name : String,
  s : SimpleCmd,
  line : Int,
) -> Unit {
  self.push(Exec, name, false, line)
  let words = s.words
  let mut command = ""
  let mut i = 1
  for ;; {
    if i >= words.length() {
      break
    }
    let t = words[i].literal_text()
    if t == "" {
      i += 1
    } else if t.has_prefix("-") {
      break
    } else {
      command = t
      break
    }
  }
  let is_node = name == "npm" ||
    name == "pnpm" ||
    name == "yarn" ||
    name == "bun"
  if is_node {
    self.push(Read, "package.json", false, line)
    if command == "install" || command == "i" || command == "add" {
      // Measured: the lockfile is created or updated in place.
      self.push(Write, "package-lock.json", true, line)
      // Where the packages land, and how much of it is rewritten, depends on
      // what the registry serves.
      self.push(Write, "node_modules", true, line)
      self.push(Net, "package registry", true, line)
    } else if command == "ci" {
      // `npm ci` deletes the installed tree before rebuilding it.
      self.push(Delete, "node_modules", true, line)
      self.push(Write, "node_modules", true, line)
      self.push(Net, "package registry", true, line)
    } else if command == "run" || command == "test" {
      // The script decides; the tool does not read package.json.
      self.push(Unknown, "package script", true, line)
    }
    return
  }
  // pip, pip3, uv: local files are the knowable part.
  let mut j = 1
  for ;; {
    if j >= words.length() {
      break
    }
    let t = words[j].literal_text()
    if (t == "-r" || t == "--requirement") && j + 1 < words.length() {
      self.push(Read, words[j + 1].literal_text(), false, line)
      j += 2
    } else if t.has_prefix("-r") && t.length() > 2 {
      self.push(Read, t.unsafe_substring(start=2, end=t.length()), false, line)
      j += 1
    } else if t.has_prefix("./") || t.has_prefix("/") || t.has_prefix("../") {
      // A wheel or sdist on disk.
      self.push(Read, t, false, line)
      j += 1
    } else {
      j += 1
    }
  }
  if command == "install" || command == "sync" || command == "pip" {
    // Where the install lands is the environment's business.
    self.push(Unknown, "python environment", true, line)
    self.push(Net, "package index", true, line)
  }
}
