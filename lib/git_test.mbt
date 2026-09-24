///|
/// git, against the measured table in lib/git.mbt.
///
/// Every expectation here comes from a scenario that was actually run: 26 of
/// them under an LD_PRELOAD shim plus a before/after directory snapshot (git
/// 2.55.0). The two claims worth guarding hardest are the empty ones -- a
/// read-only subcommand must report no write at all, and `git clean` in a
/// repository with nothing to clean must not report a delete -- because those
/// are the ones a caller will act on.
///
/// Codes as elsewhere: R read, W write, D delete, N network, S spawn,
/// U unknown. `Exec` is left out of `touched`.
test "read-only subcommands report no writes" {
  for
    c in [
      "git status", "git status --porcelain", "git diff", "git log --oneline", "git rev-parse HEAD",
      "git blame a.txt", "git clean -n", "git clean --dry-run",
    ] {
    inspect(touched(c), content="R:.")
    debug_inspect(@lib.analyze(c).status, content="Complete")
  }
}

///|
test "clean deletes only when it was asked to" {
  // Measured: `-n` deletes nothing; without `-f` a real run refuses; `-fdx`
  // deletes the untracked and ignored files, which is a set static analysis
  // cannot name, so it is reported as the repository plus a hole.
  inspect(touched("git clean -fdx"), content="R:. D:.")
  inspect(touched("git clean -fd"), content="R:. D:.")
  inspect(touched("git clean"), content="R:.")
  inspect(@lib.analyze("git clean -fdx").impact.uncertain, content="true")
}

///|
test "working-tree writers say the set is not closed" {
  // Measured: which files a checkout or a reset overwrites depends on the two
  // trees, so the answer is the repository plus `dynamic`, never a guess.
  inspect(touched("git checkout main"), content="W:. W:.git")
  inspect(touched("git reset --hard"), content="W:. W:.git")
  inspect(touched("git stash"), content="W:. W:.git W:.git/refs/stash")
  inspect(touched("git pull"), content="W:. W:.git")
  inspect(@lib.analyze("git reset --hard").impact.uncertain, content="true")
}

///|
test "a named path is reported exactly" {
  inspect(touched("git checkout -- p.txt"), content="W:p.txt W:.git/index")
  inspect(touched("git rm p.txt"), content="D:p.txt W:.git/index")
  inspect(touched("git add p.txt"), content="R:p.txt W:.git")
  inspect(touched("git branch newb"), content="W:.git/refs/heads/newb W:.git")
  inspect(
    touched("git checkout -b newb"),
    content="W:.git/refs/heads/newb W:.git/HEAD",
  )
}

///|
test "a repository somewhere else keeps its prefix" {
  inspect(touched("git -C sub status"), content="R:sub")
  inspect(
    touched("git -C sub rm p.txt"),
    content="D:sub/p.txt W:sub/.git/index",
  )
  // A config override is skipped, not mangled into the subcommand.
  inspect(touched("git -c core.pager=cat status"), content="R:.")
}

///|
test "clone reads its source and writes its destination" {
  inspect(touched("git clone /src dst"), content="R:/src W:dst")
  // A URL is a network contact, and the host is the part worth naming.
  inspect(
    touched("git clone https://example.com/x.git dst"),
    content="N:example.com W:dst",
  )
  // The destination derives from the source name, so it is a hole.
  inspect(@lib.analyze("git clone /src").impact.uncertain, content="true")
}

///|
test "a remote name is a hole, and an unknown subcommand is unmodelled" {
  // `origin` resolves through .git/config, which static analysis does not read.
  inspect(touched("git fetch origin"), content="W:.git U:origin")
  inspect(
    touched("git fetch https://example.com/x.git"),
    content="W:.git N:example.com",
  )
  // A subcommand with no entry stays unmodelled rather than half-modelled.
  let unknown = @lib.analyze("git filter-branch --all")
  inspect(unknown.impact.uncertain, content="true")
  debug_inspect(@lib.analyze("git status").impact.uncertain, content="false")
}
