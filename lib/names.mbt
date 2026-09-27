///|
/// What counts as a shell name.
///
/// Three layers ask this question — the lexer while it reads a word, the parser
/// while it decides whether a word is an assignment, and the impact layer while
/// it reads a program's own options. They used to answer it three times, and an
/// answer that drifts is a disagreement about what a command means rather than
/// a style question, so it is answered once here.

///|
fn is_name_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c == '_'
}

///|
fn is_name_char(c : Char) -> Bool {
  is_name_start(c) || c.is_ascii_digit()
}

///|
/// Whether the whole string is one shell name: a letter or `_` first, then
/// letters, digits and `_`. Empty is not a name.
fn is_valid_name(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i, c in s {
    if i == 0 {
      if !is_name_start(c) {
        return false
      }
    } else if !is_name_char(c) {
      return false
    }
  }
  true
}
