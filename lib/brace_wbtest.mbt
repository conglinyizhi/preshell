///|
/// The words a range spells, or `literal` when it is not one.
fn range_of(spec : String, dialect : Dialect) -> String {
  match range_words(spec, dialect) {
    NotRange => "literal"
    TooMany => "too many"
    Words(words) => words.join(" ")
  }
}

///|
fn range_nth(spec : String, dialect : Dialect, n : Int) -> String {
  match range_words(spec, dialect) {
    NotRange => "literal"
    TooMany => "too many"
    Words(words) =>
      match words.get(n) {
        Some(w) => w
        None => "out of range"
      }
  }
}

///|
/// What a word's braces do, as one line: `plain` for no expansion, `hole` for an
/// expansion this tool refuses to spell out, and the words joined by `|`.
fn brace_of(text : String, dialect : Dialect) -> String {
  let w : Word = { parts: [Lit(text)], raw: text, line: 1, origin: None, }
  match w.braces(dialect) {
    Plain => "plain"
    Unmodelled => "hole"
    Words(lists) => lists.map(fn(parts) { parts_text(parts) }).join("|")
  }
}

///|
/// How a range counts, checked at the function rather than through a command
/// line: a word that starts with `-` is an option to the command models, so
/// `rm -rf {-2..2}` cannot show what the range itself produced.
///
/// Every expectation here was measured against bash 5.3 and zsh 5.9.2.
test "brace: what counts as a range" {
  inspect(range_of("-2..2", Bash), content="-2 -1 0 1 2")
  // The width counts the sign: bash writes `-02`, not `-2`.
  inspect(range_of("-02..02", Bash), content="-02 -01 000 001 002")
  inspect(range_of("1..03", Bash), content="01 02 03")
  inspect(range_of("08..10", Bash), content="08 09 10")
  inspect(range_of("10..1..3", Bash), content="10 7 4 1")
  inspect(range_of("5..1..2", Bash), content="5 3 1")
  inspect(range_of("1..1", Bash), content="1")
  // A step of zero counts by one in bash and is refused in zsh.
  inspect(range_of("1..3..0", Bash), content="1 2 3")
  inspect(range_of("1..3..0", Zsh), content="literal")
  // Two letters are a range; a letter and a digit are not (bash).
  inspect(range_of("a..c", Bash), content="a b c")
  inspect(range_of("1..a", Bash), content="literal")
  inspect(range_of("aa..ac", Bash), content="literal")
  inspect(range_of("a..f..3", Bash), content="a d")
  // zsh takes any two single characters and walks the ASCII table from `1` to
  // `a`, but refuses a step on a character range.
  inspect(range_of("1..a", Zsh).split(" ").to_array().length(), content="49")
  inspect(range_nth("1..a", Zsh, 0), content="1")
  inspect(range_nth("1..a", Zsh, 40), content="Y")
  inspect(range_nth("1..a", Zsh, 48), content="a")
  inspect(range_of("a..z..2", Zsh), content="literal")
  // Content that is not two plain pieces is not a range in either shell.
  inspect(range_of("1..3..x", Bash), content="literal")
  inspect(range_of("1..3..2..4", Bash), content="literal")
  inspect(range_of("..", Bash), content="literal")
}

///|
/// The list form, and what it does with an empty piece. Both shells drop the
/// empty *word* before a command sees it, so it is not the tool's business here;
/// what matters is which words come out, in which order.
test "brace: the list form" {
  inspect(brace_of("a{b,c}d", Bash), content="abd|acd")
  inspect(brace_of("{a,b}{1..2}", Bash), content="a1|a2|b1|b2")
  inspect(brace_of("{a,b}c{d,e}", Bash), content="acd|ace|bcd|bce")
  inspect(brace_of("{a,{b,c}}", Bash), content="a|b|c")
  // A brace with no comma and no range is literal, and the search moves on.
  inspect(brace_of("{a}{b,c}", Bash), content="{a}b|{a}c")
  inspect(brace_of("{a,b}{c}", Bash), content="a{c}|b{c}")
  inspect(brace_of("{{a,b}}", Bash), content="{a}|{b}")
  inspect(brace_of("{a}", Bash), content="plain")
  inspect(brace_of("{a,b", Bash), content="plain")
  inspect(brace_of("a}b{c", Bash), content="plain")
  inspect(brace_of("x{,y}z", Bash), content="xz|xyz")
  // An alternative that comes out empty names no path and is left out.
  inspect(brace_of("{a,}", Bash), content="a")
  inspect(brace_of("{,a}", Bash), content="a")
  inspect(brace_of("{a,,b}", Bash), content="a|b")
  inspect(brace_of("{,}", Bash), content="")
  // A comma wins over a range: measured, `{a..b,c}` is `a..b` and `c`.
  inspect(brace_of("{a..b,c}", Bash), content="a..b|c")
}

///|
/// Which of the three outcomes a word's braces land on.
fn brace_kind(w : Word, dialect : Dialect) -> String {
  match w.braces(dialect) {
    Plain => "plain"
    Unmodelled => "hole"
    Words(_) => "words"
  }
}

///|
/// What a word refuses to expand.
test "brace: what is left alone" {
  // Escaped braces are one file with braces in its name, and by the time a word
  // is in parts the escape is gone, so the raw text decides.
  let escaped : Word = {
    parts: [Lit("{a,b}")],
    raw: "\\{a,b\\}",
    line: 1,
    origin: None,
  }
  inspect(brace_kind(escaped, Bash), content="plain")
  // A brace glued to a parameter belongs to the expansion of that name
  // (`$x{a,b}` is `$xa` and `$xb` in bash), which this tool does not model.
  let glued : Word = {
    parts: [Param("x"), Lit("{a,b}")],
    raw: "$x{a,b}",
    line: 1,
    origin: None,
  }
  inspect(brace_kind(glued, Bash), content="plain")
  // A list longer than the report can carry becomes a hole, not a word list and
  // not the literal text either.
  inspect(brace_of("{1..1000}", Bash), content="hole")
  inspect(
    brace_of("{1..100}", Bash).split("|").to_array().length(),
    content="100",
  )
}
