///|
/// tar and the compressors: where the archive comes from, what its members are,
/// and what a compressor leaves behind.
///
/// The operation letter is what tells tar's archive from its members (`-c` reads
/// its members and writes the archive, `-x` the other way round), and the old
/// rule read the first leftover operand as one when it was all letters. Every
/// expectation comes from the `LD_PRELOAD` shim or, for the compressors that do
/// not go through libc, from a before/after snapshot of the directory.

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
  if !@lib.analyze("tar -czf $A dir").impact.uncertain {
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
  if !@lib.analyze("tar dir").impact.uncertain {
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
  if !@lib.analyze("gzip -r sub").impact.uncertain {
    fail("products derived per directory entry must be uncertain")
  }
}
