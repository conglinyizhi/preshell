///|
/// Per-command operand semantics, table-driven.
///
/// This exists because the modelled-command tables are a set of *claims* about
/// how each program reads its arguments, and a wrong claim is silent: nothing
/// crashes, the report just says a command reads a mode string or writes its
/// own input. Six of them were wrong when this test was first written
/// (`chmod 644 f` reported `644` as a written path, `tar czf` was mistaken for
/// extraction, and so on).
///
/// Codes: R read, W write, D delete, N network, S spawn, U unknown.
fn touched(src : String) -> String {
  let r = analyze(src)
  let parts : Array[String] = []
  for e in r.impact.effects {
    let tag = match e.kind {
      Exec => ""
      Read => "R"
      Write => "W"
      Delete => "D"
      Net => "N"
      Spawn => "S"
      Unknown => "U"
    }
    if tag != "" {
      parts.push(tag + ":" + e.target)
    }
  }
  parts.join(" ")
}

///|
fn roots_of(src : String) -> String {
  analyze(src).impact.write_roots.join(" ")
}

///|
test "reading commands: operands are the files" {
  let cases : Array[(String, String)] = [
    ("cat a.txt", "R:a.txt"),
    ("head -n5 a.txt", "R:a.txt"),
    ("tail -f log", "R:log"),
    ("sort a.txt", "R:a.txt"),
    ("wc -l a.txt", "R:a.txt"),
    ("md5sum a.txt", "R:a.txt"),
    ("base64 a.txt", "R:a.txt"),
    ("diff a.txt b.txt", "R:a.txt R:b.txt"),
    ("ls -la dir", "R:dir"),
    ("du -sh dir", "R:dir"),
    ("realpath a.txt", "R:a.txt"),
    ("stat a.txt", "R:a.txt"),
    ("readlink a.txt", "R:a.txt"),
  ]
  for c in cases {
    let (src, want) = c
    let got = touched(src)
    if got != want {
      fail("\{src}: want \{want}, got \{got}")
    }
  }
}

///|
test "the first operand is not always a path" {
  let cases : Array[(String, String)] = [
    // grep/awk/sed take a pattern or script first
    ("grep foo a.txt b.txt", "R:a.txt R:b.txt"),
    ("rg pattern src/", "R:src/"),
    ("awk {print} a.txt", "R:a.txt"),
    ("sed -n 1p a.txt", "R:a.txt"),
    ("sed -i s/a/b/ a.txt", "W:a.txt"),
    // chmod/chown/chgrp take a mode, an owner or a group first
    ("chmod 644 a.txt", "W:a.txt"),
    ("chmod -R 755 dir", "W:dir"),
    ("chown root a.txt", "W:a.txt"),
    ("chgrp staff a.txt", "W:a.txt"),
    // find's later operands are predicates, not paths
    ("find . -name '*.mbt' -type f", "R:."),
    ("find src tests -name x", "R:src R:tests"),
  ]
  for c in cases {
    let (src, want) = c
    let got = touched(src)
    if got != want {
      fail("\{src}: want \{want}, got \{got}")
    }
  }
}

///|
test "writing and deleting" {
  let cases : Array[(String, String)] = [
    ("tee out.txt", "W:out.txt"),
    ("touch new.txt", "W:new.txt"),
    ("mkdir -p d/e", "W:d/e"),
    ("truncate -s0 a.txt", "W:a.txt"),
    ("rm -f a.txt", "D:a.txt"),
    ("rm -rf build/", "D:build/"),
    ("cp a.txt b.txt", "R:a.txt W:b.txt"),
    ("mv a.txt dir/", "R:a.txt W:dir/"),
    ("install -m644 a /usr/local/bin/b", "R:a W:/usr/local/bin/b"),
    ("ln -s a b", "R:a W:b"),
    ("ln a.txt b.txt", "R:a.txt W:b.txt"),
    ("dd if=in of=out bs=1M", "R:in W:out"),
    // compressors rewrite their operand in place
    ("gzip a.txt", "R:a.txt W:a.txt"),
    ("xz a.txt", "R:a.txt W:a.txt"),
    // zip writes the archive and reads the members
    ("zip out.zip a.txt b.txt", "W:out.zip R:a.txt R:b.txt"),
    // split reads its input; the outputs are named by the tool
    ("split -l10 a.txt", "R:a.txt U:split: output file names are derived"),
  ]
  for c in cases {
    let (src, want) = c
    let got = touched(src)
    if got != want {
      fail("\{src}: want \{want}, got \{got}")
    }
  }
}

