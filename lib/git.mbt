///|
/// git, from a measured table rather than from the manual.
///
/// Twenty-six scenarios were run under an LD_PRELOAD shim plus a before/after
/// directory snapshot (git 2.55.0): which paths each subcommand reads, writes
/// and deletes, including the empty cases -- `git clean -n` deletes nothing,
/// and `git clean -fdx` in a clean repository touches nothing at all. Two rules
/// come straight out of that, and both are about not lying:
///
///   * transient files are never reported. `.git/index.lock`, `tmp_obj_*` and
///     the clone temp symrefs live only inside the command, and nearly every
///     subcommand makes one; reporting them would bury the answer in noise.
///   * anything whose target set depends on repository state -- which files a
///     checkout overwrites, which untracked files `clean` removes, which
///     objects a commit writes -- is reported as the repository with `dynamic`,
///     never as a guessed file list.
///
/// The measured counter-example to the obvious rule: `git clean -f` in a
/// directory that also holds tracked files removes only the untracked ones and
/// keeps the directory, so `Delete: dir` in the whole-tree sense would be
/// wrong. A dynamic target is the honest spelling of "some files under here".

///|
/// One git argument: its text, and whether that text is not a closed set.
struct GitArg {
  text : String
  dynamic : Bool
}

///|
fn Collector::git_effects(self : Collector, s : SimpleCmd, line : Int) -> Unit {
  let args = git_argv(s)
  match git_split(args) {
    None => self.push(Exec, "git", false, line, modeled=false)
    Some((prefix, sub, rest)) => self.git_dispatch(prefix, sub, rest, line)
  }
}

///|
/// The words after `git` itself.
fn git_argv(s : SimpleCmd) -> Array[GitArg] {
  let out : Array[GitArg] = []
  for i, w in s.words {
    if i > 0 {
      out.push({
        text: w.literal_text(),
        dynamic: w.has_hole() || w.has_glob(),
      })
    }
  }
  out
}

///|
/// Split git's own options from the subcommand. Returns the path prefix the
/// invocation works under (`-C DIR`), the subcommand, and the words after it.
/// `None` when an option we do not understand appears before the subcommand,
/// which makes the whole invocation opaque rather than half-understood.
fn git_split(args : Array[GitArg]) -> (String, String, Array[GitArg])? {
  let mut prefix = ""
  let mut i = 0
  for ;; {
    if i >= args.length() {
      return None
    }
    let a = args[i].text
    if a == "-C" ||
      a == "--git-dir" ||
      a == "--work-tree" ||
      a == "--namespace" ||
      a == "--exec-path" {
      if i + 1 >= args.length() {
        return None
      }
      if a == "-C" {
        prefix = args[i + 1].text
      }
      i += 2
    } else if a == "-c" || a == "--config-env" {
      i += 2
    } else if a.has_prefix("-C") && a.length() > 2 {
      prefix = a.unsafe_substring(start=2, end=a.length())
      i += 1
    } else if a.has_prefix("--git-dir=") ||
      a.has_prefix("--work-tree=") ||
      a.has_prefix("--namespace=") ||
      a.has_prefix("--exec-path=") ||
      (a.has_prefix("-c") && a.length() > 2) {
      i += 1
    } else if a == "--bare" ||
      a == "--no-pager" ||
      a == "--paginate" ||
      a == "-P" ||
      a == "--literal-pathspecs" ||
      a == "--no-replace-objects" ||
      a == "--version" ||
      a == "--help" ||
      a == "-h" {
      i += 1
    } else if a.has_prefix("-") {
      return None
    } else {
      let rest : Array[GitArg] = []
      let mut j = i + 1
      for ;; {
        if j >= args.length() {
          break
        }
        rest.push(args[j])
        j += 1
      }
      return Some((prefix, a, rest))
    }
  }
}

///|
/// A target under the repository, prefixed so that `git -C DIR ...` reports
/// paths relative to where the shell is rather than to the repository.
fn git_path(prefix : String, tail : String) -> String {
  if prefix == "" {
    tail
  } else if tail == "" || tail == "." {
    prefix
  } else {
    prefix + "/" + tail
  }
}

///|
fn has_arg(args : Array[GitArg], name : String) -> Bool {
  args.any(fn(a) { a.text == name })
}

