#!/usr/bin/env bash
# Shared command-text helpers for gates that read a Bash/PowerShell command string.
#
#   command_without_heredoc_bodies   stdin -> stdout, heredoc BODIES removed (opener kept,
#                                    terminator dropped, everything after it kept)
#   command_text_stripped            stdin -> stdout, the above PLUS single-quoted spans
#                                    removed and double-quote characters dropped
#   command_scan_region "<command>"  prints the text a WRITE/DEPLOY gate should judge
#
# --- command_scan_region: the heredoc question, answered once ---------------------------
# Heredoc bodies are DATA by default: a commit message or skill edit that merely DESCRIBES a
# hazard must not self-deny (inplace-edit-gate.sh and deploy-verify-confirm-gate.sh both
# blocked their own first commits that way). Ten gates each did this with their own
# `head_region="${command%%<<*}"`, and every one of them was wrong the same way -- that
# strips from the FIRST `<<` to the END of the command, which deletes not just the heredoc
# body but every command after the terminator too. So
#     cat > x.sh <<'EOF'
#     <the write>
#     EOF
#     bash x.sh
# left the gate looking at `cat > x.sh` and nothing else. Confirmed by replay 2026-09-15:
# mongo-write-gate, psql-write-gate and graylog-write-gate all silently allowed a
# production write in that shape (inline form denied); prod-deploy-business-hours-gate and
# octopus-lambda-delete-gate had already been bypassed by it live the same morning. The
# harness's own style gates push commands INTO this shape (see lib-scan-script-refs.sh's
# header), so it is the normal case, not an exotic one.
#
# Rule: remove the heredoc bodies, then look at what is LEFT -- opener, terminator's line
# and everything after it. If that remaining text RUNS a file (bash/sh/pwsh/powershell
# <path>), the command both wrote and executed something in one step, and the body counts
# as code: return the whole command. Otherwise the body stays data: return the text without
# it. A documentation edit never executes what it wrote, so this separates the two without
# reopening the self-denial trap. The run-check is done on the body-free text on purpose --
# a commit message that SAYS "run bash x.sh" must not promote its own body.
#
# Do NOT use command_text_stripped for a write gate: it also strips single-quoted spans, and
# the Mongo/psql write lives inside a single-quoted `--eval` string.
#
# --- command_text_stripped: fixture text is not an invocation ----------------------------
# Removes heredoc bodies and single-quoted spans; keeps double-quoted spans with the quote
# characters dropped, because real invocations routinely live in one (`bash "$R/x.sh"`).
# Known, accepted escape: an invocation whose whole path is single-quoted is not seen.
# Consumers: foreign-worktree-changes-gate.sh, git-commit-scope-gate.sh,
# ready-to-test-regression-reminder.sh (the last of which had no exclusion at all and denied
# a Bash call whose only Jira content was a quoted test fixture, 2026-09-14).
#
# The awk deliberately contains NO quote characters of its own -- the heredoc terminator is
# isolated positionally and then scrubbed to word chars, which sidesteps both the shell
# quoting mess and the `\"`-in-a-bracket-expression warning gawk prints to stderr (a hook
# must stay silent on stderr).
command_without_heredoc_bodies() {
  awk '
    BEGIN { term = "" }
    {
      line = $0
      if (term != "") {
        t2 = line; sub(/;[ \t]*$/, "", t2); gsub(/^[ \t]+|[ \t]+$/, "", t2)
        if (t2 == term) { term = "" }
        next
      }
      p = index(line, "<<")
      if (p > 0) {
        tok = substr(line, p + 2)
        sub(/^-/, "", tok); sub(/^[ \t]+/, "", tok); sub(/[ \t].*$/, "", tok)
        gsub(/[^A-Za-z0-9_]/, "", tok)
        if (tok != "") { term = tok }
      }
      print line
    }'
}

command_text_stripped() {
  command_without_heredoc_bodies | sed -e "s/'[^']*'//g" | tr -d '\042'
}

command_scan_region() {
  local cmd="$1" nobody
  case "$cmd" in
    *'<<'*) ;;
    *) printf '%s' "$cmd"; return 0 ;;
  esac
  nobody="$(printf '%s' "$cmd" | command_without_heredoc_bodies)"
  if printf '%s' "$nobody" \
       | grep -qE '(^|[;&|)[:space:]])(bash|sh|pwsh|powershell)([.]exe)?[[:space:]]+[^-[:space:]]'; then
    printf '%s' "$cmd"
  else
    printf '%s' "$nobody"
  fi
}
