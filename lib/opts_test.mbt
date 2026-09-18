///|
/// Table-level tests for option-value parsing (lib/opts.mbt).
///
/// The end-to-end effect tests live in commands_test.mbt; these pin the split
/// itself: which token becomes an operand, which is consumed as a value, and
/// the three spellings (`-oVAL`, clustered shorts, `--long=VAL`).
///
/// Row evidence for the table is the measurement described in commands_test;
/// what is tested here is that the parser routes each spelling to that row.
fn scan_items(xs : Array[String]) -> Array[(String, Bool)] {
  let out : Array[(String, Bool)] = []
  for x in xs {
    out.push((x, false))
  }
  out
}

///|
fn kind_name(v : OptVal) -> String {
  match v {
    NoVal => "NoVal"
    NotPath => "NotPath"
    ReadPath => "ReadPath"
    WritePath => "WritePath"
    TargetDir => "TargetDir"
    Attached => "Attached"
  }
}

///|
fn scan_render(n : String, args : Array[String]) -> String {
  let po = opts_of(n)
  let scan = if has_table(po) {
    scan_args(po, scan_items(args))
  } else {
    scan_legacy(scan_items(args))
  }
  let vals : Array[String] = []
  for v in scan.values {
    vals.push(v.opt + "=" + v.text + ":" + kind_name(v.val))
  }
  let operands : Array[String] = []
  for it in scan.operands {
    let (t, _) = it
    operands.push(t)
  }
  let tdir = match scan.target_dir {
    Some((d, _)) => d
    None => "-"
  }
  "opts=[" +
  scan.opts.join(",") +
  "] values=[" +
  vals.join(",") +
  "] operands=[" +
  operands.join(",") +
  "] tdir=" +
  tdir +
  " stdout=" +
  scan.to_stdout.to_string() +
  " fromopt=" +
  scan.from_option.to_string()
}

///|
test "a short option takes its value from the next token or from the token" {
  inspect(
    scan_render("sort", ["-k", "2", "data.txt"]),
    content="opts=[-k] values=[-k=2:NotPath] operands=[data.txt] tdir=- stdout=false fromopt=false",
  )
  inspect(
    scan_render("sort", ["-o", "out.txt", "in.txt"]),
    content="opts=[-o] values=[-o=out.txt:WritePath] operands=[in.txt] tdir=- stdout=false fromopt=false",
  )
  // Attached value: `-oout.txt`.
  inspect(
    scan_render("sort", ["-oout.txt", "in.txt"]),
    content="opts=[-o] values=[-o=out.txt:WritePath] operands=[in.txt] tdir=- stdout=false fromopt=false",
  )
  // Clustered: an unknown letter takes no value and the scan carries on, so
  // the `-o` after it still finds its value.
  inspect(
    scan_render("sort", ["-uo", "out.txt", "in.txt"]),
    content="opts=[-o] values=[-o=out.txt:WritePath] operands=[in.txt] tdir=- stdout=false fromopt=false",
  )
}

///|
test "a long option takes its value after = or after a space" {
  inspect(
    scan_render("sort", ["--output=out.txt", "in.txt"]),
    content="opts=[--output] values=[--output=out.txt:WritePath] operands=[in.txt] tdir=- stdout=false fromopt=false",
  )
  inspect(
    scan_render("sort", ["--output", "out.txt", "in.txt"]),
    content="opts=[--output] values=[--output=out.txt:WritePath] operands=[in.txt] tdir=- stdout=false fromopt=false",
  )
  // An unknown long option keeps the old behaviour: token stays a flag, the
  // next token stays an operand.
  inspect(
    scan_render("head", ["--bogus", "a.txt"]),
    content="opts=[] values=[] operands=[a.txt] tdir=- stdout=false fromopt=false",
  )
}

///|
test "an optional attached value does not consume the next token" {
  // sed -i[SUFFIX]: on its own it makes no backup, so the script stays an
  // operand.
  inspect(
    scan_render("sed", ["-i", "s/a/b/", "data.txt"]),
    content="opts=[-i] values=[] operands=[s/a/b/,data.txt] tdir=- stdout=false fromopt=false",
  )
  inspect(
    scan_render("sed", ["-i.bak", "s/a/b/", "data.txt"]),
    content="opts=[-i] values=[-i=.bak:Attached] operands=[s/a/b/,data.txt] tdir=- stdout=false fromopt=false",
  )
  inspect(
    scan_render("sed", ["--in-place=.bak", "-e", "s/a/b/", "data.txt"]),
    content="opts=[--in-place,-e] values=[--in-place=.bak:Attached,-e=s/a/b/:NotPath] operands=[data.txt] tdir=- stdout=false fromopt=true",
  )
}

///|
test "the scan records target directory, stdout mode and file-supplied patterns" {
  inspect(
    scan_render("cp", ["-t", "destdir", "a.txt"]).contains("tdir=destdir"),
    content="true",
  )
  inspect(
    scan_render("gzip", ["-9c", "data.txt"]).contains("stdout=true"),
    content="true",
  )
  inspect(
    scan_render("grep", ["-f", "pats.txt", "data.txt"]).contains("fromopt=true"),
    content="true",
  )
  // A number-looking value and a value that is a single space are both kept
  // out of the operand list.
  inspect(
    scan_render("cut", ["-d", " ", "-f", "2", "data.txt"]),
    content="opts=[-d,-f] values=[-d= :NotPath,-f=2:NotPath] operands=[data.txt] tdir=- stdout=false fromopt=false",
  )
}

///|
test "programs without a table keep the pre-table split" {
  inspect(
    scan_render("tar", ["-C", "/tmp", "xzf", "a.tgz"]),
    content="opts=[] values=[] operands=[/tmp,xzf,a.tgz] tdir=- stdout=false fromopt=false",
  )
  inspect(
    scan_render("ls", ["-la", "dir"]),
    content="opts=[] values=[] operands=[dir] tdir=- stdout=false fromopt=false",
  )
}

///|
test "the -t destination joins the operand basename" {
  // Measured: `cp -t destdir sub/a.txt` writes destdir/a.txt, and
  // `cp -t destdir/ a.txt` writes destdir/a.txt without a doubled slash.
  inspect(join_dir("destdir", "sub/a.txt"), content="destdir/a.txt")
  inspect(join_dir("destdir/", "a.txt"), content="destdir/a.txt")
  inspect(join_dir("d", "./a.txt"), content="d/a.txt")
  inspect(join_dir("d", "/x/y.txt"), content="d/y.txt")
  inspect(join_dir("d", "a.txt/"), content="d/a.txt")
  // A directory that is a hole is kept dynamic, so `cp -t $D a.txt` writes a
  // target nobody can name yet.
  let scan = scan_args(opts_of("cp"), [
    ("-t", false),
    ("$D", true),
    ("a.txt", false),
  ])
  debug_inspect(scan.target_dir, content="Some((\"$D\", true))")
  // An empty -t value must not turn into the absolute path `/a.txt`.
  inspect(
    scan_render("cp", ["-t", "", "a.txt"]),
    content="opts=[-t] values=[] operands=[a.txt] tdir=- stdout=false fromopt=false",
  )
}

///|
test "value_of finds the appended value for the derived write" {
  let scan = scan_args(
    opts_of("sed"),
    scan_items(["-i.bak", "s/a/b/", "data.txt"]),
  )
  debug_inspect(value_of(scan, ["-i", "--in-place"]), content="Some(\".bak\")")
  let bare = scan_args(opts_of("sed"), scan_items(["-i", "s/a/b/", "data.txt"]))
  debug_inspect(value_of(bare, ["-i", "--in-place"]), content="None")
}
