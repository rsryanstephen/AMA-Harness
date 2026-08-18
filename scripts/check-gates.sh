#!/usr/bin/env bash
# Regression suite for the PreToolUse deny-gates. Feeds each gate a real payload and
# asserts its decision -- behavioural, never a source-grep for "does the file mention -i".
# A gate that can't fail is worse than no gate, and both gates here shipped with a fault
# that only an executed test surfaced (see the self-deny case below).
#
# Usage: check-gates.sh [harness-repo-root]
# Exit 0 = all asserted, 1 = at least one gate misbehaved (prints the failures).
#
# ADD A CASE whenever a gate gains or loses a match rule -- especially a FALSE-POSITIVE
# case. Both faults found so far were false positives, not missed denials.
#
# Payloads are built with `jq -n --arg`, never hand-escaped JSON: hand-escaped backslashes
# collapse in the tool-call transport and the test silently passes for the wrong reason
# (see the bash-command-style skill). Fixtures live in THIS FILE rather than inline in a
# Bash command for the same reason a quote-blind gate can't be tested inline -- a
# real-looking fixture in the command text self-triggers the gate under test.
set -u

harness="${1:-$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)}"
hooks="$harness/hooks"
[ -d "$hooks" ] || { printf 'check-gates.sh: cannot locate harness hooks dir (tried %s)\n' "$hooks" >&2; exit 1; }

pass=0; fail=0; skip=0

# decide <gate-file> <payload-json> -> prints "deny" | "allow" | "pass"
decide() {
  local raw
  raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>/dev/null)"
  if [ -z "$raw" ]; then printf 'pass'; return; fi
  printf '%s' "$raw" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || printf 'pass'
}

assert() {
  local desc="$1" gate="$2" expect="$3" payload="$4" got
  got="$(decide "$gate" "$payload")"
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL  %-46s want=%-5s got=%s\n' "$desc" "$expect" "$got"
  fi
}

bash_payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# ---------------------------------------------------------------- inplace-edit-gate.sh
G=inplace-edit-gate.sh
if [ -f "$hooks/$G" ]; then
  CL='$HOME/.claude'
  assert "sed -i on a harness symlink"      "$G" deny "$(bash_payload "sed -i 's/a/b/' $CL/harness-gaps.md")"
  assert "sed --in-place"                   "$G" deny "$(bash_payload "sed --in-place 's/a/b/' $CL/AGENTS.md")"
  assert "sed -i.bak (suffix form)"         "$G" deny "$(bash_payload "sed -i.bak 's/a/b/' $CL/CLAUDE.md")"
  assert "perl -i"                          "$G" deny "$(bash_payload "perl -i -pe 's/a/b/' $CL/settings.json")"
  assert "chained after &&"                 "$G" deny "$(bash_payload "echo hi && sed -i 's/a/b/' $CL/x.md")"
  assert "chained after ;"                  "$G" deny "$(bash_payload "date ; sed -i 's/a/b/' $CL/x.md")"
  # Bundled -i: the classic in-place perl idioms. Both PASSED the gate until 2026-08-18 --
  # the old pattern wanted a bare `-i`, so `-pi` slipped through the one thing it guards.
  assert "perl -pi (bundled)"               "$G" deny "$(bash_payload "perl -pi -e 's/a/b/' $CL/AGENTS.md")"
  assert "perl -npi.bak (bundled + suffix)" "$G" deny "$(bash_payload "perl -npi.bak -e 's/a/b/' $CL/AGENTS.md")"

  assert "sed -n is read-only"              "$G" pass "$(bash_payload "sed -n '1,5p' $CL/AGENTS.md")"
  # False positive: `-i` inside a FILENAME word (`edit-issue`), not a flag. Denied a
  # read-only `sed -n` on a real harness script path.
  assert "sed -n, path contains -i in word" "$G" pass "$(bash_payload "sed -n '1,25p' $CL/skills/ama-jira-api/scripts/jira-edit-issue.sh")"
  assert "grep -i is not an edit"           "$G" pass "$(bash_payload "grep -i foo $CL/AGENTS.md")"
  assert "sed -i outside the harness"       "$G" pass "$(bash_payload "sed -i 's/a/b/' /tmp/x.txt")"
  assert "cat"                              "$G" pass "$(bash_payload "cat $CL/harness-gaps.md")"
  assert "piped sed with no -i"             "$G" pass "$(bash_payload "cat $CL/AGENTS.md | sed 's/a/b/'")"
  assert "recursive grep"                   "$G" pass "$(bash_payload "grep -rn foo $CL/skills/")"

  # THE regression: the gate's own first version denied its own commit, because the message
  # DESCRIBES the hazard and a quote-blind matcher can't tell prose from an invocation.
  # Heredoc bodies are data; only the region before the first `<<` is measured.
  assert "heredoc body merely describing sed -i" "$G" pass "$(bash_payload "git commit -F - <<EOF
