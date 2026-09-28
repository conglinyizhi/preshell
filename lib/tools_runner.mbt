///|
/// The runners: programs that hand control to another program named in their
/// own arguments (`uv run`, `npx`, `cargo run`, ...).
///
/// Where the handoff goes is the whole answer here, and finding it means
/// consuming the runner's own value-taking options first: `uv run --with plyvel
/// python` hands control to `python`, not to `plyvel`. An option whose value is
/// what runs (`cargo --bin`, `uv --module`) is deliberately absent from the
/// table — the search stops on that word because it is the answer, so skipping
/// it would skip the answer.

///|
/// The runner's own options that take the next word as their value, so that
/// `uv run --with plyvel python` hands control to `python` and not to `plyvel`.
///
/// Reading such a value as the program is not cosmetic: a caller uses `Spawn`'s
/// target to decide which words after it belong to an interpreter, and to match
/// a name against its own lists (issue #5).
///
/// An option whose value *is* what runs is deliberately absent (`cargo --bin`,
/// `cargo --example`, `uv --module`): the delegate search stops on that word
/// because it is the answer, so skipping over it would skip the answer. The
/// lists are read off each tool's own `--help` where the tool is here to ask
/// (`uv`, `docker`, `deno`, `cargo`); the rest are the documented common ones,
/// kept short on purpose, because a wrong entry skips a word the search needed.
fn runner_value_opts(name : String) -> Array[String] {
  match name {
    "uv" =>
      [
        "--extra", "--no-extra", "--group", "--no-group", "--only-group", "--no-editable-package",
        "--env-file", "-w", "--with", "--with-editable", "--with-requirements", "--package",
        "--python-platform", "--index", "--default-index", "-i", "--index-url", "--extra-index-url",
        "-f", "--find-links", "--index-strategy", "--keyring-provider", "-P", "--upgrade-package",
        "--upgrade-group", "--resolution", "--prerelease", "--prerelease-package",
        "--fork-strategy", "--exclude-newer", "--exclude-newer-package", "--no-sources-package",
        "--reinstall-package", "--link-mode", "-C", "--config-setting", "--config-settings-package",
        "--no-build-isolation-package", "--no-build-package", "--no-binary-package",
        "--cache-dir", "--refresh-package", "-p", "--python", "--color", "--allow-insecure-host",
      ]
    "npm" | "npx" | "pnpm" | "yarn" | "bun" | "bunx" =>
      [
        "--package", "-c", "--call", "-w", "--workspace", "--allow-scripts", "--cache",
        "--prefix", "--registry", "--userconfig", "--globalconfig", "--loglevel",
        "--cache-dir", "--store-dir", "-C", "--dir", "--filter",
      ]
    "cargo" =>
      [
        "--message-format", "--color", "-F", "--features", "-j", "--jobs", "--target-dir",
        "-m", "--manifest-path", "--target", "--profile", "--config", "-Z",
      ]
    "deno" =>
      [
        "--cert", "--config", "-c", "--conditions", "--env-file", "--ext", "--import-map",
        "--location", "--preload", "--seed", "--v8-flags", "--log-level", "-L",
      ]
    "docker" | "podman" =>
      [
        "-a", "--attach", "-c", "--cpu-shares", "-e", "--env", "-h", "--hostname",
        "-l", "--label", "-m", "--memory", "-p", "--publish", "-u", "--user", "-v",
        "--volume", "-w", "--workdir", "--name", "--network", "--mount", "--env-file",
        "--entrypoint", "--platform", "--restart", "--add-host", "--network-alias",
        "--label-file",
      ]
    // conda is not installed here, so this is the documented pair that shows up
    // in real command lines and nothing more.
    "conda" => ["-n", "--name", "-p", "--prefix"]
    _ => []
  }
}

///|
/// Runners: commands whose whole job is to hand control to another program.
/// What that program touches is decided inside it and by its own language's
/// conventions, which is not something this tool tries to model -- chasing it
/// would mean re-implementing every language ecosystem there is.
///
/// So they are reported as a delegation: `Spawn` naming the program being
/// handed control, plus `uncertain`. That is a fact about the command line
/// (this invocation does not decide what happens next), not a verdict, and it
/// is what lets a caller count and surface delegations separately from the
/// programs the tool does understand.
fn runner_delegate(name : String, s : SimpleCmd) -> (String, Int)? {
  let words = s.words
  // Which word holds the delegate depends on the runner.
  let takes_subcommand = match name {
    "npx" | "bunx" => false
    _ => true
  }
  let run_words = ["run", "exec", "dlx", "shell"]
  let mut i = 1
  let mut seen_subcommand = !takes_subcommand
  while i < words.length() {
    let t = words[i].literal_text()
    if t == "" {
      i += 1
      continue
    }
    if t.has_prefix("-") {
      // The runner's own options, with the values they swallow: `--with X`,
      // `--cache DIR`. Skipping the flag alone is how `uv run --with plyvel
      // python` came to name `plyvel` as the program (issue #5).
      i += 1 + wrapper_option_extra_words(runner_value_opts(name), t)
      continue
    }
    if takes_subcommand && !seen_subcommand {
      if run_words.contains(t) {
        seen_subcommand = true
        i += 1
        continue
      }
      // Some other subcommand (`uv pip install`, `go test`): not a delegation.
      return None
    }
    // The index comes along: what follows the program is what it reads as its
    // source, and a caller asking for payloads needs to know where that starts.
    return Some((t, i))
  }
  // A runner with nothing to run: `cargo run` uses the package's own binary.
  Some(("", 0))
}

///|
/// The runners whose delegation is worth naming. Kept to the ones that
/// actually show up in real command lines.
fn is_runner(name : String) -> Bool {
  match name {
    "uv"
    | "poetry"
    | "pdm"
    | "pipx"
    | "npx"
    | "bunx"
    | "go"
    | "cargo"
    | "dotnet"
    | "deno"
    | "npm"
    | "pnpm"
    | "yarn"
    | "bun"
    | "conda" => true
    _ => false
  }
}

///|
/// Report a delegation, if this invocation is one. Returns true when the
/// command was handled here.
fn Collector::runner_effects(
  self : Collector,
  n : String,
  s : SimpleCmd,
  line : Int,
) -> Bool {
  if !is_runner(n) {
    return false
  }
  match runner_delegate(n, s) {
    None => false
    Some((target, at)) => {
      self.push(Exec, n, false, line)
      self.push(
        Spawn,
        if target == "" {
          "what " + n + " runs"
        } else {
          target
        },
        true,
        line,
        payload=self.payload_for(target, s.words[at + 1:], s.redirects),
      )
      true
    }
  }
}
