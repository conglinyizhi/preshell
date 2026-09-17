///|
/// preshell — report what a shell command touches. No verdicts.
///
/// The contract callers rely on is deliberately small:
///
///   stdin      the command line, verbatim (preferred: no argv limits, and no
///              shell gets to re-quote it on the way in)
///   stdout     exactly one JSON object, nothing else
///   stderr     usage, help and diagnostics — never mixed into stdout
///   exit code  0 when a report was produced, non-zero when the tool itself
///              could not run. There is no exit code that means "dangerous":
///              a caller reads the JSON, never the status.
///
/// argv is accepted as a convenience for interactive use:
///
///   preshell 'rm -rf build/'          analyse the arguments
///   preshell < script.sh              analyse stdin (what callers should do)
///   preshell --version                tool and schema version, as JSON
///   preshell --help                   this text, on stderr
///
/// Developer modes, not part of the caller contract:
///
///   --pretty                      indent the JSON for humans
///   --shadow '<cmd>'              dump the syntax tree
///   --scan '<cmd>'                one line: status, issue count, effects
///   --bench=N                     timing loop
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
    if a == "--help" || a == "-h" {
      usage()
      return
    }
    if a == "--version" {
      println(
        Json::object({
          "tool": Json::string("preshell"),
          "version": Json::string(tool_version()),
          "schema": Json::number(@lib.report_version().to_double()),
        }).stringify(),
      )
      return
    }
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
  let from_argv = rest.length() > 0
  // Read stdin once, as bytes. Both the report path and the developer modes use
  // it: reading it twice, or letting --shadow see an empty string, is how
  // `preshell --shadow < script` silently printed an empty tree.
  let stdin_bytes : Bytes? = if from_argv {
    None
  } else {
    Some(@stdio.stdin.read_all().binary())
  }
  let src = if from_argv {
    rest.join(" ")
  } else {
    @lib.decode_command(stdin_bytes.unwrap()).0
  }
  if src.trim().length() == 0 {
    usage()
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
  // stdin is analysed from its bytes: that is the path a subprocess caller
  // uses, and the only one that sees exactly what arrived (bar the null bytes
  // the shell itself would drop).
  let report = if from_argv {
    @lib.analyze(src)
  } else {
    @lib.analyze_bytes(stdin_bytes.unwrap())
  }
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
fn tool_version() -> String {
  "0.1.0"
}

///|

///|
async fn usage() -> Unit {
  let text =
    #|preshell — report what a shell command touches (no verdicts)
    #|
    #|usage: preshell [options] [<command>]
    #|       preshell < script.sh          # preferred: the command comes from stdin
    #|
    #|  --version    print tool and schema version as JSON
    #|  --help       this text
    #|  --pretty     indent the JSON for humans
    #|  --shadow     dump the syntax tree (developer mode)
    #|  --scan       one line of status, then any issues (developer mode)
    #|  --bench=N    timing loop (developer mode)
    #|
    #|stdout carries exactly one JSON object; everything here goes to stderr.
    #|
  @stdio.stderr.write(text)
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