denies sed -i / perl -i against a $CL path, because sed -i renames over the symlink
EOF")"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ------------------------------------------------------------- confluence-media-gate.sh
G=confluence-media-gate.sh
CONFIG="$HOME/.claude/harness-config.json"
protected=""
[ -f "$CONFIG" ] && protected="$(jq -r '.atlassian.pagesWithNestedMedia[0]? // empty' < "$CONFIG" 2>/dev/null | tr -d '\r')"
if [ ! -f "$hooks/$G" ]; then
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
elif [ -z "$protected" ]; then
  # Correct for an adopter with no such page -- the gate is inert by design, so asserting
  # a deny here would fail for the wrong reason. Say so rather than silently passing.
  skip=$((skip+1)); printf 'SKIP  %s: .atlassian.pagesWithNestedMedia is empty (gate inert)\n' "$G"
else
  cpage() { jq -n --arg p "$1" --arg f "$2" \
    '{tool_name:"mcp__claude_ai_Atlassian__updateConfluencePage",tool_input:{pageId:$p,contentFormat:$f}}'; }
  assert "html write to a nested-media page"  "$G" deny "$(cpage "$protected" html)"
  assert "adf write to the same page"         "$G" pass "$(cpage "$protected" adf)"
  assert "html write to an unlisted page"     "$G" pass "$(cpage "0000000000" html)"
  # Wrong tool on the same matcher family must not be touched.
  assert "getConfluencePage is not a write"   "$G" pass "$(jq -n --arg p "$protected" \
    '{tool_name:"mcp__claude_ai_Atlassian__getConfluencePage",tool_input:{pageId:$p,contentFormat:"html"}}')"
fi

# ---------------------------------------------------------------- slack-brevity-gate.sh
G=slack-brevity-gate.sh
if [ -f "$hooks/$G" ]; then
  slack() { jq -n --arg t "$1" --arg m "$2" '{tool_name:$t,tool_input:{message:$m}}'; }
  LONG130="$(awk 'BEGIN{for(i=1;i<=130;i++) printf "word%d ", i}')"
  assert "130 prose words"                  "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message "$LONG130")"
  assert "130 words via the draft tool"     "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message_draft "$LONG130")"

  assert "a short message"                  "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "Reviewer Two - six Azure ranges on 80/443 arent LogicMonitor. Any idea what runs there? PROJ-15314.")"
  # Pasting data is not wordiness: a fenced block of 130 tokens must not trip the gate.
  assert "130 words inside a code fence"    "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '```\n%s\n```\n' "$LONG130")")"
  assert "long message, non-Slack tool"     "$G" pass "$(jq -n --arg m "$LONG130" \
    '{tool_name:"Write",tool_input:{message:$m}}')"

  # Rule 2: an address LIST needs per-item backticks -- Slack chips them separately.
  assert "bare list of 6 addresses"         "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "Reviewer Two - it held six Azure ranges: 20.42.35.32/28 .64/28 .80/28 .96/28 .112/28 .128/28. Any idea?")"
  # ONE span around the whole list is the same defect wearing backticks: one wide chip.
  assert "one span wraps the whole list"    "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    'Ranges: `20.42.35.32/28 .64/28 .80/28 .96/28 .112/28`')"
  assert "each address backticked"          "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    'Ranges: `20.42.35.32/28`  `.64/28`  `.80/28`  `.96/28`  `.112/28`  `.128/28`. Any idea?')"
  # Scoped to lists: prose mentions and a lone resource id must not be caught.
  assert "two bare addresses in prose"      "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "The ELB resolved to 3.211.43.34 and 3.232.204.239, both healthy.")"
  assert "lone sg- id, un-backticked"       "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "The Logic Monitor group (sg-def080a9) also held six ranges - any idea?")"
  assert "bare list inside a code fence"    "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf 'Ranges:\n```\n20.42.35.32/28 .64/28 .80/28 .96/28\n```\n')")"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi


