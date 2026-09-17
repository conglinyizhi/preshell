# shaudit

A shell command *analyzer*, not an approver.

Give it a command line and it tells you **what that command touches**: which
programs run, which paths are read, written or removed, what leaves the machine,
and where it could not tell. That is the entire output.

It does not decide whether any of that is acceptable. There is no allowlist, no
policy, and no verdict in here, because "should this run" depends on context the
tool does not have (which sandbox, which user, which session) and belongs to
whoever asked. For what a caller does with the answer, see
[`docs/example-policy.md`](docs/example-policy.md).

It is a **standalone tool, not a library**: invoke it as a subprocess and read
JSON. Callers in any language can use it without linking anything in, and the
GPL stays on this side of the process boundary.

## What it is not

- **Not a sandbox.** It blocks nothing. The real guard is wherever the command
  actually runs.
- **Not a policy engine.** No allow/deny, no roots to compare against.
- **Not a linter.** It does not care about style, only about reach.
- **Not 100% faithful.** Part of shell semantics is not statically decidable
  (`eval $X`, `$CMD`, `base64 -d | sh`). For those the answer is "unknown",
  never a guess.

## Usage

```bash
shaudit < script.sh              # preferred: no argv limits, no re-quoting
shaudit 'rm -rf build/'          # or pass the command as arguments
shaudit --pretty 'make -j8'      # indented JSON for humans
shaudit --shadow 'cat <<EOF'     # dump the syntax tree
shaudit --scan '<cmd>'           # one line: parse status, issue count, effects
shaudit --bench=2000             # timing loop
```

Exit codes describe the tool, never the command: `0` when a report was produced.
There is no exit code that means "dangerous".

## Output

```json
{
  "version": 1,
  "status": "Complete",
  "impact": {
    "effects": [
      { "kind": "Exec", "target": "cd", "dynamic": false, "line": 1 },
      { "kind": "Delete", "target": "/tmp/x", "dynamic": false, "line": 1 }
    ],
    "write_roots": ["/tmp"],
    "uncertain": false,
    "cwd": "/tmp"
  },
  "issues": []
}
```

Three things carry the honesty of the whole thing, and a caller that ignores
them will misread the output:

- `modeled: false` on an `Exec` means the program ran, and **what it touches is
  decided inside it**. `git pull` writing `.git/` is not missing from the report
  by oversight: enumerating what `git`, `node`, `python` or `docker` do means
  reading the scripts and images they are handed, which is not a bounded
  project. So the tool models the programs whose arguments *are* the files they
  touch (the coreutils-shaped set) and marks everything else. Every unmodelled
  program also forces `uncertain`.

- `dynamic` on an effect means the target is not a closed set (it has a hole or
  a glob). `rm -rf $DIR/*` cannot be reported as one file.
- `uncertain` on the impact means the same for the report as a whole, and it is
  forced when the parse was incomplete. **An incomplete trace is not a smaller
  answer, it is a different one**: reading "no writes reported" as "writes
  nothing" is the mistake this field exists to prevent.

`cwd` is the directory that relative paths in the report are relative to, when
the command line itself changed into one (`cd /tmp && rm x` reports `/tmp/x`).
The field is absent when no `cd` was modelled, so relative paths are relative to
wherever the command runs — which the caller knows and the tool does not.

### What "unmodelled" costs, and what it does not

The set of fully modelled programs stays small on purpose. Adding a name to it is
a claim about that program's file behaviour, and **when in doubt, leave it out**:
an omitted program is reported as unmodelled, which is the safe direction.

`uncertain` therefore tracks "we do not model something here", not "this looks
dangerous". A read-only `git status` is unmodelled and will set the flag. When a
deployment needs more, the honest next step is a caller-supplied table of program
semantics rather than a bigger built-in list.

## Status

- `Complete` — parsed end to end.
- `Unsupported` — valid shell that the parser does not handle yet. The answer
  above is therefore incomplete, and `uncertain` is forced to true.
- `Invalid` — there is evidence that bash would refuse this command too, so
  nothing would execute. Only claimed with evidence; see below.

## Evidence rather than taste

Claiming "bash would reject this" is a statement about a program we are not
running, and a false claim turns an unparsed command into an empty report. So
`Invalid` needs evidence, and the evidence comes from a differential:

```bash
tools/corpus/run.sh [bash source tests dir]
```

It compares this parser with `bash -n` over bash's own syntax corpus, prints a
four-quadrant table, and enforces one invariant:

> any message listed as corroborated in `lib/status.mbt` must appear **zero**
> times in the quadrant where bash parses the input and we do not.

The corpus bounds the strength of that guarantee, which is why an empty list is
a perfectly good state: it means "never claim it".

## Build and test

```bash
moon test --target native
moon build --release --target native
moon fmt && moon check --target native
```

## License

GPL-3.0-or-later. The implementation is an original rewrite, but it was written
with heavy reference to bash's own source (`parse.y` for the grammar and lexer)
and to `bash -n` for behaviour. See LICENSE.
