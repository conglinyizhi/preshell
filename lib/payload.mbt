///|
/// The text a program reads as its own source, when the command line carries it.
///
/// A fact about the command line, the same class as `target` and `origin`: the
/// parser already knows that this word is `python3` and that the word after `-c`
/// is what it will read as its program. Nothing here is interpreted — looking
/// for paths inside the text is the caller's job — and it says nothing about
/// what the text does.
///
/// Off by default, because a here-document body can be kilobytes and a report
/// that grows without being asked is one a caller cannot budget for.
/// `--payload` turns it on; `--payload-max=N` sets how much of the text comes
/// back.
pub(all) struct Payload {
  /// Where the text came from. `flag` — an option's value (`python3 -c '…'`);
  /// `heredoc` — a here-document body (`python3 - <<'PY' … PY`). A pipe is not
  /// a source: the text of `cat f | python3` is not in this command line at
  /// all, and an empty payload would be worse than none.
  source : String
  /// The option the text was handed to. Present when `source` is `flag`.
  flag : String?
  /// The word that ends the here-document. Present when `source` is `heredoc`.
  delimiter : String?
  /// The text as it stands, with quotes and escapes resolved and expansions
  /// left alone: a `$x` inside stays `$x`, because the shell has not expanded
  /// it yet and this tool does not guess a value it cannot see.
  text : String
  /// The whole text in UTF-8 bytes, including whatever `text` left out.
  bytes : Int
  /// True when `text` holds only the first `--payload-max` bytes.
  truncated : Bool
} derive(Debug, Eq, ToJson)

///|
/// Interpreters that read their source from the command line, and the options
/// that hand it over.
///
/// A name in this table is a claim about the program, so it stays short: only
/// the cases where "this option carries its source" is not in question. `awk`
/// and `sed` are absent on purpose — what they take is a small language of
/// their own rather than the program's source, and the option that names a file
/// carries no text.
fn payload_source_flags(program : String) -> Array[String] {
  match payload_stem(program) {
    "python" | "pypy" => ["-c"]
    "sh" | "bash" | "zsh" | "dash" | "ksh" | "ash" => ["-c"]
    "node" | "nodejs" => ["-e", "--eval", "-p", "--print"]
    "perl" => ["-e", "-E"]
    "ruby" => ["-e"]
    "php" => ["-r"]
    "lua" => ["-e"]
    _ => []
  }
}

///|
/// The interpreter a program name names: `/usr/bin/python3.12` is `python`.
///
/// A suffix is dropped only when what is left is a stem this file knows and the
/// suffix is digits and dots, so `python3.12` and `php8` are read as their
/// stems while `nodejs` and `shfoo` are not. An unknown program never becomes a
/// known one by accident.
fn payload_stem(program : String) -> String {
  // A container image names its program the same way: `node:20-alpine` and
  // `ghcr.io/x/node` both start a node. No interpreter name contains a colon,
  // so cutting at the first one cannot lose a real name.
  let named = match program.find(":") {
    Some(i) => program.unsafe_substring(start=0, end=i)
    None => program
  }
  let base = basename(named)
  for stem in payload_stems() {
    if base == stem {
      return stem
    }
    if base.has_prefix(stem) {
      let rest = base.unsafe_substring(start=stem.length(), end=base.length())
      if rest.length() > 0 && is_version_suffix(rest) {
        return stem
      }
    }
  }
  base
}

///|
/// The stems `payload_stem` may recognise. None is a prefix of another except
/// `sh`, so the order only matters for the exact match that comes first.
fn payload_stems() -> Array[String] {
  [
    "python", "pypy", "node", "nodejs", "perl", "ruby", "php", "lua", "sh", "bash",
    "zsh", "dash", "ksh", "ash",
  ]
}

///|
/// `3`, `.12`, `2.7`: digits and dots with at least one digit. `js` is not one,
/// which is what keeps `nodejs` from being read as `node` plus a suffix.
fn is_version_suffix(s : String) -> Bool {
  let mut digits = 0
  for c in s {
    if c.is_ascii_digit() {
      digits += 1
    } else if c != '.' {
      return false
    }
  }
  digits > 0
}

///|
/// The payload of a command whose program is `program`, with `args` the words
/// after it and `redirects` the command's own redirections.
///
/// None when the program is not one of the interpreters this file knows, or
/// when the command line does not carry its source.
fn payload_of(
  program : String,
  args : ArrayView[Word],
  redirects : ArrayView[Redirect],
  max : Int,
) -> Payload? {
  let flags = payload_source_flags(program)
  if flags.length() == 0 {
    return None
  }
  // An option that carries the source wins over a here-document: `python3 -c
  // 'x' <<EOT` reads its program from -c, and the body arrives as data on
  // stdin. The option is matched as a whole word, so `--eval` is not found
  // inside `--evaluate`.
  for i, w in args {
    let t = w.literal_text()
    for f in flags {
      if t == f {
        if i + 1 < args.length() {
          return Some(payload_flag(f, args[i + 1].literal_text(), max))
        }
        // `python3 -c` with nothing after it: there is no text to report.
        return None
      }
      // The glued long form: `node --eval=…` is one word, not two.
      if f.has_prefix("--") && t.has_prefix(f + "=") {
        return Some(
          payload_flag(
            f,
            t.unsafe_substring(start=f.length() + 1, end=t.length()),
            max,
          ),
        )
      }
    }
  }
  for r in redirects {
    match r.op {
      RHereDoc | RHereDocStrip =>
        match r.body {
          Some(body) =>
            return Some(payload_heredoc(r.target.literal_text(), body, max))
          None => ()
        }
      _ => ()
    }
  }
  None
}

///|

///|
/// A payload whose text came from an option.
fn payload_flag(flag : String, text : String, max : Int) -> Payload {
  payload_make("flag", Some(flag), None, text, max)
}

///|
/// A payload whose text came from a here-document body.
fn payload_heredoc(delimiter : String, text : String, max : Int) -> Payload {
  payload_make("heredoc", None, Some(delimiter), text, max)
}

///|
fn payload_make(
  source : String,
  flag : String?,
  delimiter : String?,
  text : String,
  max : Int,
) -> Payload {
  let full = @utf8.encode(text)
  if full.length() <= max {
    { source, flag, delimiter, text, bytes: full.length(), truncated: false, }
  } else {
    {
      source,
      flag,
      delimiter,
      text: utf8_prefix(text, max),
      bytes: full.length(),
      truncated: true,
    }
  }
}

///|
/// The payload, only when the caller asked for one. Attaching it by default
/// would make every report's size depend on text most callers never read.
fn Collector::payload_for(
  self : Collector,
  program : String,
  args : ArrayView[Word],
  redirects : ArrayView[Redirect],
) -> Payload? {
  match self.payload_max {
    None => None
    Some(max) => payload_of(program, args, redirects, max)
  }
}
