///|
/// The two documents this binary carries: the short usage text for a person at a
/// terminal, and the machine-readable contract for a caller that has the binary
/// and nothing else.
///
/// Both are prose the tool vouches for. When the wire format changes, these
/// change with it — the point of the contract is that nobody has to
/// reverse-engineer the protocol from behaviour.

///|
/// A command line this tool refuses to read. The reason goes to stderr first,
/// then the usage text, and the status says no report was produced.
async fn usage_error(message : String) -> Unit {
  @stdio.stderr.write("PreShell: \{message}\n\n")
  usage()
  exit(usage_exit_code)
}

///|
async fn usage() -> Unit {
  let text =
    #|PreShell — what a shell command touches, as JSON. It passes no judgement.
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
    #|  --cwd=PATH  the base every relative path in the input is resolved
    #|              against. Must be absolute. It is a starting point, not a
    #|              cd: it adds no effect, and a cd in the command overrides it.
    #|              Required by the caller contract: without it the tool falls
    #|              back to its own current directory and says so in a note
    #|  --payload   carry the text a program reads as its own source, when the
    #|              command line has it: python3 -c '<code>', python3 - <<'PY'.
    #|              Off by default. Only for programs that take their source as
    #|              an argument or on stdin; each text is capped at 4096 bytes
    #|  --payload-max=N
    #|              turn payloads on and keep at most N bytes of each text
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
    #|  --version   the tool version, as JSON
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
    #|  impact.vars      the variables those targets read. Each effect carries its
    #|                   own vars. The tool never reads the environment, so the
    #|                   name is what it hands over: substitute HOME and $HOME/x
    #|                   resolves. Substitute only the names it reports; a name
    #|                   the command line itself set is resolved here
    #|  effect.candidates the paths a hole could be, when the input left a name
    #|                   with several possible values. Possibilities, not facts:
    #|                   the target stays a hole and vars stays the name to look up
    #|  impact.uncertain read this first. true means the effect list is not a
    #|                   closed set, and an empty list must not be read as
    #|                   "touches nothing"
    #|  impact.cwd       the base the paths in this report were resolved
    #|                   against. Paths come back absolute except when an
    #|                   absolute path does not exist yet: after a cd whose
    #|                   destination could not be modelled, or when the first
    #|                   segment is expanded at run time ($HOME/x, ~/x). Those
    #|                   stay as written and uncertain is true
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
fn contract_json() -> Json {
  let doc = "https://github.com/conglinyizhi/preshell/blob/main/docs/integration.md"
  Json::object({
    "tool": Json::string("preshell"),
    "version": Json::string(tool_version()),
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
    "paths": Json::object({
      "base": Json::string(
        "pass --cwd=PATH (absolute): every relative path in the input is resolved against it and reported as an absolute path",
      ),
      "vars": Json::string(
        "every effect carries vars, the names its own target reads; impact.vars is the deduplicated union. The tool never reads the environment, so the name is what it hands over: substitute it and $HOME/x resolves. Substitute only the reported names, because in a target that is not dynamic the $ is literal text. A name the command line itself set (x=dist; rm -rf $x, or a for list spelled out in the input) is resolved here and not reported, and a for body is walked once per word while the same fact on the same line is reported once. ~ is HOME, ~+ is PWD, ~- is OLDPWD; ~user and ~N have no name a caller could look up. write_roots can contain a name too",
      ),
      "required": Json::string(
        "--cwd is required by this contract. Without it the tool uses its own current directory as the base and attaches a Note saying so, which also marks the impact uncertain",
      ),
      "always_absolute": Json::string(
        "paths are reported absolute, with two exceptions that stay as written and set impact.uncertain: a path after a cd whose destination cannot be modelled, and a path whose first segment is expanded at run time ($HOME/x, ~/x), because a parameter's value is used as it stands and may itself be absolute",
      ),
      "cd_scope": Json::string(
        "cd affects the rest of the same command line; a subshell, a command substitution, a pipeline element and a script handed to another shell get their own copy, and consecutive cds accumulate",
      ),
      "no_base": Json::string(
        "after a cd whose destination cannot be modelled (cd $DIR), the base is unknown: those paths stay as written and impact.uncertain is set, so a missing base never passes as no change",
      ),
      "origin": Json::string(
        "an effect whose target came from a value the command line set carries origin: the reference as written, as in x=/usr/bin/jq; $x -n 1 where the Exec names /usr/bin/jq and origin is $x. Absent when the target is what the word says. It is rendered the way a hole is, so a caller can match it against the command text",
      ),
      "payload": Json::string(
        "an Exec/Spawn may carry payload: the text this program reads as its own source, when the command line has it (python3 -c '<code>', python3 - <<'PY'). Off by default; turn it on with --payload, or --payload-max=N to cap each text at N bytes (default 4096). {source, flag?, delimiter?, text, bytes, truncated}: source is flag or heredoc, text is as written with expansions left alone, bytes is the whole text's length in UTF-8 bytes and truncated says whether text is a prefix of it. The tool never interprets the text, and modeled keeps its meaning. Only programs whose arguments are their source get one; a pipe carries none, because its text is not in this command line",
      ),
      "candidates": Json::string(
        "an effect may carry candidates: the paths its hole could be, when the input left a name with several possible values (if c; then x=a; else x=b; fi; rm $x). They are possibilities, not facts — target stays the hole and dynamic stays true, so a caller deciding on facts keeps using target plus vars. The list is exhaustive or absent: a value a while body may have set carries none, a set past eight paths is left out rather than truncated, and a possibility that names no path (an unset or empty name) is not listed",
      ),
    }),
    "how_to_read": Json::string(
      "read impact.uncertain first: true means the effect list is not a closed set, and an empty list does not mean \"touches nothing\"",
    ),
  })
}
