///|
/// A line of streaming input is one JSON string. These fix the refusals as
/// carefully as the acceptances: a caller whose line was not a string has to be
/// told which of the two they sent, or they will read "not a string" as "the
/// command is bad".
test "one JSON string per line, and nothing else" {
  match decode_stream_line("\"rm -rf build\"") {
    Ok(b) => inspect(@utf8.decode_lossy(b), content="rm -rf build")
    _ => fail("a JSON string is a command")
  }
  // Every line is answered, including the ones that are refused: a mode where
  // some lines vanish would leave a caller's input and output counts quietly
  // different. An empty line is a refusal, not a skipped request.
  match decode_stream_line("") {
    Err(m) => inspect(m.contains("empty line"), content="true")
    _ => fail("an empty line is refused, never skipped")
  }
  match decode_stream_line("   ") {
    Err(m) => inspect(m.contains("not valid JSON"), content="true")
    _ => fail("whitespace is not a JSON string")
  }
  // Refusals name what was sent.
  match decode_stream_line("{\"command\":\"ls\"}") {
    Err(m) => inspect(m.contains("an object"), content="true")
    _ => fail("an object is not a string")
  }
  match decode_stream_line("42") {
    Err(m) => inspect(m.contains("a number"), content="true")
    _ => fail("a number is not a string")
  }
  match decode_stream_line("ls -la") {
    Err(m) => inspect(m.contains("not valid JSON"), content="true")
    _ => fail("bare text is not JSON")
  }
  match decode_stream_line("[1,2]") {
    Err(m) => inspect(m.contains("an array"), content="true")
    _ => fail("an array is not a string")
  }
}

///|
/// The command travels as JSON, but it is analysed as bytes through the same
/// entry point as a single-shot call. An escaped NUL is the case that proves it:
/// the shell drops NUL bytes and joins what follows, and the tool has to agree
/// with the shell whichever mode the command arrived in.
test "an escaped NUL survives the round trip to the byte path" {
  match decode_stream_line("\"true\\u0000; rm -rf /\"") {
    Ok(b) => {
      // The NUL is in the bytes handed to the analyser; dropping it is
      // `decode_command`'s job, not this one's, so both modes drop it the same
      // way instead of each having its own rule.
      inspect(b[4].to_int(), content="0")
      inspect(@utf8.decode_lossy(b).contains("\u{0}"), content="true")
    }
    _ => fail("escaped NUL decodes to a NUL byte")
  }
  match decode_stream_line("\"echo \\u4f60\\u597d\"") {
    Ok(b) => inspect(@utf8.decode_lossy(b), content="echo 你好")
    _ => fail("non-ASCII survives")
  }
}

///|
test "a refused line answers with something that is not a report" {
  let j = stream_error("expected a JSON string, got an object", 7)
  let s = j.stringify()
  inspect(s.contains("\"error\""), content="true")
  inspect(s.contains("\"line\":7"), content="true")
  // No report keys: a caller must not be able to mistake this for an analysis.
  inspect(s.contains("status"), content="false")
  inspect(s.contains("version"), content="false")
}

///|
test "the framer hands out lines as they complete" {
  let f = LineFramer::new()
  debug_inspect(f.push(b"a\nb\n"), content="[Line(\"a\"), Line(\"b\")]")
  // A line split across two reads is one line, not two.
  debug_inspect(f.push(b"tail"), content="[]")
  debug_inspect(f.push(b"-end\n"), content="[Line(\"tail-end\")]")
  // CRLF input behaves like LF input.
  debug_inspect(f.push(b"crlf\r\n"), content="[Line(\"crlf\")]")
  // A blank line is a line; deciding it is not a request happens later.
  debug_inspect(f.push(b"\n"), content="[Line(\"\")]")
  // Several lines plus an incomplete tail, in one chunk.
  debug_inspect(f.push(b"x\ny\nz"), content="[Line(\"x\"), Line(\"y\")]")
  match f.finish() {
    Some(Line(s)) => inspect(s, content="z")
    _ => fail("an unterminated last line is still a line")
  }
  // Nothing left after that, and nothing invented.
  match f.finish() {
    None => ()
    Some(l) => {
      debug_inspect(l, content="nothing")
      fail("finish invented a line")
    }
  }
}

///|
test "a line that never ends is refused, not buffered" {
  let f = LineFramer::new(max_line=4)
  // Over the cap with no newline in sight: refused, and the rest of that line
  // is dropped so it cannot be mistaken for the next request.
  debug_inspect(f.push(b"abcdefgh"), content="[TooLong]")
  debug_inspect(f.push(b"ijkl\n"), content="[]")
  debug_inspect(f.push(b"next\n"), content="[Line(\"next\")]")
  // The dropped line leaves nothing behind at EOF either.
  match f.finish() {
    None => ()
    Some(l) => {
      debug_inspect(l, content="nothing")
      fail("a dropped line came back at EOF")
    }
  }
}