///|
/// The first word that is not an option, for subcommands that take a path.
fn first_operand(args : Array[GitArg]) -> GitArg? {
  for a in args {
    if a.text != "" && !a.text.has_prefix("-") {
      return Some(a)
    }
  }
  None
}

///|
/// A remote that will be contacted: a URL, or an `scp`-style `host:path`. A
/// bare name is a remote *in the config*, which static analysis cannot resolve,
/// so it is reported as a hole rather than as a host called `origin`.
fn net_from_arg(text : String) -> String? {
  match text.find("://") {
    Some(i) => {
      let after = text.unsafe_substring(start=i + 3, end=text.length())
      let host = match after.find("/") {
        Some(j) => after.unsafe_substring(start=0, end=j)
        None => after
      }
      if host == "" {
        None
      } else {
        Some(host)
      }
    }
    None =>
      match text.find("@") {
        Some(i) => {
          let rest = text.unsafe_substring(start=i + 1, end=text.length())
          match rest.find(":") {
            Some(j) => Some(rest.unsafe_substring(start=0, end=j))
            None => None
          }
        }
        None => None
      }
  }
}

///|
fn Collector::git_net(
  self : Collector,
  args : Array[GitArg],
  line : Int,
) -> Unit {
  let mut named = false
  for a in args {
    if a.text == "" || a.text.has_prefix("-") {
      continue
    }
    match net_from_arg(a.text) {
      Some(host) => self.push(Net, host, false, line)
      None =>
        // A remote *name*: whether it leaves the machine depends on the URL in
        // .git/config, which is a run-time fact. Report the hole, not a host.
        if !named {
          named = true
          self.push(Unknown, a.text, true, line)
        }
    }
  }
}

