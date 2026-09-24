///|
/// libc exit. The async package declares it the same way in its own examples;
/// a usage error has to be distinguishable from a report, and the only way to
/// say "this run produced nothing" is a non-zero status.
extern "C" fn exit(code : Int) = "exit"

///|
/// What an unusable command line answers with. 0 means "a report is on stdout",
/// so a usage error cannot also be 0.
let usage_exit_code : Int = 2

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
///              2 is a usage error (unknown option, unknown --shell value),
///              with the reason on stderr and nothing on stdout.
///
/// An empty command line is a command line: it gets a report saying nothing is
/// touched, not silence. Callers run this on whatever they were handed, and a
/// missing report is indistinguishable from a broken tool.
///
/// argv is accepted as a convenience for interactive use:
///
///   preshell 'rm -rf build/'          analyse the arguments
///   preshell < script.sh              analyse stdin (what callers should do)
///   preshell -- ls -la                after --, everything is the command
///   preshell --shell=probe < cmd      try each grammar, keep the first hit
///   preshell --stream < cmds.jsonl    many commands, one JSON string per line,
///                                     one report per line, in the same order
///   preshell --version                tool and schema version, as JSON
///   preshell --help                   this text, on stderr
///
/// In --stream, a line that is not a JSON string is refused with its own line
/// number and the run continues: a batch of 40000 commands should not be lost to
/// one bad line, and the count of reports still matches the count of requests.
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
  let mut shell : String? = None
  let mut evidence = false
  let mut stream = false
  let mut operands_started = false
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
    if a == "--man" {
      println(manual_plain)
      return
    }
    if a == "--man-markdown" {
      println(manual_markdown)
      return
    }
    if a == "--spec" {
      // 契约的机读形式。拿得到二进制、拿不到仓库的人和 agent，靠这个把接口问清楚。
      println(contract_json().stringify())
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
    if a == "--evidence" {
      evidence = true
      continue
    }
    if a == "--stream" {
      stream = true
      continue
    }
    if a == "--" && !operands_started {
      // Everything after this is the command, even if it looks like an option.
      operands_started = true
      continue
    }
    if a.has_prefix("--shell=") {
      let name = a.unsafe_substring(start=8, end=a.length())
      if !is_shell_choice(name) {
        usage_error("unknown --shell value: \{name}")
        return
      }
      shell = Some(name)
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
    // An option before the command that this tool does not know: refuse it.
    // Reading it as the command instead turned `preshell --prety` into a
    // report about a program called `--prety`, which is a silent wrong answer
    // for exactly the caller who cannot check it by eye.
    if !operands_started && a.length() > 1 && a.has_prefix("-") {
      usage_error("unknown option: \{a}")
      return
    }
    operands_started = true
    rest.push(a)
  }
  // --stream is a different shape of answer: one line in, one line out. The
  // developer modes all print something else, and --pretty alone would break the
  // framing, so they are refused together instead of producing output a caller
  // cannot parse line by line.
  if stream {
    if pretty || scan || shadow || evidence || bench > 0 {
      usage_error(
        "--stream cannot be combined with --pretty, --scan, --shadow, --evidence or --bench",
      )
      return
    }
    if rest.length() > 0 {
      usage_error(
        "--stream reads its commands from stdin; it takes no command argument",
      )
      return
    }
  }
  if bench > 0 {
    bench_corpus(bench)
    return
  }
  if evidence {
    // One message per line, for the dialect that --shell names. `probe` is not
    // a dialect, so this falls back to bash, the chain's first element.
    for m in @lib.syntax_evidence(dialect_for("", shell)) {
      println(m)
    }
    return
  }
  let probe = match shell {
    Some("probe") => true
    _ => false
  }
  if stream {
    stream_reports(shell, probe)
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
  // An empty command line is still a command line: it touches nothing, and
  // saying so is a report. This used to print the usage text on stderr and put
  // nothing at all on stdout while exiting 0, which left every subprocess
  // caller parsing an empty string. Exit 0 always carries one JSON object.
  // stdin is analysed from its bytes: that is the path a subprocess caller
  // uses, and the only one that sees exactly what arrived (bar the null bytes
  // the shell itself would drop).
  if shadow {
    // There is no single tree to dump under probe, so dump the grammar probe
    // would have settled on; the report modes carry the caveat instead.
    let dialect = if probe {
      @lib.probe_dialect(src)
    } else {
      dialect_for(src, shell)
    }
    let (seq, errors) = @lib.parse_dialect(src, dialect)
    println(@json.to_json(seq).stringify(indent=2))
    for e in errors {
      println("issue: \{e}")
    }
    return
  }
  let report = if probe {
    if from_argv {
      @lib.analyze_probe(src)
    } else {
      @lib.analyze_bytes_probe(stdin_bytes.unwrap())
    }
  } else {
    let dialect = dialect_for(src, shell)
    if from_argv {
      @lib.analyze_dialect(src, dialect)
    } else {
      @lib.analyze_bytes_dialect(stdin_bytes.unwrap(), dialect)
    }
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
/// The shell names `--shell=` accepts. An unknown one is refused rather than
/// quietly read as bash: the caller asked for a specific grammar, and guessing
/// a different one produces a report about the wrong language.
fn is_shell_choice(name : String) -> Bool {
  match name {
    "" | "auto" | "bash" | "sh" | "zsh" | "probe" => true
    _ => false
  }
}

///|
/// Which grammar to read when the caller does not pick one. The input's own
/// shebang is the best evidence there is; without one, bash, because that is
/// what a bare snippet almost always is.
fn dialect_for(src : String, named : String?) -> @lib.Dialect {
  // `auto` means "follow the shebang", the same as passing nothing at all.
  // Treating it as an unknown value and defaulting to bash silently ignored
  // the declaration, which the report then complained about.
  let sniff = match named {
    None => true
    Some(s) => s == "auto" || s == ""
  }
  if sniff {
    match @lib.declared_shell(src) {
      Some(name) =>
        match @lib.Dialect::from_shell_name(name) {
          Some(d) => d
          None => @lib.Dialect::Bash
        }
      None => @lib.Dialect::Bash
    }
  } else {
    match named {
      Some(s) =>
        match s {
          "bash" | "sh" => @lib.Dialect::Bash
          "zsh" => @lib.Dialect::Zsh
          _ => @lib.Dialect::Bash
        }
      None => @lib.Dialect::Bash
    }
  }
}

///|
fn tool_version() -> String {
  "0.2.0"
}

///|

///|
/// A command line this tool refuses to read. The reason goes to stderr first,
/// then the usage text, and the status says no report was produced.
async fn usage_error(message : String) -> Unit {
  @stdio.stderr.write("preshell: \{message}\n\n")
  usage()
  exit(usage_exit_code)
}

///|
async fn usage() -> Unit {
  let text =
    #|preshell — what a shell command touches, as JSON. It passes no judgement.
    #|
    #|usage: preshell [options] [<command>]
    #|       preshell < script.sh          one command from stdin (preferred)
    #|       preshell --stream < cmds      many commands, one per line
    #|
    #|example:
    #|  printf 'rm -rf build && tar czf out.tgz src\n' | preshell --pretty
    #|
    #|options:
    #|  --shell=S   how to read the input: auto (default), bash, zsh, probe
    #|              auto follows the shebang, then falls back to bash
    #|              probe tries the declared dialect first, then the others,
    #|              and names the one it used in the report
    #|  --pretty    indent the JSON for humans (single-shot mode only)
    #|  --stream    many commands: one request per line on stdin, one answer per
    #|              line on stdout, in the same order. A request is a JSON string,
    #|              or {"id":...,"command":"..."} whose answer comes back as
    #|              {"id":...,"report":{...}}. Every line is answered, so input
    #|              and output line up one for one.
    #|  --spec      this contract in machine-readable form, as JSON
    #|  --man       the full human manual, as plain text
    #|  --man-markdown
    #|              the full manual as Markdown, for agents and document tools
    #|  --version   tool and schema version, as JSON
    #|  --help      this text, on stderr
    #|
    #|the contract:
    #|  stdin       the command verbatim; a shell never gets to re-quote it
    #|  stdout      exactly one JSON object, or one per line under --stream
    #|  stderr      usage, help and diagnostics, never mixed into stdout
    #|  exit code   0 = the answers were produced, 2 = usage error (reason on
    #|              stderr, nothing on stdout), anything else = the tool itself
    #|              failed. No exit code means "dangerous": read the JSON.
    #|
    #|reading an answer:
    #|  status           Complete / Unsupported / Invalid: how much was understood
    #|  impact.effects   facts: Exec, Read, Write, Delete, Net, Spawn, Unknown
    #|  impact.uncertain read this first. true means the effect list is not a
    #|                   closed set, and an empty list must not be read as
    #|                   "touches nothing"
    #|  In --stream a refused line answers {"error":...,"line":N}. That is
    #|  deliberately not a report: it means the line was not a request, never
    #|  that the command is bad.
    #|
    #|calling it from a program — four things the caller must do:
    #|  1. serialize writes to stdin (POSIX makes only writes <= PIPE_BUF atomic)
    #|  2. buffer reads by newline; one read is not one line
    #|  3. ids must be unguessable, not sequential
    #|  4. do not let other child processes inherit the pipe fd (CLOEXEC)
    #|
    #|the full manual:
    #|  preshell --man            plain text, for reading
    #|  preshell --man-markdown   Markdown, for agents and document tools
    #|  man preshell              the same page, when preshell.1 is installed
    #|
    #|docs: https://github.com/conglinyizhi/preshell/blob/main/docs/integration.md
    #|      licence boundary, batch recipe, a runnable parent-process example
    #|
    #|developer modes (not part of the caller contract):
    #|  --scan      one line of status, then any issues
    #|  --shadow    dump the syntax tree
    #|  --bench=N   timing loop
    #|  --evidence  the syntax errors this dialect has evidence for
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

///|
/// stdin could not be read. That says nothing about the commands; the tool
/// itself did not run.
let io_exit_code : Int = 1

///|
/// Counters for a stream run, in a struct because the per-line answer has to
/// move them and a closure cannot mutate a captured `mut` local.
struct Counts {
  mut reports : Int
  mut errors : Int
}

///|
/// Answer one framed line: exactly one line of output, either a report or a
/// refusal. Nothing is skipped, so a caller can line up its input and its output
/// without counting anything.
async fn answer_stream_line(
  line : String,
  number : Int,
  shell : String?,
  probe : Bool,
  counts : Counts,
) -> Unit {
  match @lib.decode_stream_line(line) {
    Ok(request) => {
      let bytes = request.command
      let report = if probe {
        @lib.analyze_bytes_probe(bytes)
      } else {
        // The same two steps as the single-shot path: the dialect is chosen
        // from the text, so a shebang still decides under `auto`, and the
        // analysis runs on the bytes, so a NUL byte and invalid UTF-8 are
        // treated the way the shell treats them. Anything else would make the
        // two modes disagree about the same command.
        let (text, _) = @lib.decode_command(bytes)
        @lib.analyze_bytes_dialect(bytes, dialect_for(text, shell))
      }
      // The report goes out untouched: an id, when the caller used one, arrives
      // in an envelope around it, so the report itself stays the same object the
      // single-shot mode prints.
      write_report_line(
        @json.to_json(
          @lib.stream_report_json(@json.to_json(report), request.id),
        ).stringify(),
      )
      counts.reports += 1
    }
    Err(refused) => {
      @stdio.stderr.write("preshell: line \{number}: \{refused.message}\n")
      write_report_line(
        @lib.stream_error(refused.message, number, refused.id).stringify(),
      )
      counts.errors += 1
    }
  }
}

///|
/// One line of stdout, written straight to the descriptor.
///
/// `println` goes through a buffer: a single report is a few hundred bytes, so
/// nothing appears until the buffer fills or the process exits -- which would
/// make this mode batch-only and lose the thing it exists for. The async stdout
/// has no such buffer, and mixing the two in one process would also reorder the
/// output, so the stream path uses only this.
async fn write_report_line(text : String) -> Unit {
  @stdio.stdout.write(@utf8.encode(text + "\n"))
}

///|
/// Read one JSON string per line from stdin and answer one line per request.
///
/// Each report is written as soon as it is analysed, so a caller that keeps this
/// process alive gets the answer to a command before sending the next one. That
/// is the entire reason the mode exists: process startup costs about two hundred
/// times what the analysis does.
async fn stream_reports(shell : String?, probe : Bool) -> Unit {
  let framer = @lib.LineFramer::new()
  let counts : Counts = { reports: 0, errors: 0, }
  let chunk : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  let mut number = 0
  let mut read_failed = false
  for ;; {
    let n = @stdio.stdin.read(chunk, max_len=chunk.length()) catch { _ => -1 }
    if n < 0 {
      read_failed = true
      break
    }
    if n == 0 {
      break
    }
    for framed in framer.push(Bytes::from_array(chunk.exact_view(end=n))) {
      match framed {
        @lib.FramedLine::Line(line) => {
          number += 1
          answer_stream_line(line, number, shell, probe, counts)
        }
        @lib.FramedLine::TooLong => {
          // The line was dropped before it could be parsed, but it still
          // occupied a line: refusing it out loud keeps the caller's numbering
          // matching their input.
          number += 1
          let message = "line longer than \{@lib.max_stream_line()} bytes"
          @stdio.stderr.write("preshell: line \{number}: \{message}\n")
          write_report_line(
            @lib.stream_error(message, number, None).stringify(),
          )
          counts.errors += 1
        }
      }
    }
  }
  // A last line that ended at EOF rather than at a newline is still a request.
  match framer.finish() {
    Some(@lib.FramedLine::Line(line)) => {
      number += 1
      answer_stream_line(line, number, shell, probe, counts)
    }
    _ => ()
  }
  @stdio.stderr.write(
    "preshell: \{counts.reports} reports, \{counts.errors} lines refused\n",
  )
  if read_failed {
    @stdio.stderr.write("preshell: reading stdin failed\n")
    exit(io_exit_code)
  }
}

///|
/// The contract as data, for a caller that has the binary and nothing else.
///
/// This is prose the tool vouches for: when the wire format changes, this and
/// the help text change with it. It exists because the alternative is an agent
/// (or a person) reverse-engineering the protocol from behaviour.
fn contract_json() -> Json {
  let doc = "https://github.com/conglinyizhi/preshell/blob/main/docs/integration.md"
  Json::object({
    "tool": Json::string("preshell"),
    "version": Json::string(tool_version()),
    "schema": Json::number(@lib.report_version().to_double()),
    "doc": Json::string(doc),
    "one_line": Json::string(
      "Reports what a shell command touches. Facts, not a verdict: no policy, no allow/deny.",
    ),
    "modes": Json::array([
      Json::object({
        "name": Json::string("single"),
        "stdin": Json::string("one shell command, verbatim"),
        "stdout": Json::string("exactly one JSON report"),
      }),
      Json::object({
        "name": Json::string("stream"),
        "flag": Json::string("--stream"),
        "stdin": Json::string(
          "one request per line: a JSON string, or {\"id\":...,\"command\":\"...\"}",
        ),
        "stdout": Json::string(
          "one answer per line, same order: the report, or {\"id\":...,\"report\":{...}} when the request carried an id",
        ),
        "guarantee": Json::string(
          "every input line is answered exactly once, refusals included",
        ),
      }),
    ]),
    "exit_codes": Json::object({
      "0": Json::string("the answers were produced; read stdout"),
      "2": Json::string("usage error: reason on stderr, nothing on stdout"),
      "other": Json::string("the tool itself failed"),
      "note": Json::string(
        "no exit code means dangerous; the JSON is the answer, and stderr is never mixed into stdout",
      ),
    }),
    "refusal": Json::object({
      "shape": Json::string(
        "{\"error\":\"...\",\"line\":N} and, when the line carried an id, \"id\" too",
      ),
      "means": Json::string(
        "the line was not a request; it never means the command is bad",
      ),
      "note": Json::string(
        "a refusal is not a report: it has no version and no status",
      ),
    }),
    "client_obligations": Json::array([
      Json::string(
        "serialize writes to stdin: POSIX makes only writes <= PIPE_BUF atomic",
      ),
      Json::string("buffer reads by newline: one read is not one line"),
      Json::string(
        "ids must be unguessable, not sequential, or a forged answer can displace a real one",
      ),
      Json::string(
        "do not let other child processes inherit the pipe fd (CLOEXEC / close_fds)",
      ),
    ]),
    "how_to_read": Json::string(
      "read impact.uncertain first: true means the effect list is not a closed set, and an empty list does not mean \"touches nothing\"",
    ),
  })
}
