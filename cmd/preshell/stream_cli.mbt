///|
/// Stream mode at the command line: one request per line on stdin, one answer
/// per line on stdout, in the same order.
///
/// Two properties are load-bearing. Every input line is answered exactly once,
/// refusals included, so the caller's input and output stay lined up; and the
/// answer is written straight to the file descriptor rather than through a
/// buffered writer, because a report is a few hundred bytes and a buffer that
/// size turns "streaming" into "one batch at the end".

///|
/// Answer one framed line: exactly one line of output, either a report or a
/// refusal. Nothing is skipped, so a caller can line up its input and its output
/// without counting anything.
async fn answer_stream_line(
  line : String,
  number : Int,
  shell : String?,
  probe : Bool,
  counts : Counts,
  base_cwd : String?,
  base_note : String?,
  payload_max : Int?,
) -> Unit {
  match @lib.decode_stream_line(line) {
    Ok(request) => {
      let bytes = request.command
      let raw = if probe {
        @lib.analyze_bytes_probe(bytes, base_cwd~, payload_max~)
      } else {
        // The same two steps as the single-shot path: the dialect is chosen
        // from the text, so a shebang still decides under `auto`, and the
        // analysis runs on the bytes, so a NUL byte and invalid UTF-8 are
        // treated the way the shell treats them. Anything else would make the
        // two modes disagree about the same command.
        let (text, _) = @lib.decode_command(bytes)
        @lib.analyze_bytes_dialect(
          bytes,
          dialect_for(text, shell),
          base_cwd~,
          payload_max~,
        )
      }
      // Every line stands alone, so the caveat about the base is repeated here
      // rather than announced once at the start of the stream.
      let report = match base_note {
        Some(note) => @lib.add_note(raw, note)
        None => raw
      }
      // The report goes out untouched except for that caveat: an id, when the
      // caller used one, arrives in an envelope around it, so the report itself
      // stays the same object the single-shot mode prints.
      write_report_line(
        @json.to_json(
          @lib.stream_report_json(@json.to_json(report), request.id),
        ).stringify(),
      )
      counts.reports += 1
    }
    Err(refused) => {
      @stdio.stderr.write("PreShell: line \{number}: \{refused.message}\n")
      write_report_line(
        @lib.stream_error(refused.message, number, refused.id).stringify(),
      )
      counts.errors += 1
    }
  }
}

///|
/// One line of stdout, written straight to the descriptor.
///
/// `println` goes through a buffer: a single report is a few hundred bytes, so
/// nothing appears until the buffer fills or the process exits -- which would
/// make this mode batch-only and lose the thing it exists for. The async stdout
/// has no such buffer, and mixing the two in one process would also reorder the
/// output, so the stream path uses only this.
async fn write_report_line(text : String) -> Unit {
  @stdio.stdout.write(@utf8.encode(text + "\n"))
}

///|
/// Read one JSON string per line from stdin and answer one line per request.
///
/// Each report is written as soon as it is analysed, so a caller that keeps this
/// process alive gets the answer to a command before sending the next one. That
/// is the entire reason the mode exists: process startup costs about two hundred
/// times what the analysis does.
async fn stream_reports(
  shell : String?,
  probe : Bool,
  base_cwd : String?,
  base_note : String?,
  payload_max : Int?,
) -> Unit {
  let framer = @lib.LineFramer::new()
  let counts : Counts = { reports: 0, errors: 0, }
  let chunk : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  let mut number = 0
  let mut read_failed = false
  for ;; {
    let n = @stdio.stdin.read(chunk, max_len=chunk.length()) catch { _ => -1 }
    if n < 0 {
      read_failed = true
      break
    }
    if n == 0 {
      break
    }
    for framed in framer.push(Bytes::from_array(chunk.exact_view(end=n))) {
      match framed {
        @lib.FramedLine::Line(line) => {
          number += 1
          answer_stream_line(
            line, number, shell, probe, counts, base_cwd, base_note, payload_max,
          )
        }
        @lib.FramedLine::TooLong => {
          // The line was dropped before it could be parsed, but it still
          // occupied a line: refusing it out loud keeps the caller's numbering
          // matching their input.
          number += 1
          let message = "line longer than \{@lib.max_stream_line()} bytes"
          @stdio.stderr.write("PreShell: line \{number}: \{message}\n")
          write_report_line(
            @lib.stream_error(message, number, None).stringify(),
          )
          counts.errors += 1
        }
      }
    }
  }
  // A last line that ended at EOF rather than at a newline is still a request.
  match framer.finish() {
    Some(@lib.FramedLine::Line(line)) => {
      number += 1
      answer_stream_line(
        line, number, shell, probe, counts, base_cwd, base_note, payload_max,
      )
    }
    _ => ()
  }
  @stdio.stderr.write(
    "PreShell: \{counts.reports} reports, \{counts.errors} lines refused\n",
  )
  if read_failed {
    @stdio.stderr.write("PreShell: reading stdin failed\n")
    exit(io_exit_code)
  }
}
