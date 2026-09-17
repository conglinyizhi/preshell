///|
/// shaudit — report what a shell command touches. No verdicts.
///
/// Input: a command line, from argv or from stdin.
/// Output: one JSON object on stdout (see `lib/status.mbt` for the shape).
///
///   shaudit 'rm -rf build/'          analyse the arguments
///   shaudit < script.sh              analyse stdin (preferred: no argv limits,
///                                    no shell re-quoting of the command)
///   shaudit --pretty 'make -j8'      indent the JSON for humans
///   shaudit --shadow '<cmd>'         dump the syntax tree
///   shaudit --scan '<cmd>'           one line: parse status and issue count
///   shaudit --bench=2000             timing loop
///
/// Exit codes describe this program, never the command it was given: 0 when a
/// report was produced, non-zero when the tool itself could not run.
async fn main {
  let argv = @env.args()
  let mut shadow = false
  let mut scan = false
  let mut pretty = false
  let mut bench = 0
  let rest : Array[String] = []
  let mut i = 0
  for a in argv {
    if i == 0 {
      i += 1
      continue
    }
    i += 1
    if a == "--shadow" {
      shadow = true
      continue
    }
    if a == "--scan" {
      scan = true
      continue
    }
    if a == "--pretty" {
      pretty = true
      continue
    }
    if a == "--bench" {
      bench = 1000
      continue
    }
    if a.has_prefix("--bench=") {
      bench = digits_of(a.unsafe_substring(start=8, end=a.length()))
      continue
    }
    if a == "-c" {
      continue
    }
    rest.push(a)
  }
  if bench > 0 {
    bench_corpus(bench)
    return
  }
  let src = if rest.length() > 0 {
    rest.join(" ")
  } else {
    // stdin: the whole script, verbatim. Callers should prefer this over argv:
    // it has no length limit and the command is not re-quoted by a shell on
    // the way in.
    @stdio.stdin.read_all().text()
  }
  if src.trim().length() == 0 {
    println("usage: shaudit [--pretty|--shadow|--scan|--bench=N] [<command>]")
    println("       without <command>, the command is read from stdin")
    return
  }
  if shadow {
    let (seq, errors) = @lib.parse(src)
    println(@json.to_json(seq).stringify(indent=2))
    for e in errors {
      println("issue: \{e}")
    }
    return
  }
  let report = @lib.analyze(src)
  if scan {
    // One machine-readable line for tools/corpus/run.sh, then one line per
    // issue. The harness keys on the message only, so keep "issue: <message>"
    // exact and put the location after it.
    println(
      "status=\{Repr(report.status)} issues=\{report.issues.length()} effects=\{report.impact.effects.length()}",
    )
    for issue in report.issues {
      println("issue: \{issue.message} (line \{issue.line})")
    }
    return
  }
  let indent = if pretty { 2 } else { 0 }
  println(@json.to_json(report).stringify(indent~))
}

///|
fn digits_of(s : String) -> Int {
  let mut v = 0
  for c in s {
    if c.is_ascii_digit() {
      v = v * 10 + (c.to_int() - '0'.to_int())
    }
  }
  if v == 0 {
    1000
  } else {
    v
  }
}

///|
/// Check a fixed corpus in a tight loop, for timing.
fn bench_corpus(rounds : Int) -> Unit {
  let corpus = [
    "git status && git diff --stat", "echo hello > /tmp/out && cat /tmp/out", "curl -s https://example.com | head -20",
    "find . -name '*.mbt' -exec grep -l foo {} \\;", "for f in src/*.mbt; do wc -l $f; done",
    "if [ -d build ]; then rm -rf build; fi", "cat <<EOF\n$(date)\nEOF", "x=$(echo a; echo b); echo \"$x\" | wc -l",
    "tar xzf pkg.tar.gz -C /tmp && ls /tmp/pkg", "case $1 in a) echo one;; b) echo two;;& *) echo other;; esac",
  ]
  let t0 = @env.now()
  let mut effects = 0
  for _ in 0..<rounds {
    for src in corpus {
      effects += @lib.analyze(src).impact.effects.length()
    }
  }
  let t1 = @env.now()
  let n = rounds * corpus.length()
  let ms = (t1 - t0).to_int()
  println(
    "parsed \{n} commands in \{ms} ms  (\{ms * 1000 / n} us/cmd, \{effects} effects)",
  )
}
