///|
/// 警告码表本身也要被钉住：`--help-id` 的可信度取决于这张表是否完整。
fn warn_field_nonempty(code : @lib.WarnCode) -> Bool {
  code.code() != "" &&
  code.slug() != "" &&
  code.message() != "" &&
  code.meaning() != "" &&
  code.remedy() != ""
}

///|
test "every registered code is documented" {
  for code in @lib.all_warn_codes() {
    if !warn_field_nonempty(code) {
      fail(
        "\{code.code()}: 有字段是空的，--help-id 会问出半条信息",
      )
    }
  }
}

///|
test "codes round-trip through their text form" {
  for code in @lib.all_warn_codes() {
    // Debug 渲染出来的变体名就是码本身，所以期望值可以直接拼。
    debug_inspect(
      @lib.parse_warn_code(code.code()),
      content="Some(" + code.code() + ")",
    )
  }
}

///|
test "an unknown code is not guessed" {
  debug_inspect(@lib.parse_warn_code("W99"), content="None")
  debug_inspect(@lib.parse_warn_code(""), content="None")
  debug_inspect(@lib.parse_warn_code("w1"), content="None")
}

///|
test "codes and slugs are unique" {
  let codes : Array[String] = []
  let slugs : Array[String] = []
  for code in @lib.all_warn_codes() {
    if codes.contains(code.code()) {
      fail("重复的码：\{code.code()}")
    }
    if slugs.contains(code.slug()) {
      fail("重复的 slug：\{code.slug()}")
    }
    codes.push(code.code())
    slugs.push(code.slug())
  }
}

///|
test "the table has exactly the codes it is meant to have" {
  // 这条是绊线，不是断言业务价值：`all_warn_codes()` 是表里唯一不靠编译器
  // 检查的地方（match 是穷尽的，漏一个变体编译不过，但这个列表可以漏）。
  // 加了新码就会撞到这里，逼作者回来把列表补上，而不是让 --help-id 悄悄少一条。
  inspect(@lib.all_warn_codes().length(), content="2")
}

///|
test "W0 is the internal catch-all and W1 is the inferred base" {
  inspect(@lib.WarnCode::W0.slug(), content="internal-limit")
  inspect(@lib.WarnCode::W1.slug(), content="base-inferred")
  // W0 的说明要覆盖「工具自身读到一半」这一类，而不只是效果表被截断。
  inspect(@lib.WarnCode::W0.meaning().contains("environment"), content="true")
  // W1 的解法必须是「传 --cwd」，否则查了也不知道怎么消掉警告。
  inspect(@lib.WarnCode::W1.remedy().contains("--cwd"), content="true")
}
