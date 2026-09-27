///|
/// Text and byte helpers that more than one layer needs.
///
/// Everything here is a pure function of its arguments: a character class, a
/// byte decoder, a path segment. They live in one file because the parser, the
/// impact layer and the command line all reach for them, and the alternative —
/// a copy per layer — is how two call sites come to disagree about what a name
/// character is or how a path is split.

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

///|
/// The longest prefix of `s` that fits in `max` UTF-8 bytes.
///
/// The cut lands on a character boundary: a continuation byte (`10xxxxxx`) is
/// not a place to stop, or the prefix would be half a character and decoding it
/// would produce a replacement mark that is not in the input.
fn utf8_prefix(s : String, max : Int) -> String {
  let b = @utf8.encode(s)
  let mut end = if max > b.length() { b.length() } else { max }
  while end > 0 && (b[end].to_int() & 0xC0) == 0x80 {
    end -= 1
  }
  @utf8.decode_lossy(b[:end])
}

///|
/// Last path segment: `sub/a.txt` -> `a.txt`, `a.txt/` -> `a.txt`, `/` -> ``.
///
/// A trailing slash is trimmed first, so the answer is a name rather than an
/// empty string: callers use this to recognise a program (`/usr/bin/env` is
/// `env`) and a container image (`ghcr.io/x/node` is `node`), and an empty
/// answer would silently match nothing.
fn basename(p : String) -> String {
  let mut end = p.length()
  while end > 0 && p.unsafe_substring(start=end - 1, end~) == "/" {
    end -= 1
  }
  let trimmed = p.unsafe_substring(start=0, end~)
  match trimmed.rev_find("/") {
    Some(i) => trimmed.unsafe_substring(start=i + 1, end=trimmed.length())
    None => trimmed
  }
}

///|
/// Whether every character is a digit. An empty string is not a number.
fn all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if !c.is_ascii_digit() {
      return false
    }
  }
  true
}

///|
/// Space, tab and carriage return: the characters that end a token inside the
/// grammar.
///
/// A newline is deliberately not one of them — the lexer has its own handling
/// for it, and hiding that here would change how a line break is reported. The
/// splitting rule in fields.mbt wants the other set; see `is_ifs_blank`.
fn is_blank(c : Char) -> Bool {
  match c {
    ' ' | '\t' | '\r' => true
    _ => false
  }
}

///|
/// Whether a character is one this shell treats as IFS whitespace rather than as
/// a separator in its own right: space, tab and newline.
fn is_ifs_blank(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n'
}
