// Brace expansion: bash's braces.c, and zsh's own pass over the same shapes.
//
// It is a purely textual expansion that runs *before* parameter expansion, which
// is why the two cases differ: `rm -rf {a,b}` names two files, while
// `x='{a,b}'; rm $x` names one file whose name has braces in it. So this runs
// before the values from bind.mbt go in, not after.
//
// Everything here was measured against bash 5.3 and zsh 5.9.2. Where the two
// disagree the code says so; the shape of the disagreement is always the same —
// bash is stricter about what counts as a range, zsh is looser but refuses steps
// on character ranges.

///|
/// One position in a word: a literal character takes part in the brace search,
/// everything else is opaque. Braces are only ever spelled in literal text (the
/// lexer keeps `*` in a Glob part and `${x}` in a Param part), so this split is
/// what keeps a `,` inside those out of the search.
priv enum BAtom {
  Ch(Char)
  Op(WordPart)
}

///|
/// What the braces in a word amount to.
priv enum Brace {
  /// No expansion: the word is what it says.
  Plain
  /// The words it expands to, as part lists.
  Words(Array[Array[WordPart]])
  /// An expansion this tool does not model. The word is not what it says, so the
  /// caller gets a hole rather than an invented path.
  Unmodelled
}

///|
/// What an `X..Y` specification turns out to be.
priv enum Range {
  /// Not a range: the braces stay as written.
  NotRange
  /// The words it spells.
  Words(Array[String])
  /// A range with more words than the report carries. Spelling it out would
  /// fill the effect list with copies of one command line.
  TooMany
}

///|
/// The alternatives a single brace can offer.
priv enum Alts {
  /// Not a brace expansion: the braces stay as written.
  Literal
  Alts(Array[Array[BAtom]])
  /// An expansion this tool refuses to spell out (too many words).
  Overflow
}

///|
/// How many words one word may expand to. `{1..1000}` is a real command line, but
/// a thousand paths is not an answer a caller can use, and the cut has to be
/// visible rather than silent.
fn max_brace_words() -> Int {
  256
}

///|
/// Nesting depth this tool follows. `{a,{a,{a,...}}}` is depth for free in a
/// 3-character-per-level input.
fn max_brace_depth() -> Int {
  16
}

///|
priv struct BraceRun {
  dialect : Dialect
  mut left : Int
  mut overflow : Bool
}

///|
fn brace_atoms(parts : Array[WordPart]) -> Array[BAtom] {
  let out : Array[BAtom] = []
  for p in parts {
    match p {
      Lit(s) =>
        for c in s {
          out.push(Ch(c))
        }
      _ => out.push(Op(p))
    }
  }
  out
}

///|
fn brace_parts(atoms : Array[BAtom]) -> Array[WordPart] {
  let out : Array[WordPart] = []
  let mut lit = StringBuilder()
  for a in atoms {
    match a {
      Ch(c) => lit.write_char(c)
      Op(p) => {
        if !lit.is_empty() {
          out.push(Lit(lit.to_string()))
          lit = StringBuilder()
        }
        out.push(p)
      }
    }
  }
  if !lit.is_empty() {
    out.push(Lit(lit.to_string()))
  }
  out
}

///|
/// The content as plain text, or None when a part in it is a hole. A range needs
/// plain text: `{$x..3}` is not a range in either shell.
fn atoms_text(atoms : Array[BAtom]) -> String? {
  let sb = StringBuilder()
  for a in atoms {
    match a {
      Ch(c) => sb.write_char(c)
      Op(_) => return None
    }
  }
  Some(sb.to_string())
}

///|
/// The index of the `}` that closes the `{` at `start`, or None when it is never
/// closed (`{a,b` stays as written).
fn brace_match(atoms : Array[BAtom], start : Int) -> Int? {
  let mut depth = 0
  let mut k = start
  while k < atoms.length() {
    match atoms[k] {
      Ch('{') => depth += 1
      Ch('}') => {
        depth -= 1
        if depth == 0 {
          return Some(k)
        }
      }
      _ => ()
    }
    k += 1
  }
  None
}

