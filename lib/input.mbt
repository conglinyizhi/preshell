///|
/// Input normalisation.
///
/// Two things here are not cosmetic:
///
/// A NUL byte is **dropped**, joined with what follows, because that is what
/// bash does: `true\0; rm -rf /` runs the `rm`. Truncating at the NUL instead
/// prints "Complete, nothing touched" for a command that deletes everything,
/// which is the one failure mode this tool exists to prevent.
///
/// Invalid UTF-8 is decoded lossily rather than rejected. Callers hand over
/// whatever bytes they have, and a command line with one stray byte is still
/// mostly analysable; the replacement is reported as an issue so nobody has to
/// guess why a path looks odd.
pub fn decode_command(bytes : Bytes) -> (String, Array[String]) {
  let sb = StringBuilder()
  let notes : Array[String] = []
  let n = bytes.length()
  let mut i = 0
  let mut bad_bytes = 0
  for ;; {
    if i >= n {
      break
    }
    let b = bytes[i].to_int()
    if b < 0x80 {
      if b == 0 {
        // bash ignores NUL bytes; so do we, and say so.
        if !notes.any(fn(x) { x.contains("null byte") }) {
          notes.push(
            "null byte in input: ignored and joined, the way the shell does it",
          )
        }
      } else {
        sb.write_char(b.unsafe_to_char())
      }
      i += 1
      continue
    }
    let (width, cp) = match utf8_width(b) {
      0 => (1, -1)
      w => {
        let cp = utf8_codepoint(bytes, i, w)
        if cp < 0 {
          (1, -1)
        } else {
          (w, cp)
        }
      }
    }
    if cp >= 0 {
      sb.write_char(cp.unsafe_to_char())
      i += width
    } else {
      sb.write_char('\u{fffd}')
      bad_bytes += 1
      i += 1
    }
  }
  if bad_bytes > 0 {
    notes.push(
      "input is not valid UTF-8 (\{bad_bytes} byte(s) replaced): the command may not be what it looks like",
    )
  }
  (sb.to_string(), notes)
}

///|
/// How many bytes a UTF-8 sequence starting with `b` occupies, or 0 when `b`
/// cannot start one.
fn utf8_width(b : Int) -> Int {
  if b >= 0xC2 && b <= 0xDF {
    2
  } else if b >= 0xE0 && b <= 0xEF {
    3
  } else if b >= 0xF0 && b <= 0xF4 {
    4
  } else {
    0
  }
}

///|
/// The code point at `i`, or -1 when the sequence is malformed.
fn utf8_codepoint(bytes : Bytes, i : Int, width : Int) -> Int {
  let mut cp = match width {
    2 => bytes[i].to_int() & 0x1F
    3 => bytes[i].to_int() & 0x0F
    _ => bytes[i].to_int() & 0x07
  }
  for k in 1..<width {
    if i + k >= bytes.length() {
      return -1
    }
    let c = bytes[i + k].to_int()
    if c < 0x80 || c > 0xBF {
      return -1
    }
    cp = (cp << 6) | (c & 0x3F)
  }
  if cp > 0x10FFFF {
    -1
  } else if cp >= 0xD800 && cp <= 0xDFFF {
    // Surrogate halves are not valid UTF-8 encodings.
    -1
  } else {
    cp
  }
}
