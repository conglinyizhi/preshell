///|
/// The payloads a command line produces, one entry per effect that carries one:
/// `target source where [text] bytes=N truncated=B`.
///
/// Rendered this way because every field matters in the assertion: the source
/// says where the text came from, the flag or delimiter says how the caller can
/// find it again in the command text, and the size pair says whether what came
/// back is all of it.
fn payloads_of(src : String, max? : Int = 4096) -> String {
  let r = @lib.analyze(src, payload_max=Some(max))
  let parts : Array[String] = []
  for e in r.impact.effects {
    match e.payload {
      None => ()
      Some(p) => {
        let site = match p.flag {
          Some(f) => f
          None =>
            match p.delimiter {
              Some(d) => "<<" + d
              None => ""
            }
        }
        parts.push(
          "\{e.target} \{p.source} \{site} [\{p.text}] bytes=\{p.bytes} truncated=\{p.truncated}",
        )
      }
    }
  }
  parts.join(" | ")
}

///|
/// The payload of the single effect that carries one, or a marker when there is
/// none.
fn payload_of_one(src : String, max? : Int = 4096) -> String {
  let out = payloads_of(src, max~)
  if out == "" {
    "<none>"
  } else {
    out
  }
}

///|
/// Payloads are off unless asked for: a report that grows without being asked
/// is one a caller cannot budget for. This is the property that keeps the
/// default output shape unchanged.
test "no payload unless the caller asks" {
  let r = @lib.analyze("python3 -c 'print(1)'")
  for e in r.impact.effects {
    inspect(e.payload is None, content="true")
  }
  inspect(
    @lib.analyze("python3 -c 'print(1)'", payload_max=Some(64)).impact.effects[0].payload
    is Some(_),
    content="true",
  )
}

///|
/// The option that carries the source is the payload. The text is the text as
/// written: quotes and escapes resolved, `$x` left alone because the shell has
/// not expanded it yet.
test "an interpreter's -c argument is its payload" {
  inspect(
    payload_of_one("python3 -c 'print(1)'"),
    content="python3 flag -c [print(1)] bytes=8 truncated=false",
  )
  // Inside double quotes the shell does not turn `\n` into a newline, so the
  // text keeps the two characters it was written with.
  inspect(
    payload_of_one("python3 -c \"import os\\nprint(os.getcwd())\""),
    content="python3 flag -c [import os\\nprint(os.getcwd())] bytes=29 truncated=false",
  )
  // The whole word has to match: `-c` inside another option is not this one.
  inspect(payload_of_one("python3 -m json.tool f.json"), content="<none>")
  inspect(payload_of_one("python3 -c"), content="<none>")
  // An expansion is left as written, and so is the variable name in it.
  inspect(
    payload_of_one("python3 -c 'print(\"$HOME\")'"),
    content="python3 flag -c [print(\"$HOME\")] bytes=14 truncated=false",
  )
  // The glued long form is one word, not two.
  inspect(
    payload_of_one("node --eval='console.log(4)'"),
    content="node flag --eval [console.log(4)] bytes=14 truncated=false",
  )
  // Every interpreter in the table, and the options each one takes.
  inspect(
    payload_of_one("sh -c 'echo x'"),
    content="sh flag -c [echo x] bytes=6 truncated=false",
  )
  inspect(
    payload_of_one("bash -c 'echo x'"),
    content="bash flag -c [echo x] bytes=6 truncated=false",
  )
  inspect(
    payload_of_one("node -e 'x'"),
    content="node flag -e [x] bytes=1 truncated=false",
  )
  inspect(
    payload_of_one("perl -E 'say 1'"),
    content="perl flag -E [say 1] bytes=5 truncated=false",
  )
  inspect(
    payload_of_one("ruby -e 'puts 1'"),
    content="ruby flag -e [puts 1] bytes=6 truncated=false",
  )
  inspect(
    payload_of_one("php -r 'echo 1;'"),
    content="php flag -r [echo 1;] bytes=7 truncated=false",
  )
}

///|
/// A program name is the program, whatever path and version it was spelled
/// with. The version suffix is only dropped when what is left is a name this
/// tool knows, so an unknown program never becomes a known one.
test "the interpreter is recognised through its path and version" {
  inspect(
    payload_of_one("/usr/bin/python3.12 -c 'x'"),
    content="/usr/bin/python3.12 flag -c [x] bytes=1 truncated=false",
  )
  inspect(
    payload_of_one("python2 -c 'x'"),
    content="python2 flag -c [x] bytes=1 truncated=false",
  )
  inspect(
    payload_of_one("nodejs -e 'x'"),
    content="nodejs flag -e [x] bytes=1 truncated=false",
  )
  // Not interpreters, and not read as one: the name has to be one we know.
  inspect(payload_of_one("luajit -e 'x'"), content="<none>")
  inspect(payload_of_one("pypy3x -c 'x'"), content="<none>")
  inspect(payload_of_one("git -c user.name=x status"), content="<none>")
  // awk is not one of them either, but it is not "none": its program is an
  // operand, and that shape is read below.
}

