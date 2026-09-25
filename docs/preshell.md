# PreShell

PreShell is a facts-only shell command analyzer. It reports what a command touches without executing the command or making an allow/deny decision.

## Synopsis

```text
preshell [options] [command]
preshell [options] < script.sh
preshell --stream < commands.jsonl
```

The preferred subprocess interface sends the command verbatim on stdin. The command is never re-quoted by a shell on the way in.

## Quick start

```bash
printf 'rm -rf build && tar czf out.tgz src\n' | preshell --pretty
preshell --spec
preshell --man | less
preshell --man-markdown
```

`preshell` never executes the command it receives, never reads the caller's disk, and never opens a network connection. It is an analyzer, not a sandbox or a policy engine.

## Options

- `--shell=S`: read the input as `auto` (default), `bash`, `zsh`, or `probe`. `auto` follows the shebang and otherwise uses bash. `probe` tries the declared dialect first and then the other supported dialect.
- `--cwd=PATH`: the base every relative path in the input is resolved against. It must be absolute. It is a starting point, not a `cd`, so it adds no effect and a `cd` in the command overrides it. It is required by the caller contract: without it the tool falls back to its own current directory and says so in a note.
- `--pretty`: indent the JSON in single-command mode.
- `--stream`: read one JSON request per line and write one answer per line.
- `--help-id`: list the registered warning codes, one per line.
- `--help-id=CODE`: what that warning means, how to clear it, and what it does to the report.
- `--spec`: print the machine-readable protocol contract as JSON.
- `--help`: print the short contract quick reference to stderr.
- `--man`: print this manual as plain text.
- `--man-markdown`: print this manual as Markdown.
- `--version`: print the tool and report schema version as JSON.

Developer-only modes are `--scan`, `--shadow`, `--bench=N`, and `--evidence`. They are not part of the integration contract.

## Single-command mode

```bash
printf '%s' 'rm -rf build' | preshell
preshell 'rm -rf build'
```

Standard output contains exactly one JSON report. Diagnostics and help go to standard error. Exit status `0` means the answer was produced; status `2` means a usage error; another non-zero status means the tool itself failed. No exit status means dangerous: read the JSON.

## Warning codes

An issue that carries a `code` is a registered warning; one without a code is a parser finding.

```json
{"kind":"Note","code":"W1","message":"no --cwd given: ...","line":0}
```

- Match on `code`, never on `message`: the text is prose and will be edited, the code will not.
- `preshell --help-id` lists every code. `preshell --help-id=W1` explains what it means, how to make it stop, and what it does to the report. `--spec` carries the same table as JSON.
- Every warning forces `impact.uncertain`.
- The table lives in `lib/warnings.mbt`. A new warning has to be registered there before it can be emitted, because the only way to add one takes a `WarnCode` rather than a string.

| code | slug | when it appears | how to clear it |
|---|---|---|---|
| `W0` | `internal-limit` | the tool hit a limit of its own or could not read its own environment: the effect or issue list was capped, a bounded recursion ran out of depth, or the current directory could not be read | nothing to change in the command; read the report as partial |
| `W1` | `base-inferred` | `--cwd` was absent, so the path base was inferred from this process's current directory | pass `--cwd=PATH` |

## Paths and pwd

Paths are reported **absolute**. PreShell never reads the file system, so the base they are resolved against has to come from somewhere, and that somewhere is the caller.

- Pass `--cwd=/a/b` and `rm -rf dist` reports `Delete: /a/b/dist`, with `impact.cwd` set to `/a/b`. The value must be absolute; a relative one is a usage error.
- `--cwd` is required by the caller contract. Without it the tool uses its own current directory as the base — which is the caller's directory whenever the caller spawned it without changing directory — and attaches a `Note` to every report saying so. That note also marks `impact.uncertain`, so the answer is not presented as a closed one.
- `--cwd` is a starting point, not a movement: it produces no effect, and a `cd` inside the command takes precedence.
- `cd` affects the rest of the same command line only. A subshell, a command substitution, a pipeline element and a script handed to another shell each get their own copy, and consecutive `cd`s accumulate in order.
- The one case that cannot be absolute is a path after a `cd` whose destination cannot be modelled, such as `cd $DIR`. Those paths stay as written and `impact.uncertain` is set, so the gap is visible rather than filled in with a guess.

## Stream mode

Stream mode is JSON Lines. A bare JSON string request produces a bare report response:

```json
"rm -rf build"
```

A tagged request produces an envelope:

```json
{"id":"random-value","command":"rm -rf build"}
```

```json
{"id":"random-value","report":{"version":1,"status":"Complete"}}
```

The report inside the envelope is the same report as single-command mode. Every input line receives exactly one answer, including refusals. A refusal is not a report:

```json
{"error":"invalid request","line":3}
```

When the rejected request carried an id, that id is echoed. Unknown request keys are refused rather than silently ignored.

The analyzer processes one request at a time and has no shared mutable analysis state. For parallel throughput, the caller should start several `--stream` processes.

## Client obligations

A caller using a subprocess or stream must:

1. Serialize writes to stdin. POSIX only guarantees atomic writes up to `PIPE_BUF` bytes.
2. Buffer stdout by newline. One read is not necessarily one response line.
3. Use unpredictable random ids, not sequential ids, when ids could be observed or the pipe could be shared.
4. Prevent unrelated child processes from inheriting the pipe file descriptors. Use `CLOEXEC` or Python's `close_fds=True`.

On EOF or timeout, fail all pending requests. Do not treat a missing response as an empty report.

## Reading a report

Read `status` first:

- `Complete`: the parser understood the command end to end.
- `Unsupported`: the input is valid for the selected shell, but the analyzer does not model part of it. The answer is partial.
- `Invalid`: there is evidence that the selected shell would reject the input too.

Read `impact.uncertain` before treating the effect list as complete. When it is `true`, an empty effect list does not mean that the command touches nothing.

The effect kinds include `Exec`, `Read`, `Write`, `Delete`, `Net`, `Spawn`, and `Unknown`. `modeled: false` means control was handed to a program whose internal behavior is not modeled. `dynamic: true` means the target is not a closed set, for example because it contains a variable or glob.

## What PreShell does not decide

The report is factual. It is not a security proof, sandbox, approval, or allow/deny verdict. Whether a command should run depends on the caller's user, sandbox, working directory, and policy.

Shell constructs such as `eval $X`, `$CMD`, and `base64 -d | sh` are not statically closed. The analyzer reports uncertainty instead of guessing.

## More information

- Integration and license boundary: <https://github.com/conglinyizhi/preshell/blob/main/docs/integration.md>
- Relative paths and pwd: run `preshell --help`, or pass `--cwd=PATH`
- Third-party materials and provenance: <https://github.com/conglinyizhi/preshell/blob/main/docs/third-party-licenses.md>
- Source and releases: <https://github.com/conglinyizhi/preshell>
- License: GPL-3.0-or-later
