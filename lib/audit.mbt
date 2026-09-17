///|
/// What the auditor thinks of a command line. This is the only thing the
/// caller is supposed to act on.
pub(all) enum Risk {
  Allow
  Ask
  Deny
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Finding {
  rule : String
  risk : Risk
  detail : String
  line : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Verdict {
  risk : Risk
  findings : Array[Finding]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct AuditConfig {
  /// Paths the caller is allowed to write, as absolute or workspace-relative.
  write_roots : Array[String]
  /// Names that always mean "a human should look at this".
  extra_ask : Array[String]
}

///|
pub fn AuditConfig::default() -> AuditConfig {
  { write_roots: ["/tmp"], extra_ask: [], }
}

///|
struct Auditor {
  cfg : AuditConfig
  findings : Array[Finding]
  mut depth : Int
}

///|
pub fn audit(seq : Seq, cfg : AuditConfig) -> Verdict {
  let a : Auditor = { cfg, findings: [], depth: 0, }
  a.walk_seq(seq)
  let mut worst = Allow
  for f in a.findings {
    worst = worse(worst, f.risk)
  }
  { risk: worst, findings: a.findings, }
}

///|
fn worse(a : Risk, b : Risk) -> Risk {
  match (a, b) {
    (Deny, _) | (_, Deny) => Deny
    (Ask, _) | (_, Ask) => Ask
    _ => Allow
  }
}

///|
fn Auditor::add(
  self : Auditor,
  rule : String,
  risk : Risk,
  detail : String,
  line : Int,
) -> Unit {
  self.findings.push({ rule, risk, detail, line, })
}

///|
fn Auditor::walk_seq(self : Auditor, seq : Seq) -> Unit {
  for item in seq.items {
    self.walk_pipeline(item.pipeline)
  }
}

///|
fn Auditor::walk_pipeline(self : Auditor, p : Pipeline) -> Unit {
  for i, c in p.cmds {
    self.walk_cmd(c)
    let name = match c {
      Cmd::Simple(s) => command_name(s)
      _ => None
    }
    match name {
      Some(n) =>
        if i > 0 && is_interpreter(n) {
          let fed_by_download = p.cmds[:i].any(fn(prev) {
            match prev {
              Cmd::Simple(s) =>
                match command_name(s) {
                  Some(pn) => is_downloader(pn)
                  None => false
                }
              _ => false
            }
          })
          if fed_by_download {
            self.add(
              "download-pipe-interpreter",
              Deny,
              "a downloader feeds `\{n}` on stdin",
              0,
            )
          } else {
            self.add(
              "pipe-into-interpreter",
              Ask,
              "piped into `\{n}`: the real command is on stdin",
              0,
            )
          }
        }
      None => ()
    }
  }
}

///|
fn Auditor::walk_cmd(self : Auditor, cmd : Cmd) -> Unit {
  match cmd {
    Cmd::Simple(s) => self.walk_simple(s)
    Cmd::Subshell(seq) | Cmd::Group(seq) => self.walk_seq(seq)
    Cmd::If(cond~, then_~, elifs~, else_~) => {
      self.walk_seq(cond)
      self.walk_seq(then_)
      for pair in elifs {
        let (c, b) = pair
        self.walk_seq(c)
        self.walk_seq(b)
      }
      match else_ {
        Some(e) => self.walk_seq(e)
        None => ()
      }
    }
    Cmd::Loop(cond~, body~, ..) => {
      self.walk_seq(cond)
      self.walk_seq(body)
    }
    Cmd::For(body~, words~, ..) => {
      for w in words {
        self.scan_word(w)
      }
      self.walk_seq(body)
    }
    Cmd::Case(subject~, items~) => {
      self.scan_word(subject)
      for it in items {
        for p in it.patterns {
          self.scan_word(p)
        }
        self.walk_seq(it.body)
      }
    }
    Cmd::FuncDef(name~, body~) => {
      if name == ":" {
        self.add(
          "function-name-colon",
          Deny,
          "function named `:` (fork-bomb shape)",
          0,
        )
      }
      self.walk_seq(Seq::{
        items: [{ pipeline: { negated: false, cmds: [body], }, op: Semi, }],
      })
    }
    Cmd::Arith(_) => ()
    Cmd::Cond(raw) =>
      if raw.contains("$(") || raw.contains("`") {
        self.add(
          "cond-command-substitution",
          Ask,
          "[[ ]] contains a command substitution: \{raw}",
          0,
        )
      }
  }
}

///|
fn is_interpreter(n : String) -> Bool {
  match n {
    "bash"
    | "sh"
    | "zsh"
    | "dash"
    | "ksh"
    | "python"
    | "python3"
    | "perl"
    | "ruby"
    | "node"
    | "php"
    | "Rscript" => true
    _ => false
  }
}

///|
fn is_downloader(n : String) -> Bool {
  match n {
    "curl" | "wget" | "fetch" | "http" | "httpie" | "aria2c" => true
    _ => false
  }
}

///|
fn is_writer(n : String) -> Bool {
  match n {
    "tee"
    | "cp"
    | "mv"
    | "install"
    | "truncate"
    | "dd"
    | "ln"
    | "mkfs"
    | "shred" => true
    _ => false
  }
}

///|
fn is_privilege(n : String) -> Bool {
  match n {
    "sudo" | "doas" | "su" | "pkexec" | "setpriv" => true
    _ => false
  }
}

///|
fn is_critical_path(p : String) -> Bool {
  if p == "" {
    return false
  }
  if p == "~" || p.has_prefix("~/") {
    return true
  }
  let abs = if p.has_prefix("/") { p } else { "/" + p }
  let roots = [
    "/dev", "/etc", "/boot", "/usr", "/var", "/bin", "/sbin", "/lib", "/opt", "/root",
    "/sys", "/proc",
  ]
  for r in roots {
    if abs == r || abs.has_prefix(r + "/") {
      return true
    }
  }
  abs == "/"
}

///|
/// Is the path inside one of the roots? A relative path is assumed to be
/// relative to the workspace, so it only escapes by walking up.
fn path_outside(p : String, roots : Array[String]) -> Bool {
  if p == "" {
    return true
  }
  if p.has_prefix("~") {
    return true
  }
  let norm = normalize_path(p)
  if !p.has_prefix("/") {
    return norm.has_prefix("../") || norm.has_prefix("/..")
  }
  for r in roots {
    let rr = if r.has_suffix("/") {
      r.unsafe_substring(start=0, end=r.length() - 1)
    } else {
      r
    }
    if norm == rr || norm.has_prefix(rr + "/") {
      return false
    }
  }
  true
}

///|
pub fn normalize_path(p : String) -> String {
  let out : Array[String] = []
  for seg in p.split("/") {
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if out.length() > 0 {
        ignore(out.pop())
      } else {
        out.push("..")
      }
      continue
    }
    out.push(seg.to_string())
  }
  let body = out.join("/")
  if p.has_prefix("/") {
    "/" + body
  } else {
    body
  }
}

///|
fn command_name(s : SimpleCmd) -> String? {
  match s.words {
    [w, ..] => w.static_text()
    _ => None
  }
}

///|
fn Auditor::walk_simple(self : Auditor, s : SimpleCmd) -> Unit {
  let name = command_name(s)
  for a in s.assigns {
    for p in a.value {
      self.scan_part(p)
    }
  }
  for r in s.redirects {
    self.scan_redirect(r)
  }
  for w in s.words {
    self.scan_word(w)
  }
  match name {
    None =>
      if s.words.length() > 0 {
        self.add(
          "dynamic-command",
          Ask,
          "command name is built at run time: \{s.words[0].literal_text()}",
          s.words[0].line,
        )
      }
    Some(n) => self.audit_named(n, s)
  }
}

///|
fn arg_texts(s : SimpleCmd) -> Array[String] {
  let out : Array[String] = []
  for w in s.words {
    out.push(w.literal_text())
  }
  out
}

///|
fn Auditor::audit_named(self : Auditor, n : String, s : SimpleCmd) -> Unit {
  let args = arg_texts(s)
  let line = match s.words {
    [w, ..] => w.line
    _ => 0
  }
  if is_privilege(n) {
    self.add("privilege", Ask, "`\{n}` escalates privileges", line)
  }
  if n == "eval" || (is_interpreter(n) && has_flag(args, "-c")) {
    self.audit_eval_like(n, s, line)
  }
  if n == "rm" {
    self.audit_rm(s, line)
  }
  if n == "dd" {
    for a in args {
      if a.has_prefix("of=") {
        let target = a.unsafe_substring(start=3, end=a.length())
        if target.has_prefix("/dev/") {
          self.add("dd-to-device", Deny, "dd writes to \{target}", line)
        } else if path_outside(target, self.cfg.write_roots) {
          self.add(
            "write-outside",
            Ask,
            "dd writes outside the sandbox: \{target}",
            line,
          )
        }
      }
    }
  }
  if n.has_prefix("mkfs") {
    self.add("mkfs", Deny, "`\{n}` formats a filesystem", line)
  }
  match n {
    "shutdown" | "reboot" | "halt" | "poweroff" | "init" =>
      self.add("power", Deny, "`\{n}` takes the machine down", line)
    _ => ()
  }
  if n == "chmod" || n == "chown" {
    if has_flag(args, "-R") && args.any(is_critical_path) {
      self.add("chmod-critical", Deny, "recursive \{n} on a system path", line)
    }
  }
  if is_writer(n) || (n == "sed" && has_flag(args, "-i")) {
    self.check_write_args(args, n, line)
  }
  if n == "sed" || n == "awk" || n == "xargs" || n == "find" {
    if args.any(fn(a) {
        a == "-exec" ||
        a == "-delete" ||
        a.contains("sh -c") ||
        a.contains("rm ")
      }) {
      self.add(
        "hidden-command",
        Ask,
        "`\{n}` can run another command: \{args.join(" ")}",
        line,
      )
    }
  }
  if n == "curl" || n == "wget" {
    for a in args {
      if a.has_prefix("-o") || a.has_prefix("--output") {
        let t : Array[String] = a
          .split("=")
          .to_array()
          .map(fn(s) { s.to_string() })
        if t.length() > 1 &&
          path_outside(t[t.length() - 1], self.cfg.write_roots) {
          self.add(
            "download-outside",
            Ask,
            "download writes outside the sandbox: \{a}",
            line,
          )
        }
      }
    }
  }
  for e in self.cfg.extra_ask {
    if n == e {
      self.add("extra-ask", Ask, "`\{n}` is on the watch list", line)
    }
  }
}

///|
fn has_flag(args : Array[String], flag : String) -> Bool {
  args.any(fn(a) {
    a == flag ||
    (
      a.has_prefix("-") &&
      !a.has_prefix("--") &&
      a.contains(flag.unsafe_substring(start=1, end=flag.length()))
    )
  })
}

///|
fn Auditor::check_write_args(
  self : Auditor,
  args : Array[String],
  n : String,
  line : Int,
) -> Unit {
  for a in args {
    if a.has_prefix("-") || a == "" {
      continue
    }
    if is_critical_path(a) {
      self.add(
        "write-critical",
        Deny,
        "`\{n}` touches a system path: \{a}",
        line,
      )
    } else if path_outside(a, self.cfg.write_roots) {
      self.add(
        "write-outside",
        Ask,
        "`\{n}` writes outside the sandbox: \{a}",
        line,
      )
    }
  }
}

///|
fn Auditor::audit_rm(self : Auditor, s : SimpleCmd, line : Int) -> Unit {
  let args = arg_texts(s)
  let recursive = has_flag(args, "-r") || has_flag(args, "-R")
  let targets : Array[String] = []
  for a in args {
    if !a.has_prefix("-") && a != "rm" {
      targets.push(a)
    }
  }
  for t in targets {
    if t == "/" {
      self.add("rm-root", Deny, "`rm` on /", line)
    } else if t == "~" || t == "/*" || t == "/.*" {
      self.add("rm-home", Deny, "`rm` on \{t}", line)
    } else if is_critical_path(t) {
      self.add("rm-critical", Deny, "`rm` under a system path: \{t}", line)
    } else if path_outside(t, self.cfg.write_roots) {
      self.add("rm-outside", Ask, "`rm` outside the sandbox: \{t}", line)
    }
  }
  if recursive &&
    targets.any(fn(t) { t == "" || t.contains("*") || t.contains("$") }) {
    self.add(
      "rm-recursive-wildcard",
      Ask,
      "recursive rm with a wildcard or hole",
      line,
    )
  }
  for w in s.words {
    if w.has_hole() && recursive {
      self.add(
        "rm-recursive-dynamic",
        Ask,
        "recursive rm whose target is built at run time",
        line,
      )
    }
  }
}

///|
/// `eval`, `bash -c`, `sh -c`: the real command is inside a string. If that
/// string is static we can just parse it and keep auditing; if it is not,
/// there is nothing honest left to say.
fn Auditor::audit_eval_like(
  self : Auditor,
  n : String,
  s : SimpleCmd,
  line : Int,
) -> Unit {
  if self.depth >= 4 {
    self.add("eval-depth", Ask, "nested eval beyond the audit depth", line)
    return
  }
  let script = match eval_script(s, n) {
    Some(x) => x
    None => {
      self.add(
        "eval-dynamic",
        Ask,
        "`\{n}` runs a string built at run time",
        line,
      )
      return
    }
  }
  let (seq, errors) = parse(script)
  self.depth += 1
  for e in errors {
    self.add("parse-error", Ask, "cannot parse eval body: \{e}", line)
  }
  self.walk_seq(seq)
  self.depth -= 1
}

///|
fn eval_script(s : SimpleCmd, n : String) -> String? {
  if n == "eval" {
    let sb = StringBuilder()
    for i, w in s.words {
      if i == 0 {
        continue
      }
      let t = match w.static_text() {
        Some(t) => t
        None => return None
      }
      if i > 1 {
        sb.write_char(' ')
      }
      sb.write_string(t)
    }
    return Some(sb.to_string())
  }
  let args = arg_texts(s)
  for i, a in args {
    if a == "-c" && i + 1 < args.length() {
      return s.words[i + 1].static_text()
    }
  }
  None
}

///|
fn Auditor::scan_redirect(self : Auditor, r : Redirect) -> Unit {
  let line = r.target.line
  match r.op {
    ROut | RAppend | RClobber | RInOut =>
      match r.target.static_text() {
        Some(p) =>
          if is_critical_path(p) {
            self.add(
              "write-critical",
              Deny,
              "redirect writes to a system path: \{p}",
              line,
            )
          } else if path_outside(p, self.cfg.write_roots) {
            self.add(
              "write-outside",
              Ask,
              "redirect writes outside the sandbox: \{p}",
              line,
            )
          }
        None => {
          if r.target.has_hole() {
            self.add(
              "write-dynamic",
              Ask,
              "redirect target is built at run time: \{r.target.literal_text()}",
              line,
            )
          }
          if r.target.has_glob() {
            self.add("write-glob", Ask, "redirect target is a glob", line)
          }
        }
      }
    RHereDoc | RHereDocStrip | RHereString =>
      match r.body {
        Some(b) =>
          if b.contains("$(") || b.contains("`") {
            self.add(
              "heredoc-command-substitution",
              Ask,
              "here-document body runs a command: \{b}",
              line,
            )
          }
        None => ()
      }
    _ => ()
  }
  self.scan_word(r.target)
}

///|
fn Auditor::scan_word(self : Auditor, w : Word) -> Unit {
  for p in w.parts {
    self.scan_part(p)
  }
}

///|
fn Auditor::scan_part(self : Auditor, p : WordPart) -> Unit {
  match p {
    CmdSub(seq) | ProcSub(_, seq) => self.walk_seq(seq)
    DQuote(inner) =>
      for q in inner {
        self.scan_part(q)
      }
    Param(_) => ()
    _ => ()
  }
}
