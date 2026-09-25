# PreShell

- 中文版：[README.zh-CN.md](README.zh-CN.md)
- English: this page

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
GPL stays on this side of the process boundary. What that boundary means for
your project's licence, and how to call it without footguns, is
[`docs/integration.md`](docs/integration.md) and [`docs/third-party-licenses.md`](docs/third-party-licenses.md).

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
preshell --cwd=/srv/app 'rm -rf dist'   # resolve relative paths from a base
```

Many commands, one process: `--stream` reads one JSON string per line and writes
one report per line, in the same order.

```bash
jq -Rc . commands.txt | preshell --stream > reports.jsonl
```

A request can carry an id, in which case the answer comes back in an envelope
around the report (`{"id":17,"report":{...}}`) so a parent with several workers
can give each answer to the worker that asked, without trusting line order.
The report inside stays byte-for-byte the report the single-shot mode prints.

`preshell --help` carries the short contract (modes, framing, exit codes, what a
refusal means, and the four things a caller must do); `preshell --spec` is the
same contract as JSON, for a caller that has the binary and nothing else.
The full manual is available from the binary as `preshell --man` (plain text) or
`preshell --man-markdown` (for agents and document tools); `docs/preshell.md` is
the single source, also generated as `docs/preshell.1` for `man preshell`.

PreShell CI orchestration lives in MoonBit `.mbtx` scripts: `tools/ci/check.mbtx` is used by both
GitHub Actions and `tools/ci_local.py`, while non-MoonBit corpus and probe tools remain
external commands invoked by that engine.

Every [PreShell release](https://github.com/conglinyizhi/preshell/releases) is a compact changelog generated from the commits between tags: user-visible changes come first, while detailed commit lists are folded and engineering maintenance is kept below. It carries a
prebuilt x86_64 Linux binary plus a `SHA256SUMS` file, built from that tag by
`.github/workflows/release.yml`. Building it yourself is one `moon build`; see
[`docs/integration.md`](docs/integration.md) for both paths and for the licence
boundary that makes a subprocess call the safe way to use it.

Exit codes describe the tool, never the command: `0` when a report was produced.
There is no exit code that means "dangerous".

## Relative paths and pwd

The tool never reads the file system, so it does not know which directory you are
in. `rm -rf dist` comes back as `Delete: dist`, with no `impact.cwd`.

Pass `--cwd=/srv/app` and the same command reports `/srv/app/dist`, with
`impact.cwd` set to the base. The value must be absolute; a relative one is a
usage error. Absolute paths are reported as written, and relative paths that
cannot be resolved are reported as written too, so the answer says which base it
was read against instead of inventing one.

`--cwd` is a starting point, not a `cd`: it adds no effect, and a `cd` inside the
command overrides it. A `cd` only affects the rest of the same command line —
a subshell, a command substitution, a pipeline element and a script handed to
another shell each get their own copy, and consecutive `cd`s accumulate. When the
base cannot be worked out (`cd $DIR`, or a relative `cd` with no base),
`impact.uncertain` is set rather than a missing base passing as "no change".

A caller that does not supply a base has to resolve the paths itself, or hand
them to whatever runs in the real directory. See
[`docs/integration.md`](docs/integration.md) for the caller contract.

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



This tool parses **bash** semantics, and it says so when the input declares
something else. The claims are split by how a POSIX shell actually fails,
because both kinds exist and they are not the same statement (each was checked
with `dash -n`):

- **rejected at parse time**: arrays (`x=(1 2)`), `<<<`, `<( )`, the
  `function` keyword. "It would not run there" is accurate.
- **parsed, and means something else**: `[[ ]]` is an ordinary command named
  `[[` to dash, and `((i++))` is two nested subshells. Saying these make the
  file invalid would be wrong.
- **not modelled at all** (`zsh`, `fish`, `python`, ...): the report is
  `Unsupported`, because the grammar being parsed is not that one.

`tools/corpus/posix_oracle.sh` runs these claims past a real POSIX shell and
reports each direction. On 1128 sh/dash scripts from this host the result is 3
claims confirmed, 0 false alarms, 0 missed dialect uses that matter (2 polyglots,
21 files we flag for other reasons, 1102 in agreement). Zero false alarms is
what CI enforces; the coarseness of the attribution is a known weakness.

## Where it stands

Measured against the two dialect corpora, as of the latest run:

| corpus | files | parsed | our gaps | we are too permissive | crashes |
|---|---|---|---|---|---|
| bash 5.3 syntax tests | 451 | 434 | 0 | 3 | 0 |
| zsh 5.9.2 Completion and Functions | 1244 | 1237 to 1239 | 0 | 5 to 7 | 0 |

The zsh row is a range because `zsh -n` is not a pure syntax checker: in a sandbox
that blocks the temporary file process substitution needs, it also aborts on a
couple of files, which moves them into the last column. The gap column and the
crash column are stable; see `AGENTS.md` for the measurements behind both.

"Our gaps" means the shell accepts a file and this tool does not: that number
reached zero on both corpora. The "too permissive" column is the dangerous
direction, and every entry in it is now a known quirk of the oracle rather than
a hole in the parser (see `Differential fuzzing` below and `AGENTS.md`).

On the command side, 35 common invocations were measured against what they
truly do (an LD_PRELOAD shim plus before/after directory snapshots): all 35 now
produce path conclusions rather than a bare "ran something".

Batching matters because process startup, not analysis, is what a call costs:
1.12 ms per command one at a time against 0.116 ms through `--stream` (the
analysis itself is 5 µs, so what the streaming mode removes is the process).
Every line of input is answered by exactly one line of output, refusals
included, so a caller can line its input up against its output without counting.

A larger, less flattering corpus is the one the sessions on this machine already
contain: 38250 distinct real bash commands and 423 sandbox-allow requests were
pulled from the agent's own logs and run through the tool. 99% of the commands
parse, 83% yield a path conclusion, no reported target looked like a non-path,
and every command the tool failed to parse was one the shells refuse as well.
The rest are cases like `python3 <<'PY'`, where a script is handed to a program
the tool does not model: those say so (`modeled: false`, `uncertain`) instead of
quietly reporting nothing. See `docs/integration.md` for the table and the
script.

## Which shell

Two grammars are read: bash and zsh. `--shell=auto` (the default) follows the
shebang, `--shell=bash` and `--shell=zsh` force one, and `--shell=probe` tries
the declared one first, then the other, and writes into the report which grammar
it ended up using (`probe: read as zsh, because bash did not parse this input`,
with `uncertain` set, because the input never said). Anything else (`fish`,
`python`, ...) is reported as `Unsupported` rather than read with the wrong
rules.

For POSIX `sh` the answer is split by how the shell actually fails, because both
kinds exist and they are not the same statement (each of these was checked with
`dash -n`):

- **rejected at parse time**: arrays (`x=(1 2)`), `<<<`, `<( )`, the `function`
  keyword. "It would not run there" is accurate.
- **parsed, and it means something else**: to dash, `[[ ]]` is an ordinary
  command named `[[`, and `((i++))` is two nested subshells. Claiming those make
  a file invalid would be wrong, and it is what a first version of this did.
- **not modelled at all** (`zsh`, `fish`, `python`, ...): the report is
  `Unsupported`, because the grammar being parsed is not that one.

`tools/corpus/posix_oracle.sh` runs these claims past a real POSIX shell and
reports each direction separately. On 1128 sh/dash scripts from this host: 3
claims confirmed, **0 false alarms**, 0 missed dialect uses of the kind that
matter, 2 polyglots, 21 files flagged for other reasons, 1102 in agreement. Zero
false alarms is what CI enforces; the coarseness of the attribution is a known
weakness, recorded in `AGENTS.md`.

## Hardening

All runnable locally and in CI:

```bash
moon test --target native                     # library behaviour
moon fmt && moon check --target native        # formatting and types
tools/corpus/run.sh                           # differential against bash -n
ORACLE="zsh -n" PFLAGS="--shell=zsh" tools/corpus/run.sh --list <list>
tools/corpus/posix_oracle.sh                  # dialect claims vs a real sh
tools/probe/malformed.sh                      # the process must not die
node tools/fuzz/mutate.js --n 2000 --seed 1   # mutation fuzzing, reproducible
node tools/fuzz/differential.js --n 800 --seed 1
tools/corpus/snapshot.sh <bin> <list> <out>   # full status snapshot, for diffs
```

The differential corpus (bash 5.3's `tests/*.sub`) ships with the repository so
that CI and local runs use the same input; provenance and licensing are in
`tools/corpus/bash-tests/README.md`. `tools/corpus/find_scripts.sh` collects real
scripts from the host for a second, noisier corpus, and `zsh_corpus.sh` collects
the zsh tree's own `Completion/` and `Functions/` (1244 files) for the zsh side.

Two numbers to watch, because both were zero and should stay there: crashes, and
inputs where bash rejects a command this tool accepts.

One environment note: `tools/corpus/run.sh` sets `ulimit -c 0` for itself and its
children. `zsh -n` aborts on files that use process substitution when the sandbox
blocks the temporary file it needs (`getoutputfile` in the stack), and
systemd-coredump records one dump per crash, which a corpus run multiplies by
the thousand. The line only affects that script.

## Differential fuzzing

`mutate.js` asks whether the tool dies. `differential.js` asks whether it is
right, with a real shell as the judge: mutations of a construct zoo are fed to
both, and the two directions are reported separately -- the shell accepts and we
do not (a gap), and the shell refuses while we report `Complete` (the dangerous
direction). Its first run found sixteen cases of the second kind, none of which
the corpora could see, including `always` accepted under the bash dialect, a
`for` with no body, an unclosed array, and a lone `}` where a command should be.
Every failure is printed with the oracle's own message, because the oracle has
known quirks of its own.

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

## Deliberate limits

These are choices, not bugs waiting to be found:

- **`[[ ... ]]` is opaque.** The tokenizer finds the closing `]]` and keeps the
  text for the dialect checks, but the expression inside is not parsed;
  command substitutions in it are audited, because they run. A malformed
  condition therefore reads as `Complete`, and implementing the condition
  grammar would cost more than it returns.
- **An assignment in argument position is refused** (`f x=1`). bash performs it;
  saying "not parsed" is the safe direction, and the corpus does not contain it.
- **A brace glued to a word** (`f () {echo x}`) is a long tail: zsh pushes an
  unmatched `}` back and we model that, but the glued spelling still reports
  `Unsupported` in some shapes.
- **A program we do not model says so.** It is reported as `Exec` with
  `modeled: false`, which forces `uncertain`; the effect list below it is a
  lower bound. That is what keeps this from being an unbounded enumeration
  problem.
- **The oracle is not a pure syntax checker.** `zsh -n` evaluates part of what
  it reads (division by zero, file descriptor numbers, process substitution),
  and the corpus files are function bodies that it reads as top-level scripts.
  Every disagreement is printed with the oracle's message so a human can tell.

## Build and test

```bash
moon test --target native
moon build --release --target native
moon fmt && moon check --target native
```

## License

GPL-3.0-or-later. The implementation is an original rewrite, but it was written
with heavy reference to bash's own source (`parse.y` for the grammar and lexer)
and to `bash -n` for behaviour. Third-party test materials and provenance are
listed in [`docs/third-party-licenses.md`](docs/third-party-licenses.md). See LICENSE.