///|
/// Split at the commas that are not inside a nested brace, or None when there is
/// no comma at the top level. An empty piece is kept: `x{,y}z` expands to `xz`
/// and `xyz`, and whether an empty *word* survives is decided later.
fn split_commas(atoms : Array[BAtom]) -> Array[Array[BAtom]]? {
  let pieces : Array[Array[BAtom]] = []
  let mut cur : Array[BAtom] = []
  let mut depth = 0
  let mut seen = false
  for a in atoms {
    match a {
      Ch('{') => {
        depth += 1
        cur.push(a)
      }
      Ch('}') => {
        depth -= 1
        cur.push(a)
      }
      Ch(',') =>
        if depth == 0 {
          seen = true
          pieces.push(cur)
          cur = []
        } else {
          cur.push(a)
        }
      _ => cur.push(a)
    }
  }
  if !seen {
    return None
  }
  pieces.push(cur)
  Some(pieces)
}

///|
/// Split `text` at every `..`, as plain strings. The pieces keep their order and
/// their emptiness, because `{1..}` and `{..3}` are told apart by it.
fn split_dots(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut rest = text
  for ;; {
    match rest.find("..") {
      Some(i) => {
        out.push(rest[:i].to_owned())
        rest = rest[i + 2:].to_owned()
      }
      None => {
        out.push(rest)
        break
      }
    }
  }
  out
}

