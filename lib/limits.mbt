///|
/// Every cap this tool applies, in one place.
///
/// Each one exists because something real was unbounded: 40000 nested `if` blew
/// the native stack, `((` crashed on an inverted slice interval, a 15KB input
/// produced a 280KB answer of issues, a 360KB input produced 39000 effects, and
/// a command line with eight here-documents produced a report nobody could read.
/// A cap that fires is reported (`*_dropped`, or a note) and forces `uncertain`,
/// because a partial answer that does not say it is partial is the failure mode
/// this tool exists to prevent.
///
/// They are gathered here so the numbers can be compared at a glance: a cap far
/// above its neighbours means one layer is paying for another's unbounded work.

///|
/// How many words a `for` list may have before its body is no longer walked
/// once per word. Unrolling is linear in the word count and multiplies the
/// effects of the body, so a list longer than this keeps the old answer — a
/// hole — instead of filling the effect list with copies of the same body.
fn max_unroll() -> Int {
  64
}

///|
/// How many values one name may hold before the tool stops tracking it. A set is
/// what the value *may* be, so a bigger one is still honest — just not worth
/// carrying, and the answer falls back to the plain hole.
fn max_values() -> Int {
  8
}

///|
/// How many paths one hole may name before the list stops being useful. Same
/// reasoning: past this the hole says everything the list would.
fn max_candidates() -> Int {
  8
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
/// How many effects a report carries. Effects are the answer, not diagnostics,
/// so the cap is generous — but it exists: a 360KB input of nested `if` used to
/// produce 39k effects and a 2.8MB answer, which is not something to hand a
/// caller that is going to paste it somewhere. `effects_dropped` says how many
/// were left out, and dropping any forces `uncertain`, because a partial effect
/// list is not a smaller answer.
fn max_effects() -> Int {
  4096
}

///|
/// How deep the parser may recurse before it refuses. Measured: 40000 nested
/// `if` statements segfault the native build, and the recursion is the shell's
/// own grammar, so the depth is bounded here rather than left to the stack.
fn max_nesting() -> Int {
  1024
}

///|
/// How many issues a report carries. Diagnostics scale with the input: a
/// 5000-level nesting produced 5001 issues and a 280KB answer for a 15KB
/// question. The count of what was left out is reported instead, so a caller
/// can tell something is wrong without paying for the whole list.
fn max_issues() -> Int {
  64
}

///|
/// Wrapper nesting is bounded like every other recursion here: a command line
/// of 10000 `env` words must not decide whether this process survives.
fn max_wrapper_depth() -> Int {
  16
}
