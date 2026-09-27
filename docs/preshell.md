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
- `--spec`: print the machine-readable protocol contract as JSON.
- `--help`: print the short contract quick reference to stderr.
- `--man`: print this manual as plain text.
- `--man-markdown`: print this manual as Markdown.
- `--version`: print the tool version as JSON.

Developer-only modes are `--scan`, `--shadow`, `--bench=N`, and `--evidence`. They are not part of the integration contract.

## Single-command mode

```bash
printf '%s' 'rm -rf build' | preshell
preshell 'rm -rf build'
```

Standard output contains exactly one JSON report. Diagnostics and help go to standard error. Exit status `0` means the answer was produced; status `2` means a usage error; another non-zero status means the tool itself failed. No exit status means dangerous: read the JSON.

## Paths and pwd

Paths are reported **absolute**. PreShell never reads the file system, so the base they are resolved against has to come from somewhere, and that somewhere is the caller.

- Pass `--cwd=/a/b` and `rm -rf dist` reports `Delete: /a/b/dist`, with `impact.cwd` set to `/a/b`. The value must be absolute; a relative one is a usage error.
- `--cwd` is required by the caller contract. Without it the tool uses its own current directory as the base — which is the caller's directory whenever the caller spawned it without changing directory — and attaches a `Note` to every report saying so. That note also marks `impact.uncertain`, so the answer is not presented as a closed one.
- `--cwd` is a starting point, not a movement: it produces no effect, and a `cd` inside the command takes precedence.
- `cd` affects the rest of the same command line only. A subshell, a command substitution, a pipeline element and a script handed to another shell each get their own copy, and consecutive `cd`s accumulate in order.
- Two kinds of path cannot be made absolute, and both stay as written with `impact.uncertain` set, so the gap is visible rather than filled in with a guess:
  - a path after a `cd` whose destination cannot be modelled, such as `cd $DIR`;
  - a path whose first segment is expanded at run time, such as `$HOME/x` or `~/x`. The value of a parameter is used as it stands, so whether the result is absolute is a run-time fact, and the base cannot be applied on top of it. The caller knows the value and finishes the job.
- A path that reads a variable says which one: every effect carries `vars` for the names its own target reads, and `impact.vars` is the deduplicated union. PreShell never reads the environment, so the name is what it hands over — substitute `HOME` and `$HOME/x` becomes the real path. Substitute only the names that were reported: in a path that is not `dynamic` the `$` is literal text (`'$X/y'`), and it is already anchored as one. A name the command line itself set is resolved here instead, so it is not reported at all.
- The tilde cases follow the same rule. `~` is `HOME`, `~+` is `PWD`, `~-` is `OLDPWD`. `~user` goes to the password database and `~N` to the shell's own directory stack, so neither has a name a caller could look up, and both are reported as holes; when the login name is invalid bash leaves the prefix exactly as written. Quoted (`"~"`) it is literal text and is anchored like any other relative path.

## Values the command line sets

A parameter is resolved only when the input itself says what it holds, and only when the shell would do nothing else to the value. Nothing is read from the environment, and nothing is guessed.

- `x=dist; rm -rf $x` reports `Delete: /a/b/dist`, and `x` is not listed in `vars`: the name is resolved, so the caller has nothing left to substitute.
- A value the shell would expand further stays a hole: `x='*.log'` would fan out against the file system at the use site, and `x=$(date)` is a run-time value. A blank is not in this list any more — it splits, which is the next section.
- A `for` list the input spells out is a closed set: `for f in a b; do rm "$f"; done` reports both deletions, and the body is walked once per word. The same fact found twice on the same line is reported once, so `for f in a b; do rm x; done` is one deletion: the second run told the caller nothing the first one did not, and it is the line the statement came from that makes them the same statement. A list the shell has to work out (`for f in *.ts`) stays a hole.
- A value that holds on one path only is dropped rather than kept: after `if c; then x=a; fi`, `rm $x` is a hole, because that branch may not have run. The same goes for a value set inside a subshell or a command substitution, which cannot reach the rest of the command line.
- The loop name does not outlive the loop: after `for f in a b; do :; done`, `rm $f` is a hole, because a caller reading the report cannot see that the loop ran at all.

