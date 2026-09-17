///|
/// Working-directory tracking: `cd /tmp && rm -rf x` deletes `/tmp/x`, and a
/// caller cannot resolve that itself because the move happens inside the
/// command line. Mis-scoping this is the difference between "touches /tmp/x"
/// and "touches some x somewhere".
fn impact_of_cwd(src : String) -> Impact {
  analyze(src).impact
}

///|
fn path_effects(im : Impact) -> Array[String] {
  let out : Array[String] = []
  for e in im.effects {
    match e.kind {
      Read | Write | Delete => out.push(e.target)
      _ => ()
    }
  }
  out
}

///|
test "a modelled cd moves the paths after it" {
  let im = impact_of_cwd("cd /tmp && rm -rf x")
  debug_inspect(im.cwd, content="Some(\"/tmp\")")
  debug_inspect(path_effects(im), content="[\"/tmp/x\"]")
  debug_inspect(im.write_roots, content="[\"/tmp\"]")
  debug_inspect(im.uncertain, content="false")
}

///|
test "relative paths with no cd are left as written" {
  // No cwd change: the caller's own working directory is what these are
  // relative to, and that is the caller's knowledge, not this tool's.
  let im = impact_of_cwd("rm -rf build/")
  debug_inspect(im.cwd, content="None")
  debug_inspect(path_effects(im), content="[\"build/\"]")
}

///|
test "a subshell does not move the directory it was called from" {
  let im = impact_of_cwd("(cd /tmp && rm x)")
  debug_inspect(im.cwd, content="None")
  debug_inspect(path_effects(im), content="[\"/tmp/x\"]")
}

///|
test "a command substitution does not move the surrounding directory" {
  let im = impact_of_cwd("x=$(cd /tmp; rm y); rm z")
  debug_inspect(im.cwd, content="None")
  debug_inspect(path_effects(im), content="[\"/tmp/y\", \"z\"]")
}

///|
test "a pipeline element does not move the next one" {
  let im = impact_of_cwd("cd /tmp | rm x")
  debug_inspect(im.cwd, content="None")
  debug_inspect(path_effects(im), content="[\"x\"]")
}

///|
test "an unmodellable cd is reported, not guessed" {
  let im = impact_of_cwd("cd $DIR && rm x")
  debug_inspect(im.cwd, content="None")
  debug_inspect(im.uncertain, content="true")
  debug_inspect(path_effects(im), content="[\"x\"]")
}

///|
test "consecutive cds accumulate" {
  let im = impact_of_cwd("cd /tmp; cd sub; rm a")
  debug_inspect(im.cwd, content="Some(\"/tmp/sub\")")
  debug_inspect(path_effects(im), content="[\"/tmp/sub/a\"]")
}

///|
test "a shell handed a static string gets its own directory scope" {
  let im = impact_of_cwd("bash -c \"cd /tmp; rm x\"; rm z")
  debug_inspect(im.cwd, content="None")
  debug_inspect(path_effects(im), content="[\"/tmp/x\", \"z\"]")
}
