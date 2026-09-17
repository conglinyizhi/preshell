///|
/// Whitebox checks on the evidence table itself. These need private access, so
/// they live here rather than in the blackbox test files.
test "the corroborated table never contains a message from both quadrants" {
  // unterminated here-document 曾同时出现在「两边都报错」和「我们的缺口」
  // 两格，所以它不能进表；这条报错随 here-doc 到 EOF 的修正已经消失。
  debug_inspect(
    corroborated_syntax_messages().contains("unterminated here-document"),
    content="false",
  )
  // 目前唯一在表里的原文。
  debug_inspect(
    corroborated_syntax_messages().contains("unterminated ${"),
    content="true",
  )
}

///|
test "the table is the only path to a Syntax issue" {
  debug_inspect(classify_error("unterminated ${").kind, content="Syntax")
  debug_inspect(
    classify_error("something nobody has evidence for").kind,
    content="Gap",
  )
}
