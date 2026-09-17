///|
/// How much of the command the parser actually understood.
///
/// This is a first-class part of the result, not a debugging aid: a verdict
/// computed from a half-understood command line is not a weaker verdict, it is
/// a different thing, and callers have to be able to tell them apart.
pub(all) enum ParseStatus {
  /// Parsed end to end.
  Complete
  /// Valid bash (as far as we know) that this parser does not handle yet.
  /// The audit on top of it is incomplete, so the verdict floor is Ask.
  Unsupported
  /// bash would refuse this command too. Only claimed with corroboration;
  /// see `classify_error`.
  ///
  /// This is an abstention, not a clearance: a command that is not parsed
  /// cannot be audited, and the caller should forward bash's own error instead
  /// of treating our silence as approval. Do not translate "bash will refuse
  /// it anyway" into "so running it is harmless" — that inference is exactly
  /// the one this status exists to block.
  Invalid
} derive(Debug, Eq, ToJson)

///|
pub(all) enum IssueKind {
  /// This parser's gap. bash probably parses the construct fine, so nothing
  /// may be concluded from the partial tree: never report this as "invalid".
  Gap
  /// bash would refuse the command as well. Claiming this requires evidence:
  /// a false `Syntax` turns into an Allow on a command that may actually run,
  /// which is the one failure mode this whole tool exists to avoid.
  Syntax
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Issue {
  kind : IssueKind
  message : String
  line : Int
} derive(Debug, Eq, ToJson)

///|
/// The single result a caller acts on.
pub(all) struct Report {
  status : ParseStatus
  /// `None` when there is nothing to decide: the status is Invalid, bash
  /// itself will refuse the command, and the caller should pass the error
  /// through rather than act on an audit of a fragment.
  risk : Risk?
  findings : Array[Finding]
  issues : Array[Issue]
  /// Best effort. Only meaningful when `status` is `Complete`; `uncertain`
  /// is forced to true otherwise.
  impact : Impact
} derive(Debug, Eq, ToJson)

///|
/// Parse, audit and summarise one command line.
pub fn check(src : String, cfg : AuditConfig) -> Report {
  let (seq, errors) = parse(src)
  let issues : Array[Issue] = []
  for e in errors {
    issues.push(classify_error(e))
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
  let verdict = audit(seq, cfg)
  let findings = verdict.findings
  let base_impact = impact(seq)
  if status is Unsupported {
    findings.push({
      rule: "unsupported-syntax",
      risk: Ask,
      detail: "this parser did not understand the whole command; the audit below is incomplete",
      line: 0,
    })
  }
  // A partial tree may not produce an Allow, and an invalid one produces
  // nothing at all: the caller hands bash's own error through instead.
  let risk = match status {
    Invalid => None
    Unsupported => Some(worse(verdict.risk, Ask))
    Complete => Some(verdict.risk)
  }
  let final_impact = if status is Complete {
    base_impact
  } else {
    base_impact.mark_uncertain()
  }
  { status, risk, findings, issues, impact: final_impact, }
}

///|
/// Map a parser complaint to an issue kind.
///
/// The default is `Gap`, and that is the whole design: claiming "bash would
/// reject this" is a statement about a program we are not running, and getting
/// it wrong means waving through a command that executes.
fn classify_error(message : String) -> Issue {
  let kind = if corroborated_syntax_messages().contains(message) {
    Syntax
  } else {
    Gap
  }
  { kind, message, line: 0, }
}

///|
/// Messages that may be reported as `Syntax`, i.e. "bash would refuse this
/// input too".
///
/// This list is evidence-gated, not curated by taste. An entry may only be
/// added after `tools/corpus/run.sh` shows the message in the quadrant where
/// both bash and shaudit reject the input, and **never** in the quadrant where
/// bash parses it and shaudit does not. The harness fails when that invariant
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
  { effects: self.effects, write_roots: self.write_roots, uncertain: true, }
}
