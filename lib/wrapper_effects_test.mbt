///|
/// Wrappers: the programs whose whole job is to run the command they are handed
/// (`env`, `timeout`, `nice`, `xargs`, ...).
///
/// Measured with the shim — `env rm -rf victim.txt` ends in the real program
/// deleting the file. Before this each one reported "an unmodelled program ran",
/// which is true and says nothing about what it ran.

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
    if @lib.analyze(src).impact.uncertain {
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
  if !@lib.analyze("env cd /tmp").impact.uncertain {
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
  if !@lib.analyze("xargs rm").impact.uncertain {
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
