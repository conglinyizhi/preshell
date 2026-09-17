///|
/// shaudit — audit a bash command line without running it.
///
///   shaudit 'rm -rf /'            full report (JSON)
///   shaudit --impact 'make -j8'   only the blast radius
///   shaudit --shadow 'cat <<EOF'  dump the syntax tree
///   shaudit --scan "$(cat f.sh)"  one line: parse status + issue count
///   shaudit --bench=2000          timing loop
fn main {
  let argv = @env.args()
  let mut shadow = false
  let mut scan = false
  let mut impact_only = false
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
    if a == "--impact" {
      impact_only = true
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
  if rest.length() == 0 {
    println(
      "usage: shaudit [--shadow|--impact|--scan|--bench=N] [-c] <command>",
    )
    return
  }
  let src = rest.join(" ")
  if shadow {
    let (seq, errors) = @lib.parse(src)
    println(@json.to_json(seq).stringify(indent=2))
    for e in errors {
      println("issue: \{e}")
    }
    return
  }
  let report = @lib.check(src, @lib.AuditConfig::default())
  if impact_only {
    println(@json.to_json(report.impact).stringify(indent=2))
    return
  }
  if scan {
    // One machine-readable line for tools/corpus/run.sh, then one line per
    // issue. The harness keys on the message only, so keep "issue: <message>"
    // exact and put the location after it.
    println(
      "status=\{Repr(report.status)} issues=\{report.issues.length()} findings=\{report.findings.length()}",
    )
    for issue in report.issues {
      println("issue: \{issue.message} (line \{issue.line})")
    }
    return
  }
  println(@json.to_json(report).stringify(indent=2))
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
  let mut findings = 0
  for _ in 0..<rounds {
    for src in corpus {
      findings += @lib.check(src, @lib.AuditConfig::default()).findings.length()
    }
  }
  let t1 = @env.now()
  let n = rounds * corpus.length()
  let ms = (t1 - t0).to_int()
  println(
    "parsed \{n} commands in \{ms} ms  (\{ms * 1000 / n} us/cmd, \{findings} findings)",
  )
}
