///|
/// A line of streaming input is either a JSON string or an object carrying the
/// command plus the caller's id. These fix the refusals as carefully as the
/// acceptances: a caller whose line was not a request has to be told what was
/// wrong with it, and a worker pool has to be able to tell which of its requests
/// was refused.
test "a bare string, or an object with an id" {
  match decode_stream_line("\"rm -rf build\"") {
    Ok(r) => inspect(@utf8.decode_lossy(r.command), content="rm -rf build")
    _ => fail("a JSON string is a request")
  }
  // A bare string carries no id, and that is not the same as an id of null.
  match decode_stream_line("\"ls\"") {
    Ok(r) =>
      match r.id {
        None => ()
        Some(v) =>
          inspect(v.stringify(), content="this string should have no id")
      }
    _ => fail("a JSON string is a request")
  }
  match decode_stream_line("{\"id\": 17, \"command\": \"ls -la\"}") {
    Ok(r) => {
      inspect(@utf8.decode_lossy(r.command), content="ls -la")
      match r.id {
        Some(v) => inspect(v.stringify(), content="17")
        None => fail("the id must come back")
      }
    }
    _ => fail("an object with command and id is a request")
  }
  // Ids are echoed verbatim, whatever JSON value they are.
  match decode_stream_line("{\"id\": \"w3-91\", \"command\": \"pwd\"}") {
    Ok(r) =>
      match r.id {
        Some(v) => inspect(v.stringify(), content="\"w3-91\"")
        None => fail("a string id must come back")
      }
    _ => fail("a string id is allowed")
  }
}

///|
/// Every line is answered, including the ones that are refused: a mode where
/// some lines vanish would leave a caller's input and output counts quietly
/// different.
test "refusals name the problem, and keep the id when they can" {
  match decode_stream_line("") {
    Err(r) => {
      inspect(r.message.contains("empty line"), content="true")
      match r.id {
        None => ()
        Some(_) => fail("an empty line has no id to keep")
      }
    }
    _ => fail("an empty line is refused, never skipped")
  }
  match decode_stream_line("   ") {
    Err(r) => inspect(r.message.contains("not valid JSON"), content="true")
    _ => fail("whitespace is not a request")
  }
  // An object with just a command is a legitimate request: the id is optional,
  // and its absence must not be confused with an id of null.
  match decode_stream_line("{\"command\":\"ls\"}") {
    Ok(r) =>
      match r.id {
        None => ()
        Some(_) => fail("no id was given, so none may be invented")
      }
    Err(r) => {
      inspect(r.message, content="this line is a request")
      fail("command alone is enough")
    }
  }
  // An unknown key is refused rather than ignored: a caller that wrote
  // "timeout" believes a timeout applies.
  match decode_stream_line("{\"id\": 7, \"command\": \"ls\", \"timeout\": 5}") {
    Err(r) => {
      inspect(r.message.contains("timeout"), content="true")
      match r.id {
        Some(v) => inspect(v.stringify(), content="7")
        None => fail("the refusal must still name the request it belongs to")
      }
    }
    _ => fail("an unknown key is refused")
  }
  // The id survives even when the command itself is unusable: that is the case
  // a worker pool cannot recover from otherwise.
  match decode_stream_line("{\"id\": 9, \"command\": 5}") {
    Err(r) => {
      inspect(r.message.contains("a number"), content="true")
      match r.id {
        Some(v) => inspect(v.stringify(), content="9")
        None => fail("the refusal must keep the id")
      }
    }
    _ => fail("a non-string command is refused")
  }
  match decode_stream_line("{\"id\": 9}") {
    Err(r) => inspect(r.message.contains("no \"command\""), content="true")
    _ => fail("an object with no command is refused")
  }
}

///|
/// The command travels as JSON, but it is analysed as bytes through the same
/// entry point as a single-shot call. An escaped NUL is the case that proves it:
/// the shell drops NUL bytes and joins what follows, and the tool has to agree
/// with the shell whichever mode the command arrived in.
test "an escaped NUL survives the round trip to the byte path" {
  match decode_stream_line("\"true\\u0000; rm -rf /\"") {
    Ok(r) => {
      // The NUL is in the bytes handed to the analyser; dropping it is
      // `decode_command`'s job, not this one's, so both modes drop it the same
      // way instead of each having its own rule.
      inspect(r.command[4].to_int(), content="0")
      inspect(@utf8.decode_lossy(r.command).contains("\u{0}"), content="true")
    }
    _ => fail("escaped NUL decodes to a NUL byte")
  }
  match decode_stream_line("\"echo \\u4f60\\u597d\"") {
    Ok(r) => inspect(@utf8.decode_lossy(r.command), content="echo 你好")
    _ => fail("non-ASCII survives")
  }
}

///|
/// A refusal is not a report, and an envelope is not a report either: the report
/// inside it stays exactly what the single-shot mode prints, which is what lets
/// the two modes be compared byte for byte.
test "the id goes in an envelope, never into the report" {
  let bare = stream_error("expected a JSON string, got an object", 7, None)
  let s = bare.stringify()
  inspect(s.contains("\"error\""), content="true")
  inspect(s.contains("\"line\":7"), content="true")
  // No report keys: a caller must not be able to mistake this for an analysis.
  inspect(s.contains("status"), content="false")
  inspect(s.contains("version"), content="false")

  let tagged = stream_error("nope", 7, Some(Json::number(3))).stringify()
  inspect(tagged.contains("\"id\":3"), content="true")
  inspect(tagged.contains("\"line\":7"), content="true")

  let report = Json::object({ "version": Json::number(1) })
  inspect(report.stringify(), content="{\"version\":1}")
  inspect(
    stream_report_json(report, None).stringify(),
    content="{\"version\":1}",
  )
  inspect(
    stream_report_json(report, Some(Json::string("a"))).stringify(),
    content="{\"id\":\"a\",\"report\":{\"version\":1}}",
  )
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
