#!/usr/bin/env bash
# Fit-to-send helpers for the support-notices triage DM. Sourced by
# support-notices-unattended-run.sh (real path) and support-notices-parse-test.sh (fixtures).
# Rule (user, 2026-10-15): the monitor NEVER fails to send. Over the gate's limit ->
# summarize leg (runner) -> deterministic shrink here, which always ends sendable.
#
# The ACTUAL gate is the oracle (dm_gate_ok), not a re-derived count: it also enforces the
# bare-address-list rule, which truncation can trip by splitting a backtick span.

DM_HOOKS="${DM_HOOKS:-$HOME/.claude/hooks}"
. "$DM_HOOKS/lib-slack-words.sh"
DM_HEADER='Support notification triage:'

dm_words() { slack_prose_words "$1"; }

# Strip leading blank lines; force the header onto line 1 (the gate keys the raised
# ceiling off `head -1` -- without it the limit silently drops to 120).
dm_ensure_header() {
  local t
  t="$(printf '%s\n' "$1" | sed '/./,$!d')"
  if printf '%s\n' "$t" | head -1 \
     | grep -qiE '^[[:space:]]*\**[[:space:]]*Support notification triage[[:space:]]*:?[[:space:]]*\**[[:space:]]*$'; then
    printf '%s\n' "$t"
  else
    printf '%s\n%s\n' "$DM_HEADER" "$t"
  fi
}

# 0 = the real slack-brevity-gate.sh would let this message through.
dm_gate_ok() {
  local out
  out="$(jq -n --arg m "$1" '{tool_name:"mcp__claude_ai_Slack__slack_send_message",tool_input:{message:$m}}' \
    | bash "$DM_HOOKS/slack-brevity-gate.sh" 2>/dev/null)"
  case "$out" in *'"deny"'*) return 1 ;; *) return 0 ;; esac
}

# Header + body cut to <= $2 whitespace TOKENS (prose words <= tokens, so it fits by
# construction whatever backticks do), odd backtick closed, pointer line appended.
dm_truncate() {  # $1 text  $2 token budget  $3 pointer line
  local body cut
  body="$(printf '%s\n' "$1" | tail -n +2)"
  cut="$(printf '%s\n' "$body" | awk -v max="$2" '
    { line=""; n=split($0, w, /[[:space:]]+/)
      for (i=1; i<=n; i++) { if (w[i]=="") continue; if (used>=max) { done=1; break }
        line = line (line=="" ? "" : " ") w[i]; used++ }
      if (line != "") print line
      if (done) exit }')"
  if [ $(( $(printf '%s' "$cut" | tr -cd '`' | wc -c) % 2 )) -eq 1 ]; then cut="$cut\`"; fi
  printf '%s\n%s\n%s\n' "$DM_HEADER" "$cut" "$3"
}

# Can't-fail floor: header + count + pointer. No addresses, ~25 words.
dm_minimal() {  # $1 item count  $2 pointer line
  printf '%s\n%s mail(s) need review -- the full triage did not fit Slack.\n%s\n' "$DM_HEADER" "$1" "$2"
}

# Deterministic shrink. Sets DM_FIT_TEXT and DM_FIT_PATH (truncated|minimal). Always ends
# on something the gate passes; every stage is checked against the real gate.
dm_shrink() {  # $1 text (header already ensured)  $2 item count  $3 pointer line
  local limit budget t
  limit="$SLACK_LIMIT_SUPPORT"
  budget=$(( limit - 30 ))   # headroom for header + pointer line
  # Stage 1: header + first line of each item -- drop the per-item detail lines.
  # Bare addresses on backtick-free lines get their own backticks (gate's address-list rule).
  t="$(printf '%s\n' "$1" | grep -vE '^[[:space:]]*(`|Investigated:|Ticket:)' \
    | sed -E '/`/!s#([0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?)#`\1`#g')"
  t="$(dm_truncate "$t" "$budget" "$3")"
  if dm_gate_ok "$t"; then DM_FIT_TEXT="$t"; DM_FIT_PATH=truncated; return 0; fi
  DM_FIT_TEXT="$(dm_minimal "$2" "$3")"; DM_FIT_PATH=minimal
}