///|
test "tar does three different things" {
  // Create writes the archive, extract writes into -C, list only reads. The
  // mode letter arrives as `-czf` or as the classic no-dash form `czf`.
  inspect(touched("tar czf out.tgz dir"), content="W:out.tgz R:dir")
  inspect(
    touched("tar -czf out.tgz dir file"),
    content="W:out.tgz R:dir R:file",
  )
  inspect(touched("tar xzf in.tgz -C /tmp"), content="W:/tmp R:in.tgz")
  inspect(touched("tar tzf in.tgz"), content="R:in.tgz")
  // The value consumed by -C is not also reported as a path tar reads.
  inspect(touched("unzip in.zip -d /tmp"), content="W:/tmp R:in.zip")
}

///|
test "network targets are reported, http or not" {
  inspect(touched("curl https://x.sh -o out"), content="N:https://x.sh W:out")
  inspect(touched("ssh host uptime"), content="N:host")
  inspect(touched("nc -z host 22"), content="N:host")
  inspect(touched("scp a.txt user@host:/tmp/"), content="N:user@host:/tmp/")
}

///|
test "pure commands have no file effects of their own" {
  let cases = [
    "echo hi", "printf %s x", "true", "sleep 1", "pwd", "export A=1", "declare -a x=(1 2)",
    "unset A",
  ]
  for src in cases {
    let got = touched(src)
    if got != "" {
      fail("\{src}: expected no path effects, got \{got}")
    }
  }
}

///|
test "write roots are the blast radius a caller locks" {
  inspect(roots_of("rm -rf build/ && echo hi > /tmp/out"), content="build /tmp")
  // 相对路径按命令内部改过的工作目录解析
  inspect(roots_of("cd /srv/app && touch out.txt"), content="/srv/app")
  inspect(
    roots_of("install -m644 a /usr/local/bin/b"),
    content="/usr/local/bin",
  )
  // Reading creates no roots.
  inspect(roots_of("cat a.txt"), content="")
}

///|
test "the shell itself is followed when the string is static" {
  inspect(touched("bash -c \"rm -rf /tmp/x\""), content="D:/tmp/x")
  inspect(touched("eval \"rm -rf /tmp/x\""), content="D:/tmp/x")
}

///|
test "programs outside the modelled set are marked, not guessed" {
  // Every one of these runs and touches things this tool does not model: the
  // answer is the marker, and it must not be a clean report.
  for
    src in [
      "git pull", "node build.js", "make -j8", "python3 -m pytest", "docker run img",
    ] {
    let r = analyze(src)
    if touched(src) != "" {
      fail("\{src}: expected no path effects, got \{touched(src)}")
    }
    if !r.impact.uncertain {
      fail("\{src}: an unmodelled program must not produce a clean report")
    }
    let unmodelled = r.impact.effects.any(fn(e) { e.kind is Exec && !e.modeled })
    if !unmodelled {
      fail("\{src}: the Exec should be marked as unmodelled")
    }
  }
}

///|
test "a for loop may put its in on the next line" {
  // Measured: bash and zsh both accept `for x` / `in x` / `do ... done` split
  // across lines, and the body still runs.
  debug_inspect(
    analyze("for x\nin a\ndo\nrm -f b\ndone").status,
    content="Complete",
  )
  inspect(touched("for x\nin a\ndo\nrm -f b\ndone"), content="D:b")
  debug_inspect(
    analyze_dialect("for x\nin a\ndo\nrm -f b\ndone", Zsh).status,
    content="Complete",
  )
  // The body-less form is still fine.
  debug_inspect(
    analyze("for x\nin a b\ndo\n:\ndone").status,
    content="Complete",
  )
}

///|
test "a named descriptor prefix before a redirect" {
  // `{fd}<file` assigns a fresh descriptor; for an audit only the target
  // matters. Measured: both shells take it inside a command, and only bash
  // takes it attached to a compound command.
  inspect(touched(": {fd}<file"), content="R:file")
  inspect(touched("exec {fd}>out"), content="W:out")
  inspect(touched("{fd}<file"), content="R:file")
  debug_inspect(
    analyze("while :; do :; done {fd}<file").status,
    content="Complete",
  )
  debug_inspect(
    analyze_dialect("while :; do :; done {fd}<file", Zsh).status,
    content="Unsupported",
  )
  // A brace word that is not a valid name stays an ordinary word.
  debug_inspect(analyze("echo {not a fd}").status, content="Complete")
}
