#!/usr/bin/env bash
# Shared mechanical fallback-rename logic, extracted from on-session-end.sh so it can
# also run retroactively for OTHER already-ended sessions from log-session-start.sh
# (closes the documented gap: SessionEnd never fires on an abrupt exit -- crash, killed
# terminal -- so a session stuck on its bare shortid fallback name had nothing to catch
# it until the NEXT session start swept for it).
#
# resolve_cc_name <sid> [transcript_path]
# Echoes Claude Code's own name for this session, sanitized (illegal filename chars
# stripped, whitespace collapsed, capped at 60 chars), or empty if none exists yet.
# Name-source priority, most-authoritative first:
#   1. customTitle -- the LATEST customTitle line in the transcript. Strict top tier:
#      user intent via /rename, -n, or Ctrl+R must keep winning over any later
#      auto-title, or /rename stops pinning a name.
#   2. Whichever of aiTitle / agentName was written LAST in the transcript, by file
#      position -- not a fixed tier order between the two. Both are Claude-assigned
#      and both move independently (confirmed: one real session had 5 distinct
#      aiTitles but only 4 distinct agentNames across its life -- they don't track
#      each other), so freezing on "aiTitle always beats agentName" or vice versa
#      can pin a stale name once one of the two stops moving.
#   3. explicitname/claudename snapshots (written by on-stop.sh), then
#      sessions/<pid>.json's "name" -- fallback ONLY for a session whose transcript
#      is missing/unreadable (the dead-session sweep case these were always right
#      for). A live session always has a readable transcript, so this tier is
#      never reached for one.
# Read via grep, not jq -- mirrors on-stop.sh's own capture and its ~88MB rationale
# (a full jq pass for one tail value is far slower). Bounded to the transcript's
# last ~4MB first (title lines are appended every few turns, so the tail hits
# almost always) and only falls back to a full-file scan if that comes up empty --
# same bounded-tail idea as session-ctx-sizes.pl's usage scan, needed here because
# sync_session_name calls this on every tool call now, not just at Stop.
resolve_cc_name() {
  local sid="$1" tr_path="${2:-}"
  if [ -z "$tr_path" ]; then
    tr_path="$(find "$HOME/.claude/projects" -name "$sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
  fi

  local cname=""
  if [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
    local hits
    hits="$(tail -c 4000000 "$tr_path" 2>/dev/null | grep -on '"customTitle":"[^"]*"\|"aiTitle":"[^"]*"\|"agentName":"[^"]*"')"
    [ -n "$hits" ] || hits="$(grep -on '"customTitle":"[^"]*"\|"aiTitle":"[^"]*"\|"agentName":"[^"]*"' "$tr_path" 2>/dev/null)"

    local last_custom last_ai last_agent
    last_custom="$(printf '%s\n' "$hits" | grep '"customTitle"' | tail -1)"
    last_ai="$(printf '%s\n' "$hits" | grep '"aiTitle"' | tail -1)"
    last_agent="$(printf '%s\n' "$hits" | grep '"agentName"' | tail -1)"

    if [ -n "$last_custom" ]; then
      cname="$(printf '%s' "$last_custom" | sed 's/^[0-9]*:.*:"//;s/"$//')"
    else
      # No customTitle at all -- whichever of aiTitle/agentName has the higher line
      # number (last in file) wins.
      local ai_line agent_line
      ai_line="$(printf '%s' "$last_ai" | cut -d: -f1)"
      agent_line="$(printf '%s' "$last_agent" | cut -d: -f1)"
      if [ -n "$ai_line" ] && { [ -z "$agent_line" ] || [ "$ai_line" -ge "$agent_line" ]; }; then
        cname="$(printf '%s' "$last_ai" | sed 's/^[0-9]*:.*:"//;s/"$//')"
      elif [ -n "$last_agent" ]; then
        cname="$(printf '%s' "$last_agent" | sed 's/^[0-9]*:.*:"//;s/"$//')"
      fi
    fi
  fi

  if [ -z "$cname" ]; then
    cname="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .name // empty' "$HOME/.claude/sessions"/*.json 2>/dev/null | head -1)"
    [ -n "$cname" ] || cname="$(cat "$HOME/.claude/.session-chatfiles/$sid.explicitname" 2>/dev/null)"
    [ -n "$cname" ] || cname="$(cat "$HOME/.claude/.session-chatfiles/$sid.claudename" 2>/dev/null)"
  fi
  printf '%s' "$cname" | tr -d '\\/:*?"<>|' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//' | cut -c1-60
}

# attempt_fallback_rename <sid> <chat_path> <resume_dir> [transcript_path]
# No-ops if $chat_path isn't still on the bare "<shortid> Chat.md" fallback name, is
# empty/missing, or has no locatable transcript to slugify from. Fires ONCE per
# session -- the basename guard below is never true again after this runs -- so this
# stays the retroactive-sweep entry point (log-session-start.sh) and never touches an
# already-named, but merely stale, session. That's what keeps one-name-per-session
# "going forward only": a dead session sitting on an old harness-era topic is left
# alone by this, same as before. Following a LIVE session's name as it changes is
# sync_session_name below, a different function on purpose.
attempt_fallback_rename() {
  local sid="$1" chat_path="$2" resume_dir="$3" tr_path="${4:-}"
  [ -f "$chat_path" ] || return 0
  [ -s "$chat_path" ] || return 0
  [ "$(basename "$chat_path")" = "${sid%%-*} Chat.md" ] || return 0

  if [ -z "$tr_path" ]; then
    tr_path="$(find "$HOME/.claude/projects" -name "$sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
  fi

  local cname
  cname="$(resolve_cc_name "$sid" "$tr_path")"
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

# sync_session_name <sid> <chat_path> <resume_dir> [transcript_path]
# One-name-per-session: keeps the chat file (and via rename-topic.sh, sessions.txt)
# following Claude Code's OWN name for this session, live, every time it changes --
# not just once like attempt_fallback_rename above. Called every turn end from
# on-stop.sh, gated there on the name actually having changed, but the real
# idempotence check is the basename comparison below (cheap, and correct even if the
# caller's change-gate is ever wrong): a resolved name equal to what the file is
# already called is a silent no-op, so calling this redundantly is always safe.
#
# Empty-slug guard: real corpus data has a customTitle of literally `"` (one
# straight quote), which resolve_cc_name's tr -d strips to the empty string. Once
# .customtitle actually drives a rename (this function), an empty result must be a
# no-op, not "rename to nothing" -- rename-topic.sh would likely just error, but
# relying on that instead of checking here risks a malformed rename slipping through
# on some other future garbage input that happens to survive sanitization as
# whitespace-only.
sync_session_name() {
  local sid="$1" chat_path="$2" resume_dir="$3" tr_path="${4:-}"
  [ -f "$chat_path" ] || return 0
  [ -s "$chat_path" ] || return 0

  if [ -z "$tr_path" ]; then
    tr_path="$(find "$HOME/.claude/projects" -name "$sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
  fi

  local cname
  cname="$(resolve_cc_name "$sid" "$tr_path")"
  [ -n "$cname" ] || return 0

  local cur_base cur_name
  cur_base="$(basename "$chat_path")"
  cur_name="${cur_base% Chat.md}"
  # Our own collision suffix " (<sid8>)" / " (<sid8>-N)" is not a different name. Comparing
  # it raw renamed every turn, minting "(sid8-2)" ... "(sid8-10)" (harness-gaps 2026-10-12).
  local own="${sid%%-*}"
  case "$cur_name" in
    *" ($own)"|*" ($own-"[0-9]*")") cur_name="${cur_name% (*}" ;;
  esac
  [ "$cur_name" = "$cname" ] && return 0

  bash "$HOME/.claude/hooks/rename-topic.sh" "$resume_dir" "$cur_base" "$cname" >/dev/null 2>&1
}
