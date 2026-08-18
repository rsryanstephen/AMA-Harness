#!/usr/bin/env bash
# Shared mechanical fallback-rename logic, extracted from on-session-end.sh so it can
# also run retroactively for OTHER already-ended sessions from log-session-start.sh
# (closes the documented gap: SessionEnd never fires on an abrupt exit -- crash, killed
# terminal -- so a session stuck on its bare shortid fallback name had nothing to catch
# it until the NEXT session start swept for it).
#
# attempt_fallback_rename <sid> <chat_path> <resume_dir> [transcript_path]
# No-ops if $chat_path isn't still on the bare "<shortid> Chat.md" fallback name, is
# empty/missing, or has no locatable transcript to slugify from.
# transcript_path is optional -- pass it when the caller already has it (on-stop.sh
# has it from its own hook payload) to skip re-`find`ing it; omitted callers fall back
# to the find below.
attempt_fallback_rename() {
  local sid="$1" chat_path="$2" resume_dir="$3" tr_path="${4:-}"
  [ -f "$chat_path" ] || return 0
  [ -s "$chat_path" ] || return 0
  [ "$(basename "$chat_path")" = "${sid%%-*} Chat.md" ] || return 0

  if [ -z "$tr_path" ]; then
    tr_path="$(find "$HOME/.claude/projects" -name "$sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
  fi

  # Name-source priority, most-authoritative first:
  #   1. explicitname -- user-set customTitle (/rename, -n, Ctrl+R) or plan-accept's
  #      agentName. Snapshotted by on-stop.sh from the transcript's own metadata lines.
  #   2. aiTitle -- Claude Code's auto-generated session title. Written durably as a
  #      {"type":"ai-title","aiTitle":"..."} line in the transcript itself (append-
  #      only, latest wins), NOT the same thing as sessions/<pid>.json's "name" field
  #      below -- that field holds a derived "<dir>-<n>" placeholder (e.g.
  #      "exporterplus-37") whenever the user hasn't explicitly renamed, which carries
  #      no information. aiTitle is the real CLI-visible name in that common case.
  #   3. claudename -- snapshot of sessions/<pid>.json's "name", kept as a fallback for
  #      the rare case a transcript has no aiTitle line at all yet.
  # Read via grep, not jq -- mirrors on-stop.sh's own aiTitle/customTitle capture and
  # its ~88MB rationale (a full jq pass for one tail value is far slower), which
  # applies harder here since this now runs every turn, not just at exit.
  local cname
  cname="$(cat "$HOME/.claude/.session-chatfiles/$sid.explicitname" 2>/dev/null)"
  if [ -z "$cname" ] && [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
    cname="$(grep -oh '"aiTitle":"[^"]*"' "$tr_path" 2>/dev/null | tail -1 | sed 's/.*:"//;s/"$//')"
  fi
  if [ -z "$cname" ]; then
    cname="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .name // empty' "$HOME/.claude/sessions"/*.json 2>/dev/null | head -1)"
    [ -n "$cname" ] || cname="$(cat "$HOME/.claude/.session-chatfiles/$sid.claudename" 2>/dev/null)"
  fi
  cname="$(printf '%s' "$cname" | tr -d '\\/:*?"<>|' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//' | cut -c1-60)"
  if [ -n "$cname" ]; then
    bash "$HOME/.claude/hooks/rename-topic.sh" "$resume_dir" "$(basename "$chat_path")" "$cname" >/dev/null 2>&1
    return 0
  fi

  local slug_src full_slug slug
  slug_src=""
  if [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
    slug_src="$(jq -s -r '
      [.[] | select(.type=="system" and .subtype=="away_summary") | .content] | last // empty
    ' "$tr_path" 2>/dev/null | tr -d '\r')"
  fi
  if [ -z "$slug_src" ]; then
    slug_src="$(awk 'BEGIN{RS="\n---\n"} NR==1{print; exit}' "$chat_path")"
  fi
  full_slug="$(printf '%s' "$slug_src" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
  if [ "${#full_slug}" -gt 60 ]; then
    slug="$(printf '%s' "$full_slug" | cut -c1-60 | sed 's/-[^-]*$//; s/-*$//')"
  else
    slug="$full_slug"
  fi
  [ -n "$slug" ] || return 0
  bash "$HOME/.claude/hooks/rename-topic.sh" "$resume_dir" "$(basename "$chat_path")" "$slug" >/dev/null 2>&1
}
