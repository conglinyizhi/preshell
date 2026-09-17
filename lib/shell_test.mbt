///|
/// The shell boundary.
///
/// This tool parses bash semantics and nothing else. A script that says
/// `#!/bin/zsh` may use syntax bash reads differently, and a `#!/bin/sh` script
/// using arrays will not run under dash at all. Both cases have to be visible in
/// the report, because "Complete, nothing unusual" about a program we did not
/// actually model is a claim the tool cannot back up.
test "the declared shell is read when there is one" {
  debug_inspect(declared_shell("#!/bin/zsh\necho hi"), content="Some(\"zsh\")")
  debug_inspect(
    declared_shell("#!/usr/bin/env bash\necho hi"),
    content="Some(\"bash\")",
  )
  debug_inspect(
    declared_shell("#!/bin/dash -e\necho hi"),
    content="Some(\"dash\")",
  )
  debug_inspect(
    declared_shell("#!/usr/bin/perl\nprint 1"),
    content="Some(\"perl\")",
  )
  debug_inspect(declared_shell("echo hi"), content="None")
  debug_inspect(declared_shell("# not a shebang\n"), content="None")
}

///|
test "a shell we do not model is called out, not silently parsed as bash" {
  let zsh = analyze("#!/bin/zsh\nfor f in *.txt; do echo $f; done")
  debug_inspect(zsh.status, content="Unsupported")
  inspect(zsh.impact.uncertain, content="true")
  inspect(zsh.issues.length(), content="1")

  let python = analyze("#!/usr/bin/env python3\nimport os")
  debug_inspect(python.status, content="Unsupported")

  // sh, dash and bash are the modelled set: no noise on the common case.
  debug_inspect(analyze("#!/bin/sh\necho hi").status, content="Complete")
  debug_inspect(analyze("#!/bin/bash\necho hi").status, content="Complete")
  debug_inspect(analyze("echo hi").status, content="Complete")
}

///|
test "bash-only syntax in a POSIX script is reported" {
  let cases = [
    ("#!/bin/sh\nx=(1 2)", "array assignment"),
    ("#!/bin/dash\n[[ -f x ]] && echo y", "[[ ]]"),
    ("#!/bin/sh\n((i++))", "(( ))"),
    ("#!/bin/sh\ncat <<< hello", "<<<"),
    ("#!/bin/sh\ndiff <(a) <(b)", "<( ) process substitution"),
  ]
  for c in cases {
    let (src, what) = c
    let r = analyze(src)
    // 解析是成功的，status 照实描述；方言不符由 Note 与 uncertain 承担。
    // 把它算成 Unsupported 会让「解析缺口」这个指标失去意义。
    debug_inspect(r.status, content="Complete")
    debug_inspect(r.impact.uncertain, content="true")
    let mentions = r.issues.any(fn(i) {
      i.kind is Note && i.message.contains(what)
    })
    if !mentions {
      fail("\{src}: expected a note about \{what}")
    }
  }
  // The same syntax under bash is fine.
  debug_inspect(analyze("#!/bin/bash\nx=(1 2)").status, content="Complete")
  debug_inspect(
    analyze("#!/bin/sh\necho \u{24}{x:-y}").status,
    content="Complete",
  )
}

///|
test "bashisms are found through nested constructs" {
  // dash refuses to parse these outright, so the claim "it would not run" holds
  inspect(
    bashisms(parse("cat <(echo a)").0).rejects.join(","),
    content="<( ) process substitution",
  )
  inspect(
    bashisms(parse("x=(1 2)").0).rejects.join(","),
    content="array assignment",
  )
  inspect(bashisms(parse("cat <<< hi").0).rejects.join(","), content="<<<")
  inspect(
    bashisms(parse("function f { :; }").0).rejects.join(","),
    content="function keyword",
  )
  // dash parses these and does something else, so they must not be called invalid
  inspect(
    bashisms(parse("( [[ -f x ]] )").0).differs.join(","),
    content="[[ ]]",
  )
  inspect(
    bashisms(parse("if ((1)); then :; fi").0).differs.join(","),
    content="(( ))",
  )
  inspect(bashisms(parse("echo a | cat").0).differs.join(","), content="")
  inspect(bashisms(parse("echo a | cat").0).rejects.join(","), content="")
}