# ============================================================ shared payload builders
# bash_payload() above sets only tool_name+command. Several gates resolve the session's home
# directory or repo from `cwd`/`session_id` and FAIL OPEN without them -- a case built with the
# bare builder would pass for the wrong reason. Hence explicit builders.
bash_payload_cwd() { jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
bash_payload_sid() { jq -n --arg c "$1" --arg d "$2" --arg s "$3" '{tool_name:"Bash",cwd:$d,session_id:$s,tool_input:{command:$c}}'; }
write_payload()    { jq -n --arg p "$1" --arg t "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$t}}'; }
edit_payload()     { jq -n --arg p "$1" --arg t "$2" '{tool_name:"Edit",tool_input:{file_path:$p,new_string:$t}}'; }
agent_payload()    { jq -n --arg p "$1" --argjson m "$2" '{tool_name:"Agent",tool_input:({prompt:$p}+$m)}'; }
mcp_payload()      { jq -n --arg t "$1" --argjson f "$2" '{tool_name:$t,tool_input:$f}'; }
skill_payload()    { jq -n --arg s "$1" '{tool_name:"Skill",tool_input:{skill:$s}}'; }

HARNESS_CWD="$harness"

# ------------------------------------------------------------ unanalyzable-script-gate.sh
# All four rules, each with the false-positive case that constrains it. Rules 2-4 were each
# added after a shape slipped past the previous ones and cost a real permission prompt.
G=unanalyzable-script-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "one-line for loop"                 "$G" deny "$(bash_payload 'for k in a b; do echo "$k"; done')"
  assert "multi-line while loop"             "$G" deny "$(bash_payload 'x=1
while read -r l; do echo "$l"; done < f')"
  assert "multi-line -m commit message"      "$G" deny "$(bash_payload 'git commit -q -m "subject

body line" -- a.md')"
  assert "unresolvable ALL-CAPS env ref"     "$G" deny "$(bash_payload 'curl -sS -u "me:$ATLASSIAN_API_TOKEN" https://example.internal/x')"
  assert "braced env ref"                    "$G" deny "$(bash_payload 'echo "${OCTOPUS_API_KEY:+set}"')"

  # Prescribed forms and idioms that MUST stay allowed -- these are the constraints.
  assert "heredoc commit body (prose 'if')"   "$G" pass "$(bash_payload "git commit -F - -- a.md <<'EOF'
PROJ-1: subject
if this breaks, for real, revert it
EOF")"
  assert "single-line if/then/fi"             "$G" pass "$(bash_payload 'if [ -f /etc/hosts ]; then echo yes; fi')"
  assert "jq program with \$p is not a shell var" "$G" pass "$(bash_payload "jq -r 'paths(scalars) as \$p | (\$p|join(\".\"))' f.json")"
  assert "\$HOME is resolvable"               "$G" pass "$(bash_payload 'ls -la "$HOME/.claude/hooks" | head -3')"
  assert "prose containing done and for"      "$G" pass "$(bash_payload 'echo "done deal, for the record"')"
  assert "multi-line, no ctrl flow or span"   "$G" pass "$(bash_payload 'echo one; echo two
printf "%s\n" three')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# -------------------------------------------------------------------- short-path-gate.sh
G=short-path-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "8.3 user-profile segment"          "$G" deny "$(bash_payload 'ls "C:/Users/RYAN~1.STE/AppData/Local/Temp"')"
  assert "8.3 PROGRA~1 segment"              "$G" deny "$(bash_payload 'ls "C:/PROGRA~1/Git/bin"')"
  # Git revisions and ~ home expansion share the tilde but are not 8.3 segments. The pattern
  # requires a trailing path separator precisely so these stay allowed.
  assert "git HEAD~1"                        "$G" pass "$(bash_payload 'git diff HEAD~1 --stat')"
  assert "git HEAD~1..HEAD range"            "$G" pass "$(bash_payload 'git log HEAD~1..HEAD --oneline')"
  assert "~/ home expansion"                 "$G" pass "$(bash_payload 'ls ~/.claude/hooks | head -3')"
  assert "long-form path"                    "$G" pass "$(bash_payload 'ls "C:/Users/your.windows.username/AppData/Local/Temp"')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# -------------------------------------------------------------------- grep-memory-gate.sh
G=grep-memory-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "recursive grep without -I"         "$G" deny "$(bash_payload 'grep -rn foo /some/tree')"
  assert "recursive long flag without -I"    "$G" deny "$(bash_payload 'grep --recursive foo /some/tree')"
  assert "recursive grep with -I"            "$G" pass "$(bash_payload 'grep -rIn foo /some/tree')"
  assert "non-recursive grep"                "$G" pass "$(bash_payload 'grep -n foo one-file.txt')"
  assert "ripgrep is not grep"               "$G" pass "$(bash_payload 'rg -n foo /some/tree')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# --------------------------------------------------------------- aggregation-secret-gate.sh
G=aggregation-secret-gate.sh
if [ -f "$hooks/$G" ]; then
  S='bash "$HOME/.claude/skills/ama-postgres-access/scripts/get-aggregation-connection.sh" staging'
  assert "connection script, output unconsumed" "$G" deny "$(bash_payload "$S")"
  # The documented consuming forms: the whole point is that the password never lands in the
  # transcript, so anything that captures the output is fine.
  assert "consumed via eval \$( )"           "$G" pass "$(bash_payload "eval \"\$($S)\"")"
  assert "consumed via pipe"                 "$G" pass "$(bash_payload "$S | grep -c PGPASSWORD")"
  assert "consumed via redirect"             "$G" pass "$(bash_payload "$S > /tmp/conn.env")"
  assert "unrelated postgres command"        "$G" pass "$(bash_payload 'psql -c "select 1"')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ===================================================== PostToolUse block-shape assertions
# Three output styles exist in this harness: PreToolUse `permissionDecision`, PostToolUse
# `{"decision":"block","reason":…}`, and plain non-zero exit. decide() only understands the
# first and returns "pass" for anything else -- routing a block-shaped gate through it would
# report a broken gate as healthy, so these get their own helper.
decide_block() {
  local raw rc
  raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>&1)"; rc=$?
  # Empty output MUST be handled before the jq probe: this box's jq (1.5rc1) exits 0 on empty
  # input, so `jq -e '.decision == "block"'` succeeds for a hook that said nothing at all.
  # Without this guard every silent (correctly-passing) gate reported as blocking -- three
  # false FAILs, and the same trap decide() above already sidesteps by testing -z first.
  if [ -z "$raw" ]; then
    if [ "$rc" -ne 0 ]; then printf 'block'; else printf 'pass'; fi
    return
  fi
  if printf '%s' "$raw" | jq -e '.decision == "block"' >/dev/null 2>&1; then printf 'block'; return; fi
  if [ "$rc" -ne 0 ]; then printf 'block'; return; fi
  printf 'pass'
}
assert_block() {
  local desc="$1" gate="$2" expect="$3" payload="$4" got
  got="$(decide_block "$gate" "$payload")"
  if [ "$got" = "$expect" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "$desc" "$expect" "$got"
  fi
}

PROBE_SID="check-gates-probe"

# The readme-family gates resolve the harness THEMSELVES from ~/.claude/skills and compare the
# edited path against it -- they ignore this script's $harness argument. So their payloads must
# name the real harness even when $hooks is a relocated copy (which is how mutation testing
# works: gate file from the copy, payload paths from reality). Pointing those payloads at a
# copied tree makes both gates fall through to "pass" and reads as two gate bugs.
real_harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$harness")"

# ------------------------------------------------------------------- native-memory-gate.sh
G=native-memory-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "write into native per-project memory" "$G" deny \
    "$(write_payload "$HOME/.claude/projects/C--Users-x-Repos-y/memory/note.md" "a fact")"
  assert "write into the harness memory store"  "$G" pass \
    "$(write_payload "$HOME/.claude/memory/a-fact.md" "a fact")"
  assert "ordinary repo write"                  "$G" pass \
    "$(write_payload "$harness/scratch/note.md" "a fact")"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ------------------------------------------------------------------ symlink-write-gate.sh
G=symlink-write-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "edit through a ~/.claude symlink"     "$G" deny "$(edit_payload "$HOME/.claude/AGENTS.md" "x")"
  assert "write through a ~/.claude symlink"    "$G" deny "$(write_payload "$HOME/.claude/harness-gaps.md" "x")"
  assert "edit the resolved repo path"          "$G" pass "$(edit_payload "$harness/AGENTS.md" "x")"
  assert "edit outside the harness"             "$G" pass "$(edit_payload "/tmp/whatever.md" "x")"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# -------------------------------------------------------------- standup-empty-section-gate.sh
# The heading is spelled "Couldn't summarize" -- with the apostrophe. A case written against
# "Could not summarize" passes vacuously, which is how this assert was nearly shipped wrong.
G=standup-empty-section-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "empty Couldn't-summarize section"     "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Couldn't summarize
- None.
")"
  assert "same section with a real bullet"      "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Couldn't summarize
- session 1a2b3c: transcript truncated mid-tool-call, no reply text recorded
")"
  assert "standup with no such section"         "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing
")"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ------------------------------------------------------------ subagent-model-tiering-gate.sh
# Warn-only: it returns permissionDecision "allow" WITH a reason rather than denying, so the
# assertion is allow-vs-pass. Asserting deny here would fail for the wrong reason.
G=subagent-model-tiering-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "Agent call with no model set"         "$G" allow "$(agent_payload "grep the fleet for a string" '{"subagent_type":"general-purpose"}')"
  assert "Agent call with model tiered"         "$G" pass  "$(agent_payload "grep the fleet for a string" '{"subagent_type":"general-purpose","model":"haiku"}')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ------------------------------------------------------------------- chrome-verify-nudge.sh
G=chrome-verify-nudge.sh
if [ -f "$hooks/$G" ]; then
  assert "UI-driving skill invoked"            "$G" allow "$(skill_payload "ama-ui-verify")"
  assert "unrelated skill invoked"             "$G" pass  "$(skill_payload "ama-graylog-search")"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ------------------------------------------------------------------- harness-ticket-gate.sh
# Epic arrives at .tool_input.additional_fields[<epicLinkFieldId>], not as a top-level field.
G=harness-ticket-gate.sh
if [ -f "$hooks/$G" ]; then
  EPICF="$(jq -r '.atlassian.epicLinkFieldId // "<epicLinkFieldId>"' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  EPICK="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  assert "new ticket under the harness epic"    "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    "$(jq -nc --arg f "$EPICF" --arg k "$EPICK" '{projectKey:"PROJ",summary:"x",additional_fields:{($f):$k}}')")"
  assert "new ticket under another epic"        "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    "$(jq -nc --arg f "$EPICF" '{projectKey:"PROJ",summary:"x",additional_fields:{($f):"PROJ-99999"}}')")"
  assert "new ticket with no epic at all"       "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x"}')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# --------------------------------------------------------------- jira-ticket-fields-gate.sh