## Word splitting

A value with a blank in it is two paths in one place and one path in another, and where it lands decides which. This is the manual's word splitting, and the report follows it:

- `x="a b"; rm $x` reports two deletions, and `rm "$x"` reports one path whose name has a space in it. Whitespace at either end of a value is padding and runs in the middle delimit, so `x="  a  b  "` is `a` and `b`.
- The text around the value stays on the outer fields: `x="a b"; rm pre$x` is `prea` and `b`, and `rm $x/post` is `a` and `b/post`.
- `IFS` is read from the values the command line set. An empty `IFS` turns splitting off, and with the default one only space, tab and newline separate.
- An assignment is not split, the use site is: `x="a b"; y=$x` puts the whole value in `y`.
- A value that comes out empty makes no argument at all: `x=""; rm $x` reports no deletion, and neither does `rm "$x"`, which names one empty path.
- An unquoted redirect target that splits is an ambiguous redirect: bash refuses the command rather than opening anything, so the target is a hole and not a path.
- Two names that both need splitting are left as a hole: the shell splits the whole expanded word, and gluing one name's fields onto another's is not modelled.

## Braces

Brace expansion is textual and runs before parameter expansion, so the two cases
differ: `rm -rf {a,b}` names two files, and `x='{a,b}'; rm $x` names one file whose
name has braces in it.

- `rm -rf {a,b}` reports both deletions, in order. `{1..3}` counts, `{01..03}` pads with zeros, `{3..1}` counts down, and `{a..c}` walks letters. The words are spliced into the argument list exactly where bash puts them, so `{echo,true} hi` runs `echo` with two arguments rather than two commands.
- A brace with no comma and no range is literal (`{a}`, `{a,b`), and so is one that is escaped (`\{a,b\}`) or quoted (`"{a,b}"`).
- A list the report cannot carry — `{1..1000}` — becomes a hole rather than a word list or a literal name, and the same goes for the shapes that are not modelled, such as a brace glued to a parameter (`$x{a,b}`).
- The two shells disagree about ranges and the report follows the dialect it was asked for: `{1..a}` is literal in bash and walks the ASCII table in zsh, and a step on a character range (`{a..f..3}`) works in bash while zsh leaves it literal.

## Candidate paths

A name the command line left with more than one possible value makes a hole that
is not a mystery: `if c; then x=a; else x=b; fi; rm $x` deletes one of two paths,
and the effect says which ones.

- The effect keeps its hole (`target: "$x"`, `dynamic: true`, `vars: ["x"]`) and gains `candidates: ["/a/b/a", "/a/b/b"]`.
- Candidates are possibilities, not facts. Nothing in the list is claimed to happen: `x` holds one of them, and two entries do not mean two deletions. A caller deciding on facts keeps using `target` plus `vars`.
- The list is exhaustive or absent. A `while` body may run any number of times, so a value it sets is an unknown rather than a set; a set that grew past eight paths is left out rather than truncated; and a possibility that names no path (an unset name, an empty value) is not listed at all.
- What is certain stays certain: `x=a; rm $x` is one path with no candidates, and `if c; then x=a; else x=a; fi; rm $x` is the same, because both ways out set the same value.
- A loop over a spelled-out list contributes the values its body left, and a condition that may not run contributes the value from before it: `x=old; if c; then x=new; fi; rm $x` reports `old` and `new`.

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
{"id":"random-value","report":{"status":"Complete"}}
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

`impact.vars` lists every variable this report's effects read, deduplicated, and
each effect carries its own `vars` for the names in its own target. PreShell
never reads the environment, so the name is what it hands over: look it up, and
`$HOME/x` becomes the real path. `write_roots` can contain such a name too, so
resolve it before comparing entries against a policy.

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
