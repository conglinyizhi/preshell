///|
/// Working-directory tracking.
///
/// This exists because "which files are affected" is not answerable without it:
/// `cd /tmp && rm -rf x` removes `/tmp/x`, not `x` wherever the caller happens
/// to be. Nothing here touches the file system; the only directory that is ever
/// known is one the command line itself named.
///
/// Scope follows the shell: a subshell, a command substitution and each element
/// of a multi-command pipeline get a copy, everything else shares the parent's.
fn Collector::saved_cwd(self : Collector) -> String? {
  self.cwd
}

///|
fn Collector::restore_cwd(self : Collector, saved : String?) -> Unit {
  self.cwd = saved
}

///|
/// Apply a modelled `cd` to the current directory. `Some(None)` marks "we can
/// no longer say what the directory is", which is a fact the caller needs.
fn Collector::change_dir(self : Collector, arg : String?, line : Int) -> Unit {
  match arg {
    None => {
      // `cd` with no argument, `cd -`, `cd $DIR`: the destination is unknown.
      self.cwd = None
      self.uncertain = true
      self.push(Unknown, "cd to an unknown directory", true, line)
    }
    Some(dir) =>
      match self.cwd {
        Some(base) =>
          self.cwd = Some(
            if dir.has_prefix("/") {
              normalize_path(dir)
            } else {
              normalize_path(base + "/" + dir)
            },
          )
        None =>
          // A relative `cd` from an unmodelled directory stays unmodelled.
          if dir.has_prefix("/") {
            self.cwd = Some(normalize_path(dir))
          } else {
            self.cwd = None
          }
      }
  }
}

///|
/// Where a path in this report actually points, given the directories the
/// command line itself changed into. A relative path with no modelled `cd` is
/// returned as written: the caller's own working directory is what it is
/// relative to, and that is the caller's knowledge, not ours.
pub fn Collector::resolve(self : Collector, p : String) -> String {
  if p.has_prefix("/") || p == "" {
    return p
  }
  match self.cwd {
    None => p
    Some(base) => normalize_path(base + "/" + p)
  }
}