///|
/// A here-document body is the payload of the program it feeds, and the
/// delimiter comes along so a caller can find the body in the text again.
test "a here-document body is the payload of the program it feeds" {
  inspect(
    payload_of_one("python3 - <<'PY'\nprint(1)\nPY"),
    content="python3 heredoc <<PY [print(1)\n] bytes=9 truncated=false",
  )
  // The body keeps the newline that ends it: that is what arrived on stdin.
  inspect(
    payload_of_one("python3 - <<PY\nx\nPY"),
    content="python3 heredoc <<PY [x\n] bytes=2 truncated=false",
  )
  // An option that carries the source wins: `-c` reads the program, and the
  // body arrives as data.
  inspect(
    payload_of_one("python3 -c 'print(1)' <<EOT\ndata\nEOT"),
    content="python3 flag -c [print(1)] bytes=8 truncated=false",
  )
  // Nothing feeds it: a pipe's text is not in this command line at all.
  inspect(payload_of_one("printf 'x' | python3 -"), content="<none>")
}

///|
/// The payload belongs to the program that runs, not to the word that owns it:
/// a here-document inside a loop or a wrapper still belongs to the interpreter
/// on the other end of it.
test "a payload is found wherever its program is" {
  // The owner of the here-document is inside a loop body. A text scanner that
  // takes the first word of the line finds `do` here, not python3.
  inspect(
    payload_of_one(
      "for f in a b; do python3 - \"$f\" <<'PY'\nprint(1)\nPY\ndone",
    ),
    content="python3 heredoc <<PY [print(1)\n] bytes=9 truncated=false",
  )
  // The program is behind a runner that was handed options of its own.
  inspect(
    payload_of_one("uv run --with websockets python3 -c 'print(2)'"),
    content="python3 flag -c [print(2)] bytes=8 truncated=false",
  )
  // Behind a wrapper, with the body belonging to the outer command.
  inspect(
    payload_of_one("env FOO=1 python3 -c 'x'"),
    content="python3 flag -c [x] bytes=1 truncated=false",
  )
  inspect(
    payload_of_one("nice python3 - <<PY\nz\nPY"),
    content="python3 heredoc <<PY [z\n] bytes=2 truncated=false",
  )
  // Behind a container runtime: the image is what starts, and what follows it
  // is what starts inside it.
  inspect(
    payload_of_one("docker run --rm node -e 'console.log(1)'"),
    content="node flag -e [console.log(1)] bytes=14 truncated=false",
  )
  inspect(
    payload_of_one("docker run --rm python:3 python -c 'print(3)'"),
    content="python:3 flag -c [print(3)] bytes=8 truncated=false",
  )
}

///|
/// A capped payload says so, and it says how big the whole thing was. The cut
/// lands on a character boundary, so what comes back is text that was there.
test "a capped payload is a prefix that says it is one" {
  inspect(
    payload_of_one("python3 -c 'abcdefghijklmnop'", max=10),
    content="python3 flag -c [abcdefghij] bytes=16 truncated=true",
  )
  inspect(
    payload_of_one("python3 -c 'abc'", max=10),
    content="python3 flag -c [abc] bytes=3 truncated=false",
  )
  // Nine bytes of a ten-byte budget: the fourth character would not fit, and
  // half of it is not text.
  inspect(
    payload_of_one("python3 - <<PY\n你好世界，这是测试\nPY", max=10),
    content="python3 heredoc <<PY [你好世] bytes=28 truncated=true",
  )
  // A budget too small for even one character yields no text, and says so.
  inspect(
    payload_of_one("python3 -c '你'", max=2),
    content="python3 flag -c [] bytes=3 truncated=true",
  )
}

///|
/// Two commands on one line that name the same program and run different source
/// are two facts, not one: dedupe keeps them apart once the payload is on, and
/// still collapses them when it is off.
test "the payload is part of what makes two effects the same" {
  inspect(
    payloads_of("python3 -c a; python3 -c b"),
    content="python3 flag -c [a] bytes=1 truncated=false | python3 flag -c [b] bytes=1 truncated=false",
  )
  inspect(
    @lib.analyze("python3 -c a; python3 -c b").impact.effects.length(),
    content="1",
  )
}

///|
/// `awk` and `sed` put their program where a file name usually goes, which is
/// the shape an option table cannot express. Their text is still the command
/// line's own — `-f` is the exception in both, and a file is not this command
/// line.
test "awk and sed carry their program as an operand" {
  inspect(
    payload_of_one("awk '{print}' f.txt"),
    content="awk operand  [{print}] bytes=7 truncated=false",
  )
  // `-F` takes a value of its own, so the program is the word after it.
  inspect(
    payload_of_one("awk -F: '{print $1}' f.txt"),
    content="awk operand  [{print $1}] bytes=10 truncated=false",
  )
  inspect(
    payload_of_one("awk -F : '{print}' f.txt"),
    content="awk operand  [{print}] bytes=7 truncated=false",
  )
  inspect(
    payload_of_one("sed 's/a/b/' f.txt"),
    content="sed operand  [s/a/b/] bytes=6 truncated=false",
  )
  // `-n` takes no value, so the script is still the first operand.
  inspect(
    payload_of_one("sed -n '1p' f.txt"),
    content="sed operand  [1p] bytes=2 truncated=false",
  )
  // Several `-e` values are one program; sed joins them with a newline.
  inspect(
    payload_of_one("sed -e 's/a/b/' -e 's/c/d/' f.txt"),
    content="sed operand  [s/a/b/\ns/c/d/] bytes=13 truncated=false",
  )
  // A program that lives in a file is not in this command line.
  for
    src in [
      "awk -f p.awk f.txt", "sed -f s.sed f.txt", "sed --file=s.sed f.txt",
    ] {
    inspect(payloads_of(src), content="")
  }
  // The size pair follows the text, and the source is the operand.
  inspect(
    payload_of_one("awk 'BEGIN{print 1}' f", max=4),
    content="awk operand  [BEGI] bytes=14 truncated=true",
  )
}
