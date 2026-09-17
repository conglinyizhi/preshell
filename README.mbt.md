# preshell

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
preshell < script.sh              # preferred: no argv limits, no re-quoting
preshell 'rm -rf build/'          # or pass the command as arguments
preshell --pretty 'make -j8'      # indented JSON for humans
preshell --shadow 'cat <<EOF'     # dump the syntax tree
preshell --scan '<cmd>'           # one line: parse status, issue count, effects
preshell --bench=2000             # timing loop
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

### Input normalisation

Two input-level facts belong in the contract, because both were once ways for
the answer to be quietly wrong:

- **A NUL byte is dropped and the two sides joined**, which is what bash does:
  `true\0; rm -rf /` runs the `rm`. Truncating at the NUL printed "Complete,
  nothing touched" for a command that deletes everything.
- **Invalid UTF-8 is decoded lossily** rather than rejected, and the replacement
  is reported as an issue. A command line with one stray byte is still worth
  analysing; failing the whole run is not.

Either case makes `status` `Unsupported` and `uncertain` true: the command
analysed is not byte-for-byte the one that arrived.

## Status

- `Complete` — parsed end to end.
- `Unsupported` — valid shell that the parser does not handle yet. The answer
  above is therefore incomplete, and `uncertain` is forced to true.
- `Invalid` — there is evidence that bash would refuse this command too, so
  nothing would execute. Only claimed with evidence; see below.


## Which shell

This tool parses **bash** semantics, and it says so when the input declares
something else:

- `#!/bin/sh` or `#!/bin/dash` using bash-only syntax (arrays, `[[ ]]`, `(( ))`,
  `<<<`, `<( )`, the `function` keyword) gets a note and `uncertain: true`.
  Such a script would not run under that shell as written. The parse itself
  succeeded, so `status` stays `Complete`: the note is about the dialect, not
  about this tool's coverage.
- A shell that is not modelled at all (`zsh`, `fish`, `python`, ...) makes the
  report `Unsupported`, because the grammar being parsed is not that one.

Neither case is guessed at: the shebang is read, and `sh`/`dash`/`bash` are
taken as the modelled set so that a POSIX script does not produce noise.

## Hardening

Three checks, all runnable locally and in CI:

```bash
moon test --target native                     # library behaviour
tools/corpus/run.sh                           # differential against bash -n
tools/probe/malformed.sh                      # the process must not die
node tools/fuzz/mutate.js --n 2000 --seed 1   # mutation fuzzing, reproducible
```

The differential corpus (bash 5.3's `tests/*.sub`) ships with the repository so
that CI and local runs use the same input; provenance and licensing are in
`tools/corpus/bash-tests/README.md`. `tools/corpus/find_scripts.sh` collects real
scripts from the host for a second, noisier corpus.

Two numbers to watch, because both were zero and should stay there: crashes, and
inputs where bash rejects a command this tool accepts.


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
