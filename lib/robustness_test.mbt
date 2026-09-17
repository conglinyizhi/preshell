///|
/// Robustness: the tool is fed arbitrary text by whoever calls it, so the bar
/// is that it always answers and never takes the process down.
///
/// Every case here came from probing, and three of them were real defects:
/// `((` and `[[` aborted the process through an inverted slice range, 40k
/// nested `if` overflowed the native stack, and both diagnostics and effects
/// used to grow with the input without bound. A regression in this file kills
/// the test binary, which is the point.
test "malformed input always produces a report" {
  let cases = [
    "(( ", "((1", "((1+", "((((", "(( ))", "echo $((", "echo $((((", "$((", "$((1+2",
    "$(", "${", "$[", "$'", "$\"", "`", "``", "[[", "[[ ]]", "[", "]", "{", "}",
    ")", ";;", ";", "|", "||", "&", "&&", "!", ">", ">>", "<", "<<", "<<<", "<&",
    ">&", "2>", "2>&", "&>", "a[", "${}", "${{\n", "'", "\"", "\\", "# comment only",
    "case", "if", "for ((", "while", "do", "done", "esac",
  ]
  for src in cases {
    let r = analyze(src)
    // Reaching here at all is the assertion: a crash would abort the test
    // binary rather than fail one case.
    inspect(r.issues_dropped >= 0, content="true")
  }
}

///|
test "an unclosed compound command prefix is reported, not accepted" {
  // These two used to abort: the raw-text slice between the opening token and
  // end of input came out inverted (`unsafe_substring(start=2, end=0)`).
  debug_inspect(analyze("((").status, content="Unsupported")
  debug_inspect(analyze("[[ ").status, content="Unsupported")
  // Same class, no crash: `((1+2` is not a command that finishes, and saying
  // Complete would read as "nothing happens here".
  debug_inspect(analyze("((1+2").status, content="Unsupported")
  debug_inspect(analyze("((1+2))").status, content="Complete")
}

///|
test "deep nesting is bounded and reported, never a crash" {
  // 40k nested `if` overflowed the native stack before max_nesting existed.
  let deep = "if true; then ".repeat(20000) + "echo x" + "; fi".repeat(20000)
  let r = analyze(deep)
  debug_inspect(r.status, content="Unsupported")
  debug_inspect(r.impact.uncertain, content="true")
  // Well inside the limit still parses.
  let ok = "if true; then ".repeat(200) + "echo x" + "; fi".repeat(200)
  debug_inspect(analyze(ok).status, content="Complete")
}

///|
test "a report never grows with the input without bound" {
  // Diagnostics scale with the input: 5k nested substitutions produced 5001
  // issues where 64 and a count are enough.
  let deep = "echo " + "$(".repeat(5000) + "x" + ")".repeat(5000)
  let r = analyze(deep)
  inspect(r.issues.length() <= 64, content="true")
  debug_inspect(r.issues_dropped > 0, content="true")
  // Effects are the answer, so the cap is generous, but it exists and any drop
  // is stated and forces `uncertain`.
  let many = "echo x\n".repeat(20000)
  let r2 = analyze(many)
  inspect(r2.impact.effects.length() <= 4096, content="true")
  debug_inspect(r2.impact.effects_dropped > 0, content="true")
  debug_inspect(r2.impact.uncertain, content="true")
}

///|
test "a null byte does not hide what follows it" {
  // bash drops NUL bytes and joins the two sides: `true\0; rm -rf /` runs the
  // `rm`. Truncating at the NUL instead used to report "Complete, nothing
  // touched" for a command that deletes everything.
  let r = analyze("true\u{0}; rm -rf /")
  // The parse succeeded, so the status says so; the note and `uncertain` carry
  // the caveat that the text we analysed is not the bytes that arrived.
  debug_inspect(r.status, content="Complete")
  debug_inspect(r.impact.uncertain, content="true")
  let deletes : Array[String] = []
  for e in r.impact.effects {
    if e.kind is Delete {
      deletes.push(e.target)
    }
  }
  debug_inspect(deletes, content="[\"/\"]")
  inspect(
    r.issues.any(fn(i) { i.kind is Note && i.message.contains("null byte") }),
    content="true",
  )
}

///|
test "bytes are decoded lossily and reported, never rejected" {
  // A stray invalid byte used to make the whole run fail: exit 1, no report.
  let r = analyze_bytes(b"\xff\xfe\xfd echo hi\n")
  debug_inspect(r.status, content="Complete")
  debug_inspect(r.impact.uncertain, content="true")
  inspect(r.issues.any(fn(i) { i.kind is Note }), content="true")
  // Valid multi-byte input still works, three- and four-byte forms included.
  debug_inspect(
    analyze_bytes(b"\xe4\xb8\xad\xe6\x96\x87").status,
    content="Complete",
  )
  debug_inspect(analyze_bytes(b"\xf0\x9f\x98\x80").status, content="Complete")
  // A truncated sequence is reported, not silently dropped.
  let t = analyze_bytes(b"\xe4\xb8")
  debug_inspect(t.status, content="Complete")
  debug_inspect(t.impact.uncertain, content="true")
}

///|
test "characters outside the BMP do not end the scan" {
  // MoonBit strings are UTF-16: an emoji is a surrogate pair, and stepping one
  // code unit at a time landed inside it, where get_char returns None. The
  // scanner read that as end of input, so `echo "🧐"` came back as an
  // unterminated double quote.
  let r = analyze("echo \"🧐\"")
  debug_inspect(r.status, content="Complete")
  debug_inspect(r.impact.uncertain, content="false")
  debug_inspect(
    analyze("echo \"汉字扩展 𠀀\"").status,
    content="Complete",
  )
  // A path with an emoji survives into the effects.
  let im = analyze("rm -rf \"📁 dir\"").impact
  let targets : Array[String] = []
  for e in im.effects {
    if e.kind is Delete {
      targets.push(e.target)
    }
  }
  debug_inspect(targets, content="[\"📁 dir\"]")
}

///|
test "a dollar sign before a closing quote is just a dollar sign" {
  // `"A$x$"` is text ending in a dollar sign, not the start of a `$"..."`:
  // bash reads it that way, and so must this. Treating it as a translation
  // string swallowed the rest of the file, which is how five real scripts came
  // back as "unterminated double quote".
  debug_inspect(analyze("echo \"A[[:digit:]]\\+$\"").status, content="Complete")
  debug_inspect(analyze("echo \"D$x'y'\"").status, content="Complete")
  debug_inspect(analyze("echo \"C$'ansi'\"").status, content="Complete")
  // At word level they are real quoting constructs.
  debug_inspect(analyze("echo $\"loc\"").status, content="Complete")
  debug_inspect(analyze("echo $'ansi'").status, content="Complete")
}