G=jira-ticket-fields-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "new ticket with no assignee"          "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x","description":"- acceptance criteria: y"}')"
  # Two things a wrongly-written case gets wrong here: the field is assignee_account_id (not
  # assignee), AND the gate requires the USER'S OWN accountId -- someone else's is itself a
  # denial ("default assignee is always the user's own unless they explicitly asked").
  SELFACC="$(jq -r '.user.jiraAccountId // empty' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  if [ -n "$SELFACC" ]; then
    assert "new ticket assigned to the user"    "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      "$(jq -nc --arg a "$SELFACC" '{projectKey:"PROJ",summary:"x",assignee_account_id:$a,description:"- acceptance criteria: y"}')")"
    assert "new ticket assigned to someone else" "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"x","assignee_account_id":"ffffffffffffffffffffffff","description":"- acceptance criteria: y"}')"
  else
    skip=$((skip+1)); printf 'SKIP  %s: .user.jiraAccountId not configured\n' "$G"
  fi
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ---------------------------------------------------------- jira-ticket-description-gate.sh
G=jira-ticket-description-gate.sh
if [ -f "$hooks/$G" ]; then
  assert "description is prose only"            "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x","assignee":"abc","description":"just some prose about the problem"}')"
  assert "description has required sections"    "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x","assignee":"abc","issuetype":"Task","description":"h3. Requirements\n* thing\n\nh3. Acceptance criteria\n* works\n\nh3. How to test\n* run it"}')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# -------------------------------------------------------- jira-fixversion-confirm-gate.sh
