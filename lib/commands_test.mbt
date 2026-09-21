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
    // A compiler's product is the operand plus its suffix, and the operand
    // is removed afterwards unless -k.
    ("gzip a.txt", "R:a.txt W:a.txt.gz D:a.txt"),
    ("xz a.txt", "R:a.txt W:a.txt.xz D:a.txt"),
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
  // answer is the marker, and it must not be a clean report. git used to be on
  // this list; it now has its own measured table (lib/git.mbt), and
  // `git filter-branch` is the spelling that still has no entry.
  for
    src in [
      "git filter-branch --all", "node build.js", "make -j8", "python3 -m pytest", "docker run img",
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

///|
/// Option values: the value of an option is not an operand, and a path-shaped
/// value counts in the direction the option gives it.
///
/// Every case here was measured before it was written into the table. The
/// method: an `LD_PRELOAD` shim over the libc file entry points (open/openat/
/// fopen/freopen/stat/fstatat/statx/unlink/rename/link/symlink/chmod/mkdir/
/// truncate) logged the flag each call used while the real command ran in a
/// scratch directory; the expected string below is what that log says, mapped
/// to R/W/D/S. For the compressors `-c` a filesystem snapshot was used
/// instead, because those binaries do not all go through libc.
test "an option value is never an operand" {
  let cases : Array[(String, String)] = [
    // sort -o writes; all three spellings measured (separate value, attached,
    // and --output=).
    ("sort -o out.txt in.txt", "W:out.txt R:in.txt"),
    ("sort --output=out.txt in.txt", "W:out.txt R:in.txt"),
    ("sort -oout.txt in.txt", "W:out.txt R:in.txt"),
    // cp/install/ln -t: the operands land inside the directory. cp/install/ln
    // read the source, mv removes it (measured: rename).
    (
      "cp -t destdir a.txt b.txt", "R:destdir R:a.txt W:destdir/a.txt R:b.txt W:destdir/b.txt",
    ),
    ("cp --target-directory=d a.txt", "R:d R:a.txt W:d/a.txt"),
    ("mv -t destdir a.txt", "R:destdir D:a.txt W:destdir/a.txt"),
    ("install -t d a.txt", "R:d R:a.txt W:d/a.txt"),
    ("ln -t d a.txt", "R:d R:a.txt W:d/a.txt"),
    // -f carries the pattern/script from a file, so every operand is a file.
    ("sed -f script.sed data.txt", "R:script.sed R:data.txt"),
    ("awk -f prog.awk in.txt", "R:prog.awk R:in.txt"),
    ("grep -f pats.txt data.txt", "R:pats.txt R:data.txt"),
    ("grep --file=pats.txt data.txt", "R:pats.txt R:data.txt"),
    // sed -i.bak writes the file and its backup.
    ("sed -i.bak s/a/b/ data.txt", "W:data.txt W:data.txt.bak"),
  ]
  for c in cases {
    let (src, want) = c
    let got = touched(src)
    if got != want {
      fail("\{src}: want \{want}, got \{got}")
    }
    if analyze(src).impact.uncertain {
      fail("\{src}: a static option value must not make the report uncertain")
    }
  }
}

///|
/// The other direction: values that are not paths must not be reported at all.
/// Reporting `R:2` for `head -n 2` is an invented fact, and an invented fact
/// costs more trust than a missing one.
test "an option value that is not a path is not reported" {
  let cases : Array[(String, String)] = [
    ("sort -k 2 data.txt", "R:data.txt"),
    ("head -n 5 data.txt", "R:data.txt"),
    ("tail -n 5 data.txt", "R:data.txt"),
    ("diff -U 3 a.txt b.txt", "R:a.txt R:b.txt"),
    ("cut -d ' ' -f 2 data.txt", "R:data.txt"),
    ("uniq -f 1 data.txt", "R:data.txt"),
    ("join -1 1 -2 1 a.txt b.txt", "R:a.txt R:b.txt"),
    // --reference is stat'd, not opened; the file it names is read, and every
    // operand becomes a file because the mode comes from the option.
    ("chmod --reference=ref.txt d.txt", "R:ref.txt W:d.txt"),
    // -r on touch/truncate is a reference file (stat), not a write target.
    ("touch -r ref.txt data.txt", "R:ref.txt W:data.txt"),
    ("truncate -r ref.txt data.txt", "R:ref.txt W:data.txt"),
    // -c sends the compressed stream to stdout: nothing is rewritten.
    ("gzip -c f.txt", "R:f.txt"),
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
/// The rest of the measured rows: long options, clustered short options and
/// attached values all reach the same place. These exist so a table row cannot
/// silently stop working.
test "long and attached option spellings" {
  let cases : Array[(String, String)] = [
    ("sort -t: -k1,1 data.txt", "R:data.txt"),
    ("sort --key=2 --output=out.txt data.txt", "W:out.txt R:data.txt"),
    ("head -c 3 data.txt", "R:data.txt"),
    ("head --lines=5 data.txt", "R:data.txt"),
    ("tail -c 3 data.txt", "R:data.txt"),
    ("tail --bytes=3 --sleep-interval=1 data.txt", "R:data.txt"),
    ("diff -C 2 a.txt b.txt", "R:a.txt R:b.txt"),
    ("diff --unified=3 --context=2 a.txt b.txt", "R:a.txt R:b.txt"),
    ("cut -c 1-2 data.txt", "R:data.txt"),
    ("cut --characters=1-2 data.txt", "R:data.txt"),
    ("cut --fields=2 --delimiter=: --bytes=1 data.txt", "R:data.txt"),
    (
      "uniq --skip-fields=1 --skip-chars=1 --check-chars=1 data.txt", "R:data.txt",
    ),
    ("join -j 1 a.txt b.txt", "R:a.txt R:b.txt"),
    ("join -t: -o 1.1 a.txt b.txt", "R:a.txt R:b.txt"),
    // -e also supplies the pattern, so data.txt is not dropped as "the
    // pattern".
    ("grep -e foo data.txt", "R:data.txt"),
    ("grep --regexp=foo data.txt", "R:data.txt"),
    ("grep -m 1 -A 2 -B 2 -C 2 foo data.txt", "R:data.txt"),
    (
      "grep --max-count=1 --after-context=2 --before-context=2 --context=2 foo data.txt",
      "R:data.txt",
    ),
    ("rg -f pats.txt data.txt", "R:pats.txt R:data.txt"),
    ("rg --file=pats.txt data.txt", "R:pats.txt R:data.txt"),
    ("rg -A 2 foo data.txt", "R:data.txt"),
    ("rg -e foo -m 1 -t txt -g *.txt data.txt", "R:data.txt"),
    ("awk -v x=1 {print} data.txt", "R:data.txt"),
    ("awk -F: {print} data.txt", "R:data.txt"),
    ("awk --assign x=1 --field-separator=: {print} data.txt", "R:data.txt"),
    ("sed -e s/a/b/ data.txt", "R:data.txt"),
    ("sed --expression=s/a/b/ data.txt", "R:data.txt"),
    ("sed --in-place=.bak -e s/a/b/ data.txt", "W:data.txt W:data.txt.bak"),
    ("cp --suffix=.bak a.txt b.txt", "R:a.txt W:b.txt"),
    ("cp --backup=numbered a.txt b.txt", "R:a.txt W:b.txt"),
    ("cp --target-directory destdir a.txt", "R:destdir R:a.txt W:destdir/a.txt"),
    ("mv --suffix=.bak a.txt b.txt", "R:a.txt W:b.txt"),
    ("mv --backup=numbered a.txt b.txt", "R:a.txt W:b.txt"),
    ("install --mode=644 a.txt b.txt", "R:a.txt W:b.txt"),
    ("install --owner=root --group=root a.txt b.txt", "R:a.txt W:b.txt"),
    ("install --suffix=.bak --backup=numbered a.txt b.txt", "R:a.txt W:b.txt"),
    ("ln --suffix=.bak --backup=numbered a.txt b.txt", "R:a.txt W:b.txt"),
    ("chown --reference=ref.txt data.txt", "R:ref.txt W:data.txt"),
    ("chgrp --reference=ref.txt data.txt", "R:ref.txt W:data.txt"),
    ("touch --date=2020-01-01 data.txt", "W:data.txt"),
    ("touch -t 202001010000 data.txt", "W:data.txt"),
    ("touch --reference=ref.txt data.txt", "R:ref.txt W:data.txt"),
    ("truncate --size=0 data.txt", "W:data.txt"),
    ("truncate --reference=ref.txt data.txt", "R:ref.txt W:data.txt"),
    ("gzip --stdout data.txt", "R:data.txt"),
    ("gzip -9c data.txt", "R:data.txt"),
    ("gzip -S .zz data.txt", "R:data.txt W:data.txt.zz D:data.txt"),
    ("bzip2 -c data.txt", "R:data.txt"),
    ("bzip2 --stdout data.txt", "R:data.txt"),
    ("xz -c data.txt", "R:data.txt"),
    ("xz -S .zz data.txt", "R:data.txt W:data.txt.zz D:data.txt"),
    ("zstd --stdout data.txt", "R:data.txt"),
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
/// tar's archive name and its operation letter.
///
/// Measured with the LD_PRELOAD shim in a scratch directory:
///
/// - `tar -czf out dir`: creates `out`, opens `dir`
/// - `tar --create --file=arc.tar dir`: creates `arc.tar`, opens `dir`
/// - `tar rf arc.tar new.txt` / `tar uf arc.tar new.txt`: opens `arc.tar` for
///   writing (O_CREAT, no truncate), reads `new.txt`
/// - `tar czf - dir`: no file is created; the archive is stdout
/// - `tar tf arc.tar`: only opens `arc.tar`
/// - `tar --help`, `tar --version`, `tar -f a.tar` and `tar`: no file at all
///
/// The old rule read the first leftover *operand* as an option cluster when it
/// was all letters, so `-czf out dir` reported `dir` as the archive and
/// `--create --file=arc.tar dir` reported nothing.
test "tar names its archive and reads its members" {
  inspect(touched("tar -czf out dir"), content="W:out R:dir")
  inspect(touched("tar --create --file=arc.tar dir"), content="W:arc.tar R:dir")
  inspect(touched("tar rf arc.tar new.txt"), content="W:arc.tar R:new.txt")
  inspect(touched("tar uf arc.tar new.txt"), content="W:arc.tar R:new.txt")
  inspect(
    touched("tar --append --file=arc.tar new.txt"),
    content="W:arc.tar R:new.txt",
  )
  inspect(
    touched("tar --update --file=arc.tar new.txt"),
    content="W:arc.tar R:new.txt",
  )
  // `-` as the archive name means stdout: measured, `tar czf - dir` creates
  // nothing at all, in both spellings of the cluster.
  inspect(touched("tar czf - dir"), content="R:dir")
  inspect(touched("tar -czf - dir"), content="R:dir")
  // The old-style cluster still has to work, and only in the first argument.
  inspect(touched("tar cf arc.tar dir"), content="W:arc.tar R:dir")
  inspect(touched("tar cvpf out.tar dir"), content="W:out.tar R:dir")
  inspect(touched("tar czvf out.tgz dir"), content="W:out.tgz R:dir")
  inspect(touched("tar cPf out.tar dir"), content="W:out.tar R:dir")
  inspect(touched("tar tzf in.tgz"), content="R:in.tgz")
  inspect(touched("tar xzf in.tgz -C out"), content="W:out R:in.tgz")
  inspect(touched("tar tzf in.tgz dir"), content="R:in.tgz")
  // --exclude takes a pattern and -X a pattern file; neither is a member.
  inspect(
    touched("tar -cf out.tgz --exclude zz dir"),
    content="W:out.tgz R:dir",
  )
  inspect(
    touched("tar -cf out.tgz -X list dir"),
    content="R:list W:out.tgz R:dir",
  )
  // A mode letter is not a substring of whatever else is on the line.
  inspect(touched("tar -cf out.tgz --exclude=x dir"), content="W:out.tgz R:dir")
  // Long options that are not operations must not be read as one:
  // `--checkpoint` starts with `c` and `--exclude` contains `x`, so a
  // substring test would read them as create and extract.
  inspect(
    touched("tar --checkpoint dir"),
    content="U:tar: no operation letter was given",
  )
  // An archive name that is a hole keeps the write uncertain.
  inspect(touched("tar -czf $A dir"), content="W:$A R:dir")
  if !analyze("tar -czf $A dir").impact.uncertain {
    fail("a hole in the archive name must make the report uncertain")
  }
}

///|
test "tar reports a cluster it cannot place instead of guessing" {
  // Measured: `tar --help`, `tar --version` print and exit without opening
  // anything (rc 0).
  inspect(touched("tar --help"), content="")
  inspect(touched("tar --version"), content="")
  // Measured: `tar -f a.tar` and bare `tar` exit 2 with "you must specify one
  // of the -Acdtrux options"; nothing is opened.
  inspect(
    touched("tar -f a.tar"),
    content="U:tar: no operation letter was given",
  )
  // Measured: `tar dir` is options to tar ("cannot specify options other than
  // -Acdtrux"), and `d`, `i`, `r` are not letters this tool can place.
  inspect(
    touched("tar dir"),
    content="U:tar: old-style option cluster not modelled",
  )
  if !analyze("tar dir").impact.uncertain {
    fail("an unmodelled cluster must make the report uncertain")
  }
}

///|
/// A compressor's product is the operand plus its suffix, and the operand is
/// removed afterwards unless -k.
///
/// Measured with the shim in a scratch directory:
///
/// - `gzip f.txt`: opens f.txt, creates f.txt.gz, unlinks f.txt
/// - `gzip -k f.txt` / `--keep`: the same without the unlink
/// - `gunzip f.txt.gz` and `gzip -d f.txt.gz`: creates f.txt, unlinks f.txt.gz
/// - `gzip -dk f.txt.gz`: creates f.txt and keeps f.txt.gz
/// - `gzip -t f.txt.gz`, `gzip -l f.txt.gz`: opens it only
/// - `gzip -S .zz f.txt` creates f.txt.zz; `gzip -d -S .zz f.txt.zz` makes
///   f.txt and removes f.txt.zz
/// - `bzip2 f.txt` / `xz f.txt`: the same shape, products .bz2 / .xz
/// - `zstd f.txt`: creates f.txt.zst and KEEPS f.txt (zstd's default; only
///   --rm removes the source)
/// - `gzip -r sub`: the products are the entries inside sub
///
/// `gzip f.txt` used to report `R:f.txt W:f.txt`: a write to a file the
/// program never writes, with neither the product nor the removal visible.
test "a compressor derives its product and removes the source" {
  inspect(touched("gzip f.txt"), content="R:f.txt W:f.txt.gz D:f.txt")
  inspect(touched("gzip -k f.txt"), content="R:f.txt W:f.txt.gz")
  inspect(touched("gzip --keep f.txt"), content="R:f.txt W:f.txt.gz")
  inspect(touched("gunzip f.txt.gz"), content="R:f.txt.gz W:f.txt D:f.txt.gz")
  inspect(touched("gzip -d f.txt.gz"), content="R:f.txt.gz W:f.txt D:f.txt.gz")
  inspect(touched("gzip -dk f.txt.gz"), content="R:f.txt.gz W:f.txt")
  inspect(touched("gzip -t f.txt.gz"), content="R:f.txt.gz")
  inspect(touched("gzip -l f.txt.gz"), content="R:f.txt.gz")
  inspect(touched("gzip -S .zz f.txt"), content="R:f.txt W:f.txt.zz D:f.txt")
  inspect(
    touched("gzip -d -S .zz f.txt.zz"),
    content="R:f.txt.zz W:f.txt D:f.txt.zz",
  )
  // A name that already carries the suffix is left alone (measured rc 0 for
  // gzip, rc 2 for xz: "already has .xz suffix").
  inspect(touched("gzip f.txt.gz"), content="R:f.txt.gz")
  inspect(touched("xz f.txt.xz"), content="R:f.txt.xz")
  inspect(
    touched("gzip a.txt f.txt"),
    content="R:a.txt W:a.txt.gz D:a.txt R:f.txt W:f.txt.gz D:f.txt",
  )
  inspect(touched("bzip2 f.txt"), content="R:f.txt W:f.txt.bz2 D:f.txt")
  inspect(
    touched("bunzip2 f.txt.bz2"),
    content="R:f.txt.bz2 W:f.txt D:f.txt.bz2",
  )
  inspect(touched("xz f.txt"), content="R:f.txt W:f.txt.xz D:f.txt")
  inspect(touched("unxz f.txt.xz"), content="R:f.txt.xz W:f.txt D:f.txt.xz")
  // zstd keeps its input, and --rm is what removes it.
  inspect(touched("zstd f.txt"), content="R:f.txt W:f.txt.zst")
  inspect(touched("unzstd f.txt.zst"), content="R:f.txt.zst W:f.txt")
  inspect(touched("unzstd f.txt.zstd"), content="R:f.txt.zstd W:f.txt")
  inspect(touched("zstd --rm f.txt"), content="R:f.txt W:f.txt.zst D:f.txt")
  // A product derived from a hole stays a hole.
  inspect(touched("gzip -S $S f.txt"), content="R:f.txt W:f.txt$S D:f.txt")
  // -r names its products from the directory entries, which this tool cannot
  // write down.
  inspect(
    touched("gzip -r sub"),
    content="R:sub U:gzip -r: the products are the entries inside each directory",
  )
  if !analyze("gzip -r sub").impact.uncertain {
    fail("products derived per directory entry must be uncertain")
  }
}

///|
/// A wrapper runs the program it is handed.
///
/// Measured with the shim: every line below ends in the real program deleting
/// the file it was given (`env rm -rf victim.txt`, `timeout 5 rm -f victim.txt`,
/// `nice -n 5 rm`, `nohup rm`, `stdbuf -oL rm`, `setsid rm`, `command rm`,
/// `xargs rm < list`). Before this each one reported "an unmodelled program
/// ran", which is true and says nothing about what it ran.
test "a wrapper passes its command through" {
  let rm = "D:victim.txt"
  for
    src in [
      "env rm -rf victim.txt", "env FOO=1 rm -rf victim.txt", "env -i rm -rf victim.txt",
      "env -u FOO rm -rf victim.txt", "env -a argv0 rm -rf victim.txt", "env --argv0=argv0 rm -rf victim.txt",
      "env --block-signal=TERM rm -rf victim.txt", "env rm -rf -- victim.txt", "timeout 5 rm -f victim.txt",
      "timeout -s KILL 5 rm -f victim.txt", "timeout -k 2 5 rm -f victim.txt", "nice rm -f victim.txt",
      "nice -n 5 rm -f victim.txt", "nice -5 rm -f victim.txt", "nohup rm -f victim.txt",
      "stdbuf -oL rm -f victim.txt", "stdbuf -o L rm -f victim.txt", "setsid rm -f victim.txt",
      "setsid -w rm -f victim.txt", "command rm -f victim.txt", "command -p rm -f victim.txt",
      "env timeout 5 rm -f victim.txt", "env nice rm -f victim.txt",
    ] {
    let got = touched(src)
    if got != rm {
      fail("\{src}: want \{rm}, got \{got}")
    }
  }
  // A wrapper that runs nothing touches nothing, and says so cleanly.
  for src in ["env", "command -v rm", "nohup", "timeout"] {
    inspect(touched(src), content="")
    if analyze(src).impact.uncertain {
      fail("\{src}: nothing runs, so nothing is uncertain")
    }
  }
  // `env -S "..."` runs a string this tool does not take apart.
  inspect(
    touched("env -S \"rm -rf victim.txt\""),
    content="U:env: the command line is inside a string option",
  )
  // A shell word cannot be what a wrapper execs (`env cd /tmp` fails), so the
  // working directory of the report must not move.
  inspect(touched("env cd /tmp"), content="")
  inspect(touched("env cd /tmp && rm f.txt"), content="D:f.txt")
  if !analyze("env cd /tmp").impact.uncertain {
    fail("a command env cannot run must stay uncertain")
  }
}

///|
test "xargs passes what it was given and marks what it appends" {
  // Measured: `xargs rm < list` deletes the names on stdin; `xargs -a list rm`
  // reads its argument list from list.
  inspect(
    touched("xargs rm"),
    content="U:xargs: the argument list comes from its input",
  )
  inspect(
    touched("xargs rm -f fixed.txt"),
    content="D:fixed.txt U:xargs: the argument list comes from its input",
  )
  inspect(
    touched("xargs -a list rm"),
    content="R:list U:xargs: the argument list comes from its input",
  )
  if !analyze("xargs rm").impact.uncertain {
    fail("the words xargs appends are unknown, so the report is uncertain")
  }
  // -I substitutes the input into a placeholder, which is not a path: without
  // this, `xargs -I{} rm {}` reported `{}` as a file to delete.
  inspect(
    touched("xargs -I{} rm -f {}"),
    content="U:xargs: the replaced arguments come from its input",
  )
  inspect(
    touched("xargs -i mv {} /tmp/dest"),
    content="U:xargs: the replaced arguments come from its input",
  )
  // xargs with no command runs echo, so nothing is touched.
  inspect(touched("xargs"), content="")
}
