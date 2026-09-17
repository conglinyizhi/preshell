///|
/// What this tool is, in one paragraph, because the boundary is the design:
///
/// It parses a shell command line and reports **what that command touches**:
/// which programs run, which paths are read, written or removed, what leaves
/// the machine, and where we could not tell. It does not decide whether any of
/// that is acceptable. There is no allowlist, no policy and no verdict here,
/// because "should this run" depends on context this tool does not have (which
/// sandbox, which user, which session) and belongs to whoever asked.
///
/// It is a standalone tool rather than a library: it is meant to be invoked as
/// a subprocess that reads a command and prints JSON, so callers in any
/// language can use it without linking it in.
pub(all) enum ParseStatus {
  /// Parsed end to end.
  Complete
  /// Valid shell (as far as we know) that this parser does not handle yet.
  /// The answer below is therefore incomplete.
  Unsupported
  /// bash would refuse this command too. Only claimed with corroboration;
  /// see `classify_error`. The report then lists no effects at all, because a
  /// command that cannot be parsed cannot be traced.
  Invalid
} derive(Debug, Eq, ToJson)

///|
pub(all) enum IssueKind {
  /// This parser's gap. bash probably parses the construct fine.
  Gap
  /// bash would refuse the command as well. Claiming this requires evidence:
  /// a false `Syntax` would turn an unparsed command into "nothing to see".
  Syntax
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Issue {
  kind : IssueKind
  message : String
  line : Int
} derive(Debug, Eq, ToJson)

///|
/// The answer. Facts only: `impact` says what the command touches, `status`
/// and `issues` say how much of the command we actually understood, and
/// nothing here says what anyone should do about it.
pub(all) struct Report {
  /// Shape version for callers that parse this JSON. Bumped when a field
  /// changes meaning, never for added optional fields.
  version : Int
  status : ParseStatus
  impact : Impact
  /// Empty when the command parsed end to end.
  issues : Array[Issue]
} derive(Debug, Eq, ToJson)

///|
pub fn report_version() -> Int {
  1
}

///|
/// Parse `src` and report what it touches.
///
/// `Unsupported` and `Invalid` both force `impact.uncertain`, because an
/// incomplete trace is not a smaller answer, it is a different one: a caller
/// that ignores this will read "no writes reported" as "writes nothing".
pub fn analyze(src : String) -> Report {
  let (seq, errors, lines) = parse_located(src)
  let issues : Array[Issue] = []
  for i, e in errors {
    let line = if i < lines.length() { lines[i] } else { 0 }
    issues.push(classify_error(e, line~))
  }
  let mut has_gap = false
  let mut has_syntax = false
  for i in issues {
    match i.kind {
      Gap => has_gap = true
      Syntax => has_syntax = true
    }
  }
  let status = if has_syntax {
    Invalid
  } else if has_gap {
    Unsupported
  } else {
    Complete
  }
  let base = impact(seq)
  let impact_ = if status is Complete { base } else { base.mark_uncertain() }
  { version: report_version(), status, impact: impact_, issues, }
}

///|
/// Map a parser complaint to an issue kind.
///
/// The default is `Gap`, and that is the whole design: claiming "bash would
/// reject this" is a statement about a program we are not running.
fn classify_error(message : String, line? : Int = 0) -> Issue {
  let kind = if corroborated_syntax_messages().contains(message) {
    Syntax
  } else {
    Gap
  }
  { kind, message, line, }
}

///|
/// Messages that may be reported as `Syntax`, i.e. "bash would refuse this
/// input too".
///
/// This list is evidence-gated, not curated by taste. An entry may only be
/// added after `tools/corpus/run.sh` shows the message in the quadrant where
/// both bash and this parser reject the input, and **never** in the quadrant
/// where bash parses it and we do not. The harness fails when that invariant
/// breaks, so a parser regression removes the right to claim `Invalid` instead
/// of quietly mislabelling a command that would actually run.
///
/// The strength of the guarantee is bounded by the corpus (bash's own
/// `tests/*.sub`, several hundred files), which is why the list stays short
/// and why an empty list is a perfectly good state: it means "never claim it".
fn corroborated_syntax_messages() -> Array[String] {
  [
    // 证据：`${` 未闭合。语料 451 文件中只有 quote1.sub 落在「两边都报错」象限，
    // 缺口象限 0 次；手动对照 `bash -n -c 'echo ${x'` 也是解析期报错。
    // 强度上限就是这点证据（n=1，无反正例）。
    "unterminated ${",
  ]
}

///|
/// Raise the uncertainty flag without touching the rest of the summary.
pub fn Impact::mark_uncertain(self : Impact) -> Impact {
  {
    effects: self.effects,
    write_roots: self.write_roots,
    uncertain: true,
    cwd: self.cwd,
  }
}