# Versions arrive at .tool_input.fields.fixVersions[].name (MCP) -- there is also an
# additional_fields form and a Bash/PAYLOAD_FILE form for the jira-create-issue.sh path.
G=jira-fixversion-confirm-gate.sh
if [ -f "$hooks/$G" ]; then
  # Deliberately absurd versions: confirmations persist in ~/.claude/.confirmed-jira-versions,
  # so a real release number may already be confirmed on this machine and the gate would
  # correctly pass -- which reads as a gate bug. Keep test versions out of that file's range.
  assert "release/* Fix Version, unconfirmed"   "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"fixVersions":[{"name":"release/999.0.0"}]}}')"
  assert "hotfix/* Fix Version, unconfirmed"    "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"fixVersions":[{"name":"hotfix/999.0.9"}]}}')"
  assert "edit with no Fix Version"             "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"summary":"new title"}}')"
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ----------------------------------------------------------------- human-readme-edit-gate.sh
# PostToolUse, block shape, and it needs a session_id: without one it fails open, so a case
# built with the plain builders passes vacuously.
G=human-readme-edit-gate.sh
if [ -f "$hooks/$G" ]; then
  # Both readme-family gates are ONE-SHOT per session: they record state under
  # ~/.claude/.session-chatfiles/<sid>* and stay quiet afterwards. Reusing one probe sid makes
  # the first case pass and every later one silently "pass" for the wrong reason -- and a
  # leftover file from an earlier run makes even the first case pass. Fresh sid per case,
  # cleaned both sides.
  rm -f "$HOME/.claude/.session-chatfiles/check-gates-probe"* 2>/dev/null || true
  rp() { jq -n --arg p "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:"x"}}'; }
  assert_block "edit to README.md"             "$G" block "$(rp "$real_harness/README.md" "check-gates-probe-hr1")"
  assert_block "edit to AGENTS.md"             "$G" pass  "$(rp "$real_harness/AGENTS.md" "check-gates-probe-hr2")"
  assert_block "edit to a hook"                "$G" pass  "$(rp "$real_harness/hooks/statusline.sh" "check-gates-probe-hr3")"
  rm -f "$HOME/.claude/.session-chatfiles/check-gates-probe"* 2>/dev/null || true
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi

# ------------------------------------------------------------------ readme-currency-gate.sh
G=readme-currency-gate.sh
if [ -f "$hooks/$G" ]; then
  rm -f "$HOME/.claude/.session-chatfiles/check-gates-probe"* 2>/dev/null || true
  # This gate also has a SIZE threshold: it accumulates changed lines per file per session and
  # stays quiet at <= 5, so a one-line payload passes even for a file AGENTS.md names. Both
  # halves are asserted -- the quiet-for-small-edits behaviour is a feature, not an absence.
  cp2() { jq -n --arg p "$1" --arg s "$2" --arg t "$3" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:$t}}'; }
  BIG="$(printf 'line %s\n' 1 2 3 4 5 6 7 8)"
  assert_block "big edit to a hook AGENTS.md names" "$G" block "$(cp2 "$real_harness/hooks/statusline.sh" "check-gates-probe-rc1" "$BIG")"
  assert_block "one-line edit stays under threshold" "$G" pass "$(cp2 "$real_harness/hooks/statusline.sh" "check-gates-probe-rc2" "x")"
  assert_block "big edit to a scratch file"          "$G" pass "$(cp2 "$real_harness/scratch/throwaway.md" "check-gates-probe-rc3" "$BIG")"
  rm -f "$HOME/.claude/.session-chatfiles/check-gates-probe"* 2>/dev/null || true
else
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$G"
fi
printf '\ncheck-gates: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
