///|
/// Warning codes.
///
/// A warning a caller might act on needs a name that does not move. The message
/// text is prose and will be edited; a downstream reader that keyed on it would
/// break silently the first time someone reworded a sentence. The code is the
/// stable key, and `preshell --help-id=W1` answers what it means and how to make
/// it go away.
///
/// Adding a code is cheap and intended to stay cheap. What is not cheap is
/// inventing one at a call site: `add_note` takes a `WarnCode`, not a string, so
/// a new warning has to be declared here first, which is what keeps
/// `--help-id` complete.
pub(all) enum WarnCode {
  /// An internal limit or unexpected state. The report is a lower bound.
  W0
  /// `--cwd` was not given, so the base was inferred rather than asserted.
  W1
} derive(Debug, Eq, ToJson)

///|
/// The code as it appears in a report and on the command line.
pub fn WarnCode::code(self : WarnCode) -> String {
  match self {
    W0 => "W0"
    W1 => "W1"
  }
}

///|
/// A short stable name for the condition, for callers that would rather log a
/// word than look a number up.
pub fn WarnCode::slug(self : WarnCode) -> String {
  match self {
    W0 => "internal-limit"
    W1 => "base-inferred"
  }
}

///|
/// One line: what happened.
pub fn WarnCode::message(self : WarnCode) -> String {
  match self {
    W0 =>
      (
        #|an internal limit or unexpected state was reached: the report is a lower bound, not a closed set
      )
    W1 =>
      (
        #|no --cwd given: relative paths were resolved against the current directory, not one the caller asserted; impact.cwd names the base
      )
  }
}

///|
/// What the code means, in as much detail as it needs.
pub fn WarnCode::meaning(self : WarnCode) -> String {
  match self {
    W0 =>
      (
        #|Something inside the analyser stopped early or was missing. Three shapes so far: the effect list or the issue list reached its cap, a bounded recursion (a nested shell, a wrapper program) ran out of depth, or the tool could not determine something about its own environment (its current directory) and had to continue without it. Nothing about the command is necessarily wrong; what is wrong is treating the answer as complete.
      )
    W1 =>
      (
        #|The paths in this report were resolved, but the base they were resolved against was not supplied by the caller. The tool fell back to the directory its own process was started in. That is usually the caller's directory, and usually is not a guarantee: the caller knows where the command will run, and the tool does not.
      )
  }
}

///|
/// How to make the warning stop.
pub fn WarnCode::remedy(self : WarnCode) -> String {
  match self {
    W0 =>
      (
        #|Nothing in the command to change. Read the report as partial, and treat any path list as a lower bound. If a small command triggers this, that is worth reporting: the limits are meant to be far out of reach for ordinary input.
      )
    W1 =>
      (
        #|Pass --cwd=PATH with the absolute directory the command will run in. The warning disappears and impact.uncertain is no longer forced by it.
      )
  }
}

///|
/// Every code, for `--help-id` and for the tests that keep the table honest.
///
/// The matches above are exhaustive, so a new variant cannot be added without
/// giving it a code, a slug, a meaning and a remedy. This list is the one place
/// that is not compiler-checked; `warnings_test.mbt` pins its length so that
/// adding a variant without adding it here fails a test rather than silently
/// shipping a code `--help-id` does not list.
pub fn all_warn_codes() -> Array[WarnCode] {
  [W0, W1]
}

///|
/// Read a code back from its text form. Unknown text is a usage error at the
/// call site rather than a silent `None` that prints nothing useful.
pub fn parse_warn_code(text : String) -> WarnCode? {
  for code in all_warn_codes() {
    if code.code() == text {
      return Some(code)
    }
  }
  None
}
