///|
/// Streaming input for callers that have many commands and do not want to pay
/// process startup once per command.
///
/// The framing is one JSON string per line. A command can contain newlines
/// (heredocs, multi-line loops), so a bare line cannot carry one, and JSON is
/// already the escaping this tool speaks. The output side needs no framing of
/// its own: a report is exactly one line, because JSON escapes the control
/// characters that would otherwise break that.
///
/// Everything here is pure: the CLI supplies bytes and prints what comes back,
/// which keeps the edge cases (a line split across reads, a line with no
/// newline at EOF, a line that never ends) testable without a subprocess.

///|
/// A line the framer found, or a line it refused.
pub enum FramedLine {
  Line(String)
  /// Longer than the cap, with no newline in sight. Refused rather than
  /// buffered: an unterminated stream would otherwise grow without limit.
  TooLong
} derive(Debug, Eq)

///|
/// A name for the JSON type, so a caller who wrote an object where a string
/// belongs is told which of the two they got.
fn json_kind(j : Json) -> String {
  match j {
    Json::String(_) => "a string"
    Json::Object(_) => "an object"
    Json::Array(_) => "an array"
    Json::Number(_) => "a number"
    Json::True | Json::False => "a boolean"
    Json::Null => "null"
  }
}

///|
/// Turn one input line into the command it carries.
///
/// The string is converted back to bytes and analysed through the same entry
/// point as a single-shot call, so a command means the same thing either way --
/// including how a NUL inside it is dropped and joined, which is what the shell
/// does with it.
///
/// Every line is either a command or a refusal, and an empty line is a refusal
/// like any other line that is not a JSON string. Skipping it quietly would be
/// friendlier until a caller zipped their input lines against the output lines
/// and got a silent off-by-one, which is the kind of wrong answer this tool
/// exists not to give.
pub fn decode_stream_line(line : StringView) -> Result[Bytes, String] {
  if line.is_empty() {
    return Err("empty line: expected a JSON string")
  }
  let json = @json.parse(line) catch {
    err => return Err("not valid JSON: \{err.to_string()}")
  }
  match json {
    Json::String(s) => Ok(@utf8.encode(s))
    other => Err("expected a JSON string, got \{json_kind(other)}")
  }
}

///|
/// The object a refused line answers with. It is deliberately not a report:
/// no `version`, no `status`. "Your input line was not a JSON string" and "the
/// shell would refuse this command" are different findings, and a caller that
/// cannot tell them apart will read one as the other.
pub fn stream_error(message : String, line : Int) -> Json {
  Json::object({
    "error": Json::string(message),
    "line": Json::number(line.to_double()),
  })
}

///|
/// Where the first `\n` is, starting at `from`.
fn newline_at(data : BytesView, from : Int) -> Int? {
  let mut i = from
  while i < data.length() {
    if data[i] == b'\n' {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// A line's bytes, without its terminator and without a trailing CR, so CRLF
/// input behaves like LF input.
fn line_bytes(data : BytesView, start : Int, end : Int) -> BytesView {
  let mut stop = end
  if stop > start && data[stop - 1] == b'\r' {
    stop -= 1
  }
  data[start:stop]
}

///|
/// Splits arriving bytes into lines, holding only an incomplete tail.
///
/// `max_line` bounds one line. It is a parameter rather than a constant so the
/// behaviour at the bound can be tested with a cap of a few bytes instead of
/// megabytes.
pub struct LineFramer {
  pending : @buffer.Buffer
  max_line : Int
  mut dropping : Bool
}

///|
/// The default cap on one line: room for any command a person would write,
/// including a megabyte-scale heredoc, while still bounding what an
/// unterminated stream can make this process hold.
pub fn max_stream_line() -> Int {
  8 * 1024 * 1024
}

///|
pub fn LineFramer::new(max_line? : Int) -> LineFramer {
  {
    pending: @buffer.Buffer(),
    max_line: max_line.unwrap_or(max_stream_line()),
    dropping: false,
  }
}

///|
/// Feed one chunk and take every complete line out of it. Reports can therefore
/// go out while the input is still arriving, which is the whole point of the
/// mode.
pub fn LineFramer::push(
  self : LineFramer,
  chunk : BytesView,
) -> Array[FramedLine] {
  let out : Array[FramedLine] = []
  self.pending.write_bytes(chunk)
  let data = self.pending.to_bytes()
  let mut start = 0
  if self.dropping {
    // Still looking for the end of a line that was already refused.
    match newline_at(data, 0) {
      Some(i) => {
        start = i + 1
        self.dropping = false
      }
      None => {
        self.pending.reset()
        return out
      }
    }
  }
  for ;; {
    match newline_at(data, start) {
      None => break
      Some(i) => {
        // Lossy on purpose: a line that is not valid UTF-8 is not valid JSON
        // either, and the refusal message is more useful than a crash.
        out.push(Line(@utf8.decode_lossy(line_bytes(data, start, i))))
        start = i + 1
      }
    }
  }
  // Keep the tail. Rebuilding is one copy per chunk, not per line.
  let rest = data[start:]
  self.pending.reset()
  self.pending.write_bytes(rest)
  if self.pending.length() > self.max_line {
    self.pending.reset()
    self.dropping = true
    out.push(TooLong)
  }
  out
}

///|
/// The last line, which ended at EOF instead of at a newline. None when nothing
/// is left over.
pub fn LineFramer::finish(self : LineFramer) -> FramedLine? {
  if self.dropping || self.pending.length() == 0 {
    return None
  }
  let data = self.pending.to_bytes()
  self.pending.reset()
  Some(Line(@utf8.decode_lossy(line_bytes(data, 0, data.length()))))
}
