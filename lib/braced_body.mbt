///|
/// The body of a `${...}` expansion, read as the small language zsh makes of it.
///
/// zsh gives the body a grammar and bash does not: measured on zsh 5.9.2 and
/// bash 5.3, every shape this file rejects is accepted by bash, which is why the
/// caller only asks in the zsh dialect. The body reads as
///
///   ${ [flags] [#|##] name [subscript]... [modifier tail] }
///
/// and a scan that cannot get past something reports the body as malformed.
/// The modifier tail is only checked for balance, because it is ordinary text:
/// `${a:-hello world}` and `${a#* }` are legal, `${a:-b{c}}` needs its braces
/// paired, and `${a:-b{c}` is refused. Anything this cannot read is left alone —
/// reporting a valid expansion as broken is worse than missing one — so the
/// direction of the errors is deliberately narrow.

///|
/// Whether the body of a `${...}` is one zsh would refuse. `body` is what sat
/// between the braces, with the braces themselves already consumed, and
/// `in_dquote` says whether the expansion sat inside a `"..."`.
fn braced_body_is_malformed(body : String, in_dquote : Bool) -> Bool {
  if braced_body_is_hard(body) {
    return false
  }
  let n = body.length()
  let mut i = 0
  // `${(f)a}`: the flags are a parenthesised list, and leaving it unclosed is
  // the `${(}` zsh refuses.
  if i < n && body.get_char(i) == Some('(') {
    match match_brace_pair(body, i, '(', ')') {
      None => return true
      Some(j) => i = j + 1
    }
  }
  // `${#a}` counts characters and `${##a}` is zsh's own flag for it; both sit
  // before the name.
  while i < n && body.get_char(i) == Some('#') {
    i += 1
  }
  // A substitution may stand where the name goes, and zsh lets the `~` `=` `^`
  // prefixes sit in front of either: `${$(dosdir)[1,-5]:l}`, `${${tmp%:*}//_/-}`
  // and `${(e)~linedir}` are all real lines from the completion corpus.
  let mut prefixed = true
  while prefixed && i < n {
    prefixed = false
    match body.get_char(i) {
      Some('~') | Some('=') | Some('^') => {
        i += 1
        prefixed = true
      }
      Some('$') =>
        match body.get_char(i + 1) {
          Some('(') =>
            match match_brace_pair(body, i + 1, '(', ')') {
              None => return true
              Some(j) => {
                i = j + 1
                prefixed = true
              }
            }
          Some('{') =>
            match match_brace_pair(body, i + 1, '{', '}') {
              None => return true
              Some(j) => {
                i = j + 1
                prefixed = true
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  if i < n {
    let c = body.get_char(i).unwrap()
    if is_name_start(c) {
      while i < n && is_name_char(body.get_char(i).unwrap()) {
        i += 1
      }
    } else if c.is_ascii_digit() {
      // `$1` is one parameter, so a digit run is one name; `${1a}` is the shape
      // zsh refuses.
      while i < n && body.get_char(i).unwrap().is_ascii_digit() {
        i += 1
      }
    } else if is_single_char_param(c) {
      // `$@`, `$*`, `$#`, `$?`, `$-`, `$$`, `$!` are one character each and are
      // not followed by a name: `${@x}` is refused.
      i += 1
    }
  }
  while i < n {
    let c = body.get_char(i).unwrap()
    if c == '[' {
      match match_brace_pair(body, i, '[', ']') {
        None => return true
        Some(j) => {
          i = j + 1
          continue
        }
      }
    }
    if is_modifier_start(c) {
      return !modifier_tail_is_balanced(body, i, in_dquote)
    }
    // A `"` opens a nested quoted string, which zsh allows right after a name
    // (measured, `${a"b\"c"}` runs in both shells and in both quotings). A
    // `'` is the same thing only inside a double-quoted expansion, where it is
    // text: `"${a'b}"` runs while the unquoted `${a'b}` is refused.
    if c == '"' || (c == '\'' && in_dquote) {
      return !modifier_tail_is_balanced(body, i, in_dquote)
    }
    // A blank, a stray `]`, an operator, or a letter after a single-character
    // parameter: this is where zsh stops and bash shrugs.
    return true
  }
  false
}

///|
/// Whether the body carries more of the expansion grammar than this file reads.
///
/// A nested substitution, a quote or an escape can hold braces, brackets and
/// parens that belong to something else: `${${(f)"$(cmd)"}#refs/tags/}` and
/// `${"${x}"[1]}` are both ordinary lines in the completion corpus, and telling
/// them apart needs the whole grammar rather than the shape of the body. Those
/// are left alone — measured, guessing at them cost 45 of the 1308 corpus files
/// — because refusing an expansion that runs is worse than missing one.
fn braced_body_is_hard(body : String) -> Bool {
  for _, c in body {
    match c {
      '$' | '"' | '\'' | '\\' | '{' | '}' => return true
      _ => ()
    }
  }
  false
}

///|
/// The parameters that are one character and are not followed by a name.
fn is_single_char_param(c : Char) -> Bool {
  match c {
    '@' | '*' | '#' | '?' | '-' | '$' | '!' => true
    _ => false
  }
}

///|
/// Whether a modifier starts here. Once one does, the rest is ordinary text and
/// its shape stops mattering — `${a:-hello world}` is legal — so this is only
/// asked at the point where a name or a subscript could have followed instead.
fn is_modifier_start(c : Char) -> Bool {
  match c {
    ':' | '-' | '=' | '+' | '?' | '#' | '%' | '/' | '^' | ',' => true
    _ => false
  }
}

///|
/// The index of the character closing the one at `start`, or None when the text
/// ends first. Only the nesting of that same pair is counted: an unmatched `[`
/// is what makes `${a[1}` malformed, while what sits inside the brackets is the
/// subscript's own business (`${a[b c]}`, `${a[$(echo 1)]}` and `${a["b"]}` are
/// all accepted).
fn match_brace_pair(s : String, start : Int, open : Char, close : Char) -> Int? {
  let n = s.length()
  let mut depth = 0
  let mut i = start
  while i < n {
    let c = s.get_char(i).unwrap()
    if c == open {
      depth += 1
    } else if c == close {
      depth -= 1
      if depth == 0 {
        return Some(i)
      }
    }
    i += 1
  }
  None
}

///|
/// Whether the text from a modifier to the end of the body is balanced.
///
/// Measured: `${a:-b{c}}` runs and `${a:-b{c}` does not, so braces are paired;
/// `"` holds what is inside it (`${a:-"}"}` runs) and a backslash escapes the
/// character after it (`${a:-b\}}` too). A nested `${...}` is scanned through
/// rather than counted as text.
/// `in_dquote` says whether the expansion sat inside a `"..."`. There the body
/// ends at the first `}`, so a `{` really is text whose partner lies outside:
/// measured, `"${a//b/X{Y}/Z}"` runs in zsh while the same text unquoted needs
/// the braces paired. Nothing is checked in that case, because the body the
/// scanner sees is only a prefix of the text zsh reads.
fn modifier_tail_is_balanced(s : String, start : Int, in_dquote : Bool) -> Bool {
  if in_dquote {
    return true
  }
  let n = s.length()
  let mut i = start
  let mut depth = 0
  while i < n {
    let c = s.get_char(i).unwrap()
    match c {
      '\\' => i += 2
      '\'' => {
        i += 1
        while i < n && s.get_char(i).unwrap() != '\'' {
          i += 1
        }
        i += 1
      }
      '"' => {
        i += 1
        while i < n && s.get_char(i).unwrap() != '"' {
          if s.get_char(i).unwrap() == '\\' {
            i += 1
          }
          i += 1
        }
        i += 1
      }
      '$' =>
        if i + 1 < n && s.get_char(i + 1) == Some('{') {
          match match_brace_pair(s, i + 1, '{', '}') {
            None => return false
            Some(j) => i = j + 1
          }
        } else {
          i += 1
        }
      '{' => {
        depth += 1
        i += 1
      }
      '}' => {
        if depth == 0 {
          return false
        }
        depth -= 1
        i += 1
      }
      _ => i += 1
    }
  }
  depth == 0
}
