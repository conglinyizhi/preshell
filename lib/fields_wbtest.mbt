///|
/// Word splitting, checked at the function: the rules are what the manual calls
/// "Word Splitting" and subst.c's `list_string`, and each row here was measured
/// against bash 5.3 with `printf '<%s>'`.
///
/// `|` marks a field boundary in the expectation, so `""` is no field at all and
/// `"|"` is two empty ones.
test "fields: how a value splits" {
  // Runs of IFS whitespace delimit, and whitespace at either end is padding.
  inspect(split_fields("a b", default_ifs()).join("|"), content="a|b")
  inspect(split_fields(" a ", default_ifs()).join("|"), content="a")
  inspect(split_fields("  a  b  ", default_ifs()).join("|"), content="a|b")
  inspect(split_fields("a\tb", default_ifs()).join("|"), content="a|b")
  inspect(split_fields("a\nb", default_ifs()).join("|"), content="a|b")
  inspect(split_fields("", default_ifs()).join("|"), content="")
  inspect(split_fields("   ", default_ifs()).join("|"), content="")
  // A non-whitespace separator delimits on its own and takes the whitespace
  // beside it with it.
  inspect(split_fields("a:b", ":").join("|"), content="a|b")
  inspect(split_fields("a: b", ":").join("|"), content="a| b")
  inspect(split_fields("a: b", " :").join("|"), content="a|b")
  inspect(split_fields("a::b", ":").join("|"), content="a||b")
  // At the front it makes an empty field, at the back it does not.
  inspect(split_fields(":a", ":").join("|"), content="|a")
  inspect(split_fields("a:", ":").join("|"), content="a")
  inspect(split_fields("::", ":").join("|"), content="|")
  // An empty IFS turns splitting off.
  inspect(split_fields("a b", "").join("|"), content="a b")
  inspect(split_fields("", "").join("|"), content="")
}
