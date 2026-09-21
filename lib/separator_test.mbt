///|
/// Command boundaries: where one statement ends and the next begins.
///
/// These tests exist because the first version of the separator rule was a
/// blunt one: treating "no separator seen" as an implicit `;` let
/// `printf "%s\n" a=(a b)` parse as `printf` followed by a subshell, producing
/// an Allow and a fabricated effect list for a line bash rejects. Tightening it
/// then over-corrected and rejected valid input (gaps went 12 -> 81), so both
/// directions are locked down here.
fn status_of(src : String) -> ParseStatus {
  analyze(src).status
}

///|
test "a command list needs an explicit separator" {
  // bash rejects all three; we report our own gap rather than a verdict.
  debug_inspect(status_of("printf \"%s\\n\" a=(a b)"), content="Unsupported")
  debug_inspect(
    status_of("switch foo in foo) echo ok;; esac"),
    content="Unsupported",
  )
  debug_inspect(status_of("echo a)"), content="Unsupported")
}

///|
test "valid statements stay complete" {
  // Regression guard for the over-correction: every line here is valid bash
  // and must not be reported as a gap.
  let valid = [
    "rm -rf build/", "a=(1 2); echo ok", "(echo a); (echo b)", "case x in a) echo y;; esac",
    "for f in a b; do echo $f; done", "echo $(case y in a) echo z;; esac)", "{ echo a; }",
    "if [ -f x ]; then echo y; fi", "echo a", "echo a &", "echo a | wc -l", "f() { echo a; }",
  ]
  for src in valid {
    if status_of(src) is Unsupported {
      fail("regressed on valid input: \{src}")
    }
  }
}

///|
test "declaration builtins take assignment arguments" {
  // bash's rule is parse.y:5798-5810 (ASSIGNMENT_BUILTIN, plus eval and let).
  debug_inspect(status_of("declare -a x=(1 2)"), content="Complete")
  debug_inspect(status_of("typeset -A foo=([one]=bar)"), content="Complete")
  debug_inspect(status_of("local -a x=() y=()"), content="Complete")
  // `unset` is not a declaration builtin, and bash refuses this too.
  debug_inspect(status_of("unset x=(1)"), content="Unsupported")
}

///|
test "redirections may precede the command word" {
  debug_inspect(status_of("< /dev/null foo bar"), content="Complete")
  debug_inspect(status_of("> /tmp/out echo hi"), content="Complete")
  debug_inspect(status_of("2>&1 cmd"), content="Complete")
}

///|
test "a connector is followed by a command, not by another connector" {
  // Measured: both shells refuse every one of these. They are the shapes a
  // differential fuzzer found us accepting.
  for
    c in [
      "true &&& x", "true ||| x", "true && || x", "true | | x", "true & & x", "echo a >>&2",
    ] {
    debug_inspect(analyze(c).status, content="Unsupported")
  }
  // zsh is the lenient one about empty commands between separators, and about
  // its own `>>&` spelling; bash is strict on both.
  debug_inspect(zstatus("true && ; x"), content="Complete")
  debug_inspect(zstatus("true ; ; x"), content="Complete")
  debug_inspect(analyze("true && ; x").status, content="Unsupported")
  debug_inspect(zstatus("echo a >>&2"), content="Complete")
  // A redirection after a connector starts a redirect-only command, which is
  // legal in both shells, and the ordinary connectors keep working.
  for
    c in [
      "true && > f", "true && (x)", "true && { x; }", "echo a &>> f", "echo a >> f",
    ] {
    debug_inspect(analyze(c).status, content="Complete")
  }
}