///|
fn parse_int(text : String) -> Int? {
  let mut v = 0
  let mut digits = 0
  let mut neg = false
  let mut first = true
  for c in text {
    if first {
      first = false
      if c == '+' {
        continue
      }
      if c == '-' {
        neg = true
        continue
      }
    }
    if !c.is_ascii_digit() {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
    digits += 1
  }
  if digits == 0 {
    return None
  }
  Some(if neg { -v } else { v })
}

///|
/// Whether the text is a number written with a leading zero, which is what makes
/// a range pad with zeros (`{1..03}` is `01 02 03`).
fn padded_number(text : String) -> Bool {
  let mut count = 0
  let mut zero_first = false
  for c in text {
    if count == 0 && (c == '-' || c == '+') {
      continue
    }
    if count == 0 && c == '0' {
      zero_first = true
    }
    count += 1
  }
  zero_first && count > 1
}

///|
/// The number written as bash writes it inside a padded range. The width includes
/// the sign, which is what makes `{-02..02}` three characters wide: `-02`, `-01`,
/// `000`, `001`, `002` (measured).
fn pad_number(value : Int, width : Int) -> String {
  let digits = if value < 0 { (-value).to_string() } else { value.to_string() }
  let body = if value < 0 { width - 1 } else { width }
  let zeros = if digits.length() >= body { 0 } else { body - digits.length() }
  let sb = StringBuilder()
  if value < 0 {
    sb.write_char('-')
  }
  for _ in 0..<zeros {
    sb.write_char('0')
  }
  sb.write_string(digits)
  sb.to_string()
}

///|
/// The words `X..Y[..Z]` spells, or None when this is not a range.
///
/// Measured, bash: counting works either way (`{3..1}`), a leading zero pads the
/// whole number including its sign (`{-02..02}` is `-02 -01 000 001 002`), a step
/// of zero counts by one, and a range needs two numbers or two single letters —
/// `{1..a}` stays literal while `{a..A}` is a character range. zsh counts any two
/// single characters (`{1..a}` walks the ASCII table) but refuses a step on a
/// character range and refuses a zero step.
fn range_words(spec : String, dialect : Dialect) -> Range {
  let pieces = split_dots(spec)
  if pieces.length() < 2 || pieces.length() > 3 {
    return NotRange
  }
  let mut step = 1
  if pieces.length() == 3 {
    match parse_int(pieces[2]) {
      Some(v) => step = v
      None => return NotRange
    }
    if step == 0 {
      if dialect is Zsh {
        return NotRange
      }
      step = 1
    }
    if step < 0 {
      step = -step
    }
  }
  let lo = pieces[0]
  let hi = pieces[1]
  let (low, high) = match (parse_int(lo), parse_int(hi)) {
    (Some(a), Some(b)) => (a, b)
    _ => {
      // A character range: both sides a single character. bash wants both of
      // them letters, zsh takes anything.
      let single = lo.length() == 1 && hi.length() == 1
      if !single {
        return NotRange
      }
      // Read the two characters by iterating: a one-character word has exactly
      // one code unit, and indexing gives that code unit rather than a `Char`.
      let mut a = ' '
      let mut b = ' '
      for c in lo {
        a = c
      }
      for c in hi {
        b = c
      }
      let letters = is_alpha(a) && is_alpha(b)
      let allowed = if dialect is Zsh { pieces.length() == 2 } else { letters }
      if !allowed {
        return NotRange
      }
      return Words(char_range(a, b, step))
    }
  }
  let width = if padded_number(lo) || padded_number(hi) {
    let w = if lo.length() > hi.length() { lo.length() } else { hi.length() }
    // The sign is part of the width, which is what bash's own formatting does:
    // `{-02..02}` is three characters wide including the `-`.
    w
  } else {
    0
  }
  let count = if low <= high {
    (high - low) / step + 1
  } else {
    (low - high) / step + 1
  }
  if count > max_brace_words() {
    return TooMany
  }
  let out : Array[String] = []
  let mut v = low
  let mut n = 0
  while n < count {
    out.push(if width > 0 { pad_number(v, width) } else { v.to_string() })
    v = if low <= high { v + step } else { v - step }
    n += 1
  }
  Words(out)
}

///|
fn is_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn char_range(a : Char, b : Char, step : Int) -> Array[String] {
  let low = a.to_int()
  let high = b.to_int()
  let out : Array[String] = []
  let mut v = low
  while (if low <= high { v <= high } else { v >= high }) {
    let sb = StringBuilder()
    sb.write_char(v.unsafe_to_char())
    out.push(sb.to_string())
    v = if low <= high { v + step } else { v - step }
  }
  out
}

///|
/// The alternatives the braces around `content` offer.
fn brace_alternatives(content : Array[BAtom], run : BraceRun) -> Alts {
  // A top-level comma wins over a range: measured, `{a..b,c}` is `a..b` and `c`.
  match split_commas(content) {
    Some(pieces) => return Alts(pieces)
    None => ()
  }
  let spec = match atoms_text(content) {
    Some(s) => s
    None => return Literal
  }
  match range_words(spec, run.dialect) {
    NotRange => Literal
    TooMany => Overflow
    Words(words) => {
      if words.length() > run.left {
        return Overflow
      }
      let out : Array[Array[BAtom]] = []
      for w in words {
        let alt : Array[BAtom] = []
        for c in w {
          alt.push(Ch(c))
        }
        out.push(alt)
      }
      Alts(out)
    }
  }
}

///|
/// Every way the word's braces can come out.
///
/// The first brace that really expands is replaced by each of its alternatives in
/// turn, and the result is expanded again, which is what makes `{a,b}{1..2}` four
/// words in that order and `{a}{b,c}` two words with the literal `{a}` kept.
fn brace_level(
  atoms : Array[BAtom],
  run : BraceRun,
  depth : Int,
) -> Array[Array[BAtom]] {
  if depth > max_brace_depth() || run.overflow {
    return [atoms]
  }
  let mut i = 0
  while i < atoms.length() {
    match atoms[i] {
      Ch('{') =>
        match brace_match(atoms, i) {
          Some(j) => {
            let content = atoms[i + 1:j].to_owned()
            match brace_alternatives(content, run) {
              Literal => i += 1
              Overflow => {
                run.overflow = true
                return [atoms]
              }
              Alts(alts) => {
                let prefix = atoms[:i].to_owned()
                let suffix = atoms[j + 1:].to_owned()
                let out : Array[Array[BAtom]] = []
                for alt in alts {
                  let combined : Array[BAtom] = []
                  combined.append(prefix)
                  combined.append(alt)
                  combined.append(suffix)
                  for tail in brace_level(combined, run, depth + 1) {
                    run.left -= 1
                    if run.left < 0 {
                      run.overflow = true
                      return [atoms]
                    }
                    out.push(tail)
                  }
                }
                return out
              }
            }
          }
          None => i += 1
        }
      _ => i += 1
    }
  }
  [atoms]
}

///|
fn Word::braces(self : Word, dialect : Dialect) -> Brace {
  // An escape makes the brace literal, and by the time a word is in parts the
  // escape is gone, so the raw text is the only place that still knows:
  // `\{a,b\}` names one file whose name has braces in it.
  if self.raw.contains("\\") {
    return Plain
  }
  let atoms = brace_atoms(self.parts)
  // A brace glued to a parameter belongs to the expansion of its name: bash
  // splices the letters in, so `$x{a,b}` is `$xa` and `$xb`. This tool does not
  // model that gluing, and expanding here would spell it `${x}a`.
  for i, a in atoms {
    match a {
      Ch('{') =>
        if i > 0 {
          match atoms[i - 1] {
            Op(Param(_)) => return Plain
            _ => ()
          }
        }
      _ => ()
    }
  }
  let run : BraceRun = { dialect, left: max_brace_words(), overflow: false, }
  let alternatives = brace_level(atoms, run, 0)
  if run.overflow {
    return Unmodelled
  }
  // An alternative that comes out empty names no path. bash drops the empty word
  // before the command sees it and zsh keeps it as an empty argument, which names
  // nothing either way, so both are left out here.
  let out : Array[Array[WordPart]] = []
  for alt in alternatives {
    let parts = brace_parts(alt)
    if parts.length() > 0 {
      out.push(parts)
    }
  }
  if out.length() == 1 && brace_parts(alternatives[0]) == self.parts {
    return Plain
  }
  Words(out)
}

///|
/// The word that says "this is not what it looks like, and this tool cannot spell
/// out what it is". The text is kept and every literal piece becomes a glob, so
/// the caller still sees the word and still sees that its paths are not a closed
/// set.
fn Word::as_hole(self : Word) -> Word {
  let parts : Array[WordPart] = []
  for p in self.parts {
    match p {
      Lit(s) => if s.length() > 0 { parts.push(Glob(s)) }
      _ => parts.push(p)
    }
  }
  if parts.length() == 0 {
    parts.push(Glob(self.raw))
  }
  { parts, raw: self.raw, line: self.line, origin: self.origin, }
}

///|
/// The command with its braces expanded. The words are spliced into the argument
/// list where bash puts them, so `rm -rf {a,b}` reads as `rm -rf a b`, and
/// `{echo,true} hi` is `echo` with two arguments rather than two commands
/// (measured). Redirect targets are words too, and `> {a,b}` opens both files.
fn Collector::brace_simple(self : Collector, s : SimpleCmd) -> SimpleCmd {
  let words : Array[Word] = []
  for w in s.words {
    for e in w.brace_words(self.dialect) {
      words.push(e)
    }
  }
  let redirects : Array[Redirect] = []
  for r in s.redirects {
    for t in r.target.brace_words(self.dialect) {
      redirects.push({ fd: r.fd, op: r.op, target: t, body: r.body, })
    }
  }
  { assigns: s.assigns, words, redirects, }
}

///|
/// The words this one expands to. `rm -rf {a,b}` is `rm -rf a b`: the words are
/// spliced into the command's argument list in place, exactly where bash puts
/// them, so `{echo,true} hi` runs `echo` with two arguments rather than two
/// commands (measured).
fn Word::brace_words(self : Word, dialect : Dialect) -> Array[Word] {
  match self.braces(dialect) {
    Plain => [self]
    Unmodelled => [self.as_hole()]
    Words(lists) => {
      let out : Array[Word] = []
      for parts in lists {
        out.push({
          parts,
          raw: parts_text(parts),
          line: self.line,
          origin: None,
        })
      }
      out
    }
  }
}
