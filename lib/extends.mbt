///|
/// Explicit `Eq` methods for this package's public types.
///
/// The compiler warns that the methods `derive(Eq)` generates are implicitly
/// promoted to regular methods, and that the promotion will be removed. Writing
/// them out is what the upstream library does (see `core/*/extends.mbt`), and it
/// keeps `==` and `!=` working on these types once the promotion is gone.
pub extend AndOr with Eq::{equal}

///|
pub extend AndOr with Eq::{not_equal}

///|
pub extend ArgScan with Eq::{equal}

///|
pub extend ArgScan with Eq::{not_equal}

///|
pub extend Assign with Eq::{equal}

///|
pub extend Assign with Eq::{not_equal}

///|
pub extend Bashisms with Eq::{equal}

///|
pub extend Bashisms with Eq::{not_equal}

///|
pub extend BinOp with Eq::{equal}

///|
pub extend BinOp with Eq::{not_equal}

///|
pub extend CaseItem with Eq::{equal}

///|
pub extend CaseItem with Eq::{not_equal}

///|
pub extend Cmd with Eq::{equal}

///|
pub extend Cmd with Eq::{not_equal}

///|
pub extend Dialect with Eq::{equal}

///|
pub extend Dialect with Eq::{not_equal}

///|
pub extend Effect with Eq::{equal}

///|
pub extend Effect with Eq::{not_equal}

///|
pub extend EffectKind with Eq::{equal}

///|
pub extend EffectKind with Eq::{not_equal}

///|
pub extend FramedLine with Eq::{equal}

///|
pub extend FramedLine with Eq::{not_equal}

///|
pub extend Impact with Eq::{equal}

///|
pub extend Impact with Eq::{not_equal}

///|
pub extend Issue with Eq::{equal}

///|
pub extend Issue with Eq::{not_equal}

///|
pub extend IssueKind with Eq::{equal}

///|
pub extend IssueKind with Eq::{not_equal}

///|
pub extend OptSpec with Eq::{equal}

///|
pub extend OptSpec with Eq::{not_equal}

///|
pub extend OptVal with Eq::{equal}

///|
pub extend OptVal with Eq::{not_equal}

///|
pub extend OptValue with Eq::{equal}

///|
pub extend OptValue with Eq::{not_equal}

///|
pub extend ParseStatus with Eq::{equal}

///|
pub extend ParseStatus with Eq::{not_equal}

///|
pub extend Pipeline with Eq::{equal}

///|
pub extend Pipeline with Eq::{not_equal}

///|
pub extend ProgOpts with Eq::{equal}

///|
pub extend ProgOpts with Eq::{not_equal}

///|
pub extend Redirect with Eq::{equal}

///|
pub extend Redirect with Eq::{not_equal}

///|
pub extend RedirOp with Eq::{equal}

///|
pub extend RedirOp with Eq::{not_equal}

///|
pub extend Report with Eq::{equal}

///|
pub extend Report with Eq::{not_equal}

///|
pub extend Seq with Eq::{equal}

///|
pub extend Seq with Eq::{not_equal}

///|
pub extend SimpleCmd with Eq::{equal}

///|
pub extend SimpleCmd with Eq::{not_equal}

///|
pub extend Tok with Eq::{equal}

///|
pub extend Tok with Eq::{not_equal}

///|
pub extend Word with Eq::{equal}

///|
pub extend Word with Eq::{not_equal}

///|
pub extend WordPart with Eq::{equal}

///|
pub extend WordPart with Eq::{not_equal}

///|
pub extend AndOr with @debug.Debug::{to_repr}

///|
pub extend ArgScan with @debug.Debug::{to_repr}

///|
pub extend Assign with @debug.Debug::{to_repr}

///|
pub extend Bashisms with @debug.Debug::{to_repr}

///|
pub extend BinOp with @debug.Debug::{to_repr}

///|
pub extend CaseItem with @debug.Debug::{to_repr}

///|
pub extend Cmd with @debug.Debug::{to_repr}

///|
pub extend Dialect with @debug.Debug::{to_repr}

///|
pub extend Effect with @debug.Debug::{to_repr}

///|
pub extend EffectKind with @debug.Debug::{to_repr}

///|
pub extend FramedLine with @debug.Debug::{to_repr}

///|
pub extend Impact with @debug.Debug::{to_repr}

///|
pub extend Issue with @debug.Debug::{to_repr}

///|
pub extend IssueKind with @debug.Debug::{to_repr}

///|
pub extend OptSpec with @debug.Debug::{to_repr}

///|
pub extend OptVal with @debug.Debug::{to_repr}

///|
pub extend OptValue with @debug.Debug::{to_repr}

///|
pub extend ParseStatus with @debug.Debug::{to_repr}

///|
pub extend Pipeline with @debug.Debug::{to_repr}

///|
pub extend ProgOpts with @debug.Debug::{to_repr}

///|
pub extend Redirect with @debug.Debug::{to_repr}

///|
pub extend RedirOp with @debug.Debug::{to_repr}

///|
pub extend Report with @debug.Debug::{to_repr}

///|
pub extend Seq with @debug.Debug::{to_repr}

///|
pub extend SimpleCmd with @debug.Debug::{to_repr}

///|
pub extend Tok with @debug.Debug::{to_repr}

///|
pub extend Word with @debug.Debug::{to_repr}

///|
pub extend WordPart with @debug.Debug::{to_repr}

///|
pub extend AndOr with ToJson::{to_json}

///|
pub extend Assign with ToJson::{to_json}

///|
pub extend Bashisms with ToJson::{to_json}

///|
pub extend BinOp with ToJson::{to_json}

///|
pub extend CaseItem with ToJson::{to_json}

///|
pub extend Cmd with ToJson::{to_json}

///|
pub extend Dialect with ToJson::{to_json}

///|
pub extend Effect with ToJson::{to_json}

///|
pub extend EffectKind with ToJson::{to_json}

///|
pub extend Impact with ToJson::{to_json}

///|
pub extend Issue with ToJson::{to_json}

///|
pub extend IssueKind with ToJson::{to_json}

///|
pub extend ParseStatus with ToJson::{to_json}

///|
pub extend Pipeline with ToJson::{to_json}

///|
pub extend Redirect with ToJson::{to_json}

///|
pub extend RedirOp with ToJson::{to_json}

///|
pub extend Report with ToJson::{to_json}

///|
pub extend Seq with ToJson::{to_json}

///|
pub extend SimpleCmd with ToJson::{to_json}

///|
pub extend Word with ToJson::{to_json}

///|
pub extend WordPart with ToJson::{to_json}
