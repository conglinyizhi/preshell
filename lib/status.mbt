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
  /// Not a parse problem: the command parsed, but something about it means the
  /// report should not be read as a clean bill. A script declaring a shell this
  /// tool does not model is the case this exists for. A `Note` does not change
  /// `status`, but it does force `uncertain`.
  Note
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
  /// The first issues found, capped at `max_issues()`. Empty when the command
  /// parsed end to end.
  issues : Array[Issue]
  /// How many issues were found but not listed. Diagnostics scale with the
  /// input (a 5000-level nesting produced 5001 of them), and a caller needs to
  /// know the list it got is partial.
  issues_dropped : Int
} derive(Debug, Eq, ToJson)

///|
pub fn report_version() -> Int {
  1
}

///|
/// Analyse a command given as raw bytes: normalise the input the way the shell
/// does, then report. This is what a subprocess caller should use, since it is
/// the only path that sees the bytes as sent.
pub fn analyze_bytes(bytes : Bytes) -> Report {
  analyze_bytes_dialect(bytes, Bash)
}

///|
/// Analyse with a chosen dialect. When the caller names none, the input's own
/// declaration decides; see `dialect_for`.
pub fn analyze_bytes_dialect(bytes : Bytes, dialect : Dialect) -> Report {
  let (text, decode_notes) = decode_command(bytes)
  // Replaced bytes are a caveat, not a parse failure: the analysis ran.
  let r = add_notes(analyze_dialect(text, dialect), decode_notes, kind=Note)
  add_notes(r, declared_shell_note(text, dialect), kind=Gap)
}

///|
/// Fold input-normalisation notes into a report. Any note means the command we
/// analysed is not byte-for-byte what arrived, so nothing here may come back
/// looking clean.

///|
/// Fold extra notes into a report.
///
/// `kind` says what the note means: a `Gap` is something this parser could not
/// handle (status becomes `Unsupported`), while a `Note` is a caveat about an
/// analysis that did succeed — input bytes that were replaced, or a script
/// declaring a shell this tool does not model. A `Note` keeps the status and
/// only forces `uncertain`, which is what keeps "parser gap" a meaningful
/// count.
fn add_notes(
  r : Report,
  notes : Array[String],
  kind? : IssueKind = Gap,
) -> Report {
  if notes.length() == 0 {
    return r
  }
  let issues : Array[Issue] = []
  for n in notes {
    issues.push({ kind, message: n, line: 0, })
  }
  for i in r.issues {
    issues.push(i)
  }
  let total = issues.length() + r.issues_dropped
  let kept = if issues.length() > max_issues() {
    issues[:max_issues()].to_array()
  } else {
    issues
  }
  let status = if kind is Gap { Unsupported } else { r.status }
  {
    version: r.version,
    status,
    impact: r.impact.mark_uncertain(),
    issues: kept,
    issues_dropped: total - kept.length(),
  }
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
/// Parse `src` and report what it touches.
///
/// `Unsupported` and `Invalid` both force `impact.uncertain`, because an
/// incomplete trace is not a smaller answer, it is a different one: a caller
/// that ignores this will read "no writes reported" as "writes nothing".
pub fn analyze(src : String) -> Report {
  analyze_dialect(src, Bash)
}

///|
/// Same, in a chosen dialect.
pub fn analyze_dialect(src : String, dialect : Dialect) -> Report {
  // argv can carry a NUL too, so this path strips it as well. The bytes path
  // goes through decode_command first and lands here with it already gone.
  let (clean, nul_notes) = strip_nuls(src)
  let r = add_notes(analyze_clean(clean, dialect), nul_notes, kind=Note)
  add_notes(r, declared_shell_note(clean, dialect), kind=Gap)
}

///|
/// Drop NUL bytes, joining what surrounds them, which is what bash does.
fn strip_nuls(src : String) -> (String, Array[String]) {
  if !src.contains_char('\u{0}') {
    return (src, [])
  }
  let sb = StringBuilder::new()
  for c in src {
    if c != '\u{0}' {
      sb.write_char(c)
    }
  }
  (
    sb.to_string(),
    ["null byte in input: ignored and joined, the way the shell does it"],
  )
}

///|
fn analyze_clean(src : String, dialect : Dialect) -> Report {
  let (seq, errors, lines) = parse_located_dialect(src, dialect)
  let issues : Array[Issue] = []
  let mut has_gap = false
  let mut has_syntax = false
  let mut has_note = false
  for i, e in errors {
    let line = if i < lines.length() { lines[i] } else { 0 }
    let issue = classify_error(e, dialect, line~)
    // The status is decided from every complaint, including those the list
    // below does not carry: a dropped `Syntax` issue must still make the whole
    // report abstain.
    match issue.kind {
      Gap => has_gap = true
      Syntax => has_syntax = true
      // A note is not a parse failure: the status keeps describing the parse.
      Note => has_note = true
    }
    if i < max_issues() {
      issues.push(issue)
    }
  }
  let dropped = errors.length() - issues.length()
  let status = if has_syntax {
    Invalid
  } else if has_gap {
    Unsupported
  } else {
    Complete
  }
  let base = impact(seq)
  // A POSIX script that uses bash-only syntax gets its analysis called out: the
  // parse succeeded, so the status still says so, but the note and the
  // uncertainty say the answer is not what that shell would do.
  let notes = posix_mismatch_note(src, seq)
  for n in notes {
    issues.push({ kind: Note, message: n, line: 0, })
    has_note = true
  }
  let impact_ = if status is Complete && !has_note {
    base
  } else {
    base.mark_uncertain()
  }
  {
    version: report_version(),
    status,
    impact: impact_,
    issues,
    issues_dropped: dropped,
  }
}

///|
/// Map a parser complaint to an issue kind.
///
/// The default is `Gap`, and that is the whole design: claiming "bash would
/// reject this" is a statement about a program we are not running.
fn classify_error(
  message : String,
  dialect : Dialect,
  line? : Int = 0,
) -> Issue {
  let kind = if corroborated_syntax_messages(dialect).contains(message) {
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
fn corroborated_syntax_messages(dialect : Dialect) -> Array[String] {
  match dialect {
    // 证据只对着 bash 取过。zsh 语料上同一条消息落进缺口象限两次
    // （`${x//[^\\}]/}` 这类带括号表达式的展开 zsh 认、这个扫描器不认），
    // 所以它在 zsh 下没有资格升级成 Syntax。换方言要重新取证。
    Zsh => []
    Bash =>
      [
        // 证据：`${` 未闭合。语料 451 文件中只有 quote1.sub 落在「两边都报错」象限，
        // 缺口象限 0 次；手动对照 `bash -n -c 'echo ${x'` 也是解析期报错。
        // 强度上限就是这点证据（n=1，无反正例）。
        "unterminated ${",
      ]
  }
}

///|
/// The messages this dialect has evidence for, one per line for the harness.
/// The corpus harness needs the same list the classifier uses; reading it out
/// of the source only works while the table has one branch.
pub fn syntax_evidence(dialect : Dialect) -> Array[String] {
  corroborated_syntax_messages(dialect)
}

///|
/// Raise the uncertainty flag without touching the rest of the summary.
pub fn Impact::mark_uncertain(self : Impact) -> Impact {
  {
    effects: self.effects,
    write_roots: self.write_roots,
    uncertain: true,
    cwd: self.cwd,
    effects_dropped: self.effects_dropped,
  }
}