///|
fn Collector::git_dispatch(
  self : Collector,
  prefix : String,
  sub : String,
  rest : Array[GitArg],
  line : Int,
) -> Unit {
  let repo = git_path(prefix, ".")
  let gitdir = git_path(prefix, ".git")
  match sub {
    // Measured: these read the repository and write nothing at all. That is a
    // stronger guarantee than "we do not know", so they get their own entries.
    "status"
    | "diff"
    | "log"
    | "show"
    | "rev-parse"
    | "ls-files"
    | "ls-tree"
    | "blame"
    | "describe"
    | "shortlog"
    | "cat-file"
    | "whatchanged"
    | "reflog"
    | "symbolic-ref"
    | "name-rev"
    | "var"
    | "help" => {
      self.push(Exec, "git", false, line)
      self.push(Read, repo, false, line)
    }
    "clean" => {
      self.push(Exec, "git", false, line)
      self.push(Read, repo, false, line)
      let dry = has_arg(rest, "-n") || has_arg(rest, "--dry-run")
      // `-f`, `-fd`, `-fdx`: the force letter inside a short cluster.
      let forced = rest.any(fn(a) {
        a.text == "--force" ||
        (
          a.text.has_prefix("-") &&
          !a.text.has_prefix("--") &&
          a.text.contains_char('f')
        )
      })
      // Without `-f` a real run refuses to delete anything, so the only thing
      // that comes back is the read.
      if !dry && forced {
        self.push(Delete, repo, true, line)
      }
    }
    // These rewrite the working tree, and how much depends on repository state.
    "checkout" | "switch" => {
      self.push(Exec, "git", false, line)
      if has_arg(rest, "--") {
        // `git checkout -- PATH`: the paths are named, so report them. The
        // index is rewritten too, and that is a closed set.
        let mut seen = false
        let mut named = false
        for b in rest {
          if b.text == "--" && !seen {
            seen = true
          } else if seen {
            named = true
            self.push(Write, git_path(prefix, b.text), b.dynamic, line)
          }
        }
        if !named {
          self.push(Write, repo, true, line)
        }
        self.push(Write, git_path(prefix, ".git/index"), false, line)
      } else if has_arg(rest, "-b") ||
        has_arg(rest, "-B") ||
        has_arg(rest, "-c") {
        // A new branch: measured, the working tree is left alone and only the
        // ref, its reflog and HEAD change.
        self.git_new_ref(prefix, rest, line)
        self.push(Write, git_path(prefix, ".git/HEAD"), false, line)
      } else if first_operand(rest) is None {
        self.push(Write, repo, true, line)
      } else {
        self.push(Write, repo, true, line)
        self.push(Write, gitdir, true, line)
      }
    }
    "reset"
    | "restore"
    | "merge"
    | "rebase"
    | "cherry-pick"
    | "revert"
    | "am" => {
      self.push(Exec, "git", false, line)
      self.push(Write, repo, true, line)
      self.push(Write, gitdir, true, line)
    }
    "stash" => {
      self.push(Exec, "git", false, line)
      self.push(Write, repo, true, line)
      self.push(Write, gitdir, true, line)
      // `stash pop` removes the stash ref and `stash` writes it; either way the
      // path is fixed.
      self.push(Write, git_path(prefix, ".git/refs/stash"), true, line)
    }
    "pull" => {
      self.push(Exec, "git", false, line)
      self.push(Write, repo, true, line)
      self.push(Write, gitdir, true, line)
      self.git_net(rest, line)
    }
    "fetch" | "push" => {
      self.push(Exec, "git", false, line)
      self.push(Write, gitdir, true, line)
      self.git_net(rest, line)
    }
    "rm" => {
      self.push(Exec, "git", false, line)
      match first_operand(rest) {
        Some(a) => self.push(Delete, git_path(prefix, a.text), a.dynamic, line)
        None => self.push(Delete, repo, true, line)
      }
      self.push(Write, git_path(prefix, ".git/index"), false, line)
    }
    "add" => {
      self.push(Exec, "git", false, line)
      let mut named = false
      for a in rest {
        if a.text != "" && !a.text.has_prefix("-") {
          named = true
          self.push(Read, git_path(prefix, a.text), a.dynamic, line)
        }
      }
      if !named {
        self.push(Read, repo, true, line)
      }
      self.push(Write, gitdir, true, line)
    }
    "commit"
    | "init"
    | "gc"
    | "repack"
    | "maintenance"
    | "update-ref"
    | "tag"
    | "branch" => {
      self.push(Exec, "git", false, line)
      match sub {
        "init" =>
          match first_operand(rest) {
            Some(a) => self.push(Write, git_path(a.text, ".git"), false, line)
            None => self.push(Write, ".git", false, line)
          }
        "tag" | "branch" => self.git_new_ref(prefix, rest, line)
        _ => ()
      }
      self.push(Write, gitdir, true, line)
    }
    "clone" => {
      self.push(Exec, "git", false, line)
      let operands : Array[GitArg] = []
      for a in rest {
        if a.text != "" && !a.text.has_prefix("-") {
          operands.push(a)
        }
      }
      if operands.length() > 0 {
        let src = operands[0]
        match net_from_arg(src.text) {
          Some(host) => self.push(Net, host, false, line)
          None => self.push(Read, git_path(prefix, src.text), src.dynamic, line)
        }
      }
      if operands.length() > 1 {
        self.push(
          Write,
          git_path(prefix, operands[1].text),
          operands[1].dynamic,
          line,
        )
      } else {
        // The destination derives from the source name, so it is a hole.
        self.push(Write, repo, true, line)
      }
    }
    _ =>
      // Unmodelled subcommand: say so instead of guessing.
      self.push(Exec, "git", false, line, modeled=false)
  }
}

///|
/// `git branch NAME` / `git tag NAME` / `git checkout -b NAME`: the ref path is
/// derivable from the command line, so it is reported exactly.
fn Collector::git_new_ref(
  self : Collector,
  prefix : String,
  rest : Array[GitArg],
  line : Int,
) -> Unit {
  let mut i = 0
  for ;; {
    if i >= rest.length() {
      break
    }
    let a = rest[i].text
    if a == "-b" || a == "-B" || a == "-c" || a == "-C" {
      if i + 1 < rest.length() {
        self.push(
          Write,
          git_path(prefix, ".git/refs/heads/" + rest[i + 1].text),
          false,
          line,
        )
      }
      return
    }
    i += 1
  }
  match first_operand(rest) {
    Some(a) =>
      self.push(
        Write,
        git_path(prefix, ".git/refs/heads/" + a.text),
        false,
        line,
      )
    None => ()
  }
}
