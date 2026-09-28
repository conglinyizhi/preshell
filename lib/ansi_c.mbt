///|
/// ANSI-C quoting: `$'...'` and the escapes inside it.
///
/// The shell resolves these before the word is used, so `$'\x2f'` is a `/` and
/// not four harmless characters. The body arrives as raw text from the lexer,
/// and it is decoded in one place because the named escapes and the two numeric
/// forms (`\xHH`, `\NNN`) all have to agree on where a run stops.

///|
/// `$'...'`: the escapes are resolved by the shell before the word is used,
/// so `$'\x2f'` is a `/` and must not be read as three harmless characters.
fn decode_ansi(s : String) -> String {
  let sb = StringBuilder()
  let n = s.length()
  let mut i = 0
  for ;; {
    if i >= n {
      break
    }
    let c = s.get_char(i).unwrap()
    if c != '\\' || i + 1 >= n {
      sb.write_char(c)
      i += 1
      continue
    }
    let d = s.get_char(i + 1).unwrap()
    match d {
      'n' => {
        sb.write_char('\n')
        i += 2
      }
      't' => {
        sb.write_char('\t')
        i += 2
      }
      'r' => {
        sb.write_char('\r')
        i += 2
      }
      'a' => {
        sb.write_char('\u{07}')
        i += 2
      }
      'b' => {
        sb.write_char('\u{08}')
        i += 2
      }
      'f' => {
        sb.write_char('\u{0c}')
        i += 2
      }
      'v' => {
        sb.write_char('\u{0b}')
        i += 2
      }
      'e' | 'E' => {
        sb.write_char('\u{1b}')
        i += 2
      }
      '\\' | '\'' | '"' | '?' => {
        sb.write_char(d)
        i += 2
      }
      'x' => {
        let (v, used) = read_hex(s, i + 2, 2)
        sb.write_char(v.unsafe_to_char())
        i += used
      }
      'u' => {
        let (v, used) = read_hex(s, i + 2, 4)
        sb.write_char(v.unsafe_to_char())
        i += used
      }
      _ =>
        if d.is_ascii_digit() {
          let (v, used) = read_octal(s, i + 1)
          sb.write_char(v.unsafe_to_char())
          i += used
        } else {
          sb.write_char('\\')
          i += 1
        }
    }
  }
  sb.to_string()
}

///|
fn read_hex(s : String, start : Int, max : Int) -> (Int, Int) {
  let mut v = 0
  let mut used = 0
  for ;; {
    if used >= max {
      break
    }
    let c = match s.get_char(start + used) {
      None => break
      Some(c) => c
    }
    if !c.is_ascii_hexdigit() {
      break
    }
    v = v * 16 + hex_value(c)
    used += 1
  }
  if used == 0 {
    (0, 1)
  } else {
    (v, used + 2)
  }
}

///|
fn hex_value(c : Char) -> Int {
  if c.is_ascii_digit() {
    c.to_int() - '0'.to_int()
  } else {
    c.to_ascii_lowercase().to_int() - 'a'.to_int() + 10
  }
}

///|
fn read_octal(s : String, start : Int) -> (Int, Int) {
  let mut v = 0
  let mut used = 0
  for ;; {
    if used >= 3 {
      break
    }
    let c = match s.get_char(start + used) {
      None => break
      Some(c) => c
    }
    if !c.is_ascii_octdigit() {
      break
    }
    v = v * 8 + (c.to_int() - '0'.to_int())
    used += 1
  }
  if used == 0 {
    (0, 1)
  } else {
    (v, used + 1)
  }
}
