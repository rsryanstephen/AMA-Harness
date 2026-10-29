#!/usr/bin/env bash
# Stop hook, two independent jobs:
#   1. mirror_reply: mechanically mirror the model's already-generated reply text (and
#      any auto-compaction recap, prefixed "recap:") into the session chat log. NO new
#      text is generated here -- this just greps the transcript JSONL (already written
#      by Claude Code) for "text" content blocks in assistant turns, plus any
#      isCompactSummary:true entry, since the last Stop, and appends them verbatim.
#      tool_use/tool_result blocks are structurally excluded (no "text" field), so
#      code-edit and action events never appear here. Zero LLM tokens spent.
#   2. auto_commit_push: every session, whatever its cwd -- commit and push ~/.claude's own
#      repo (Claude-Config): tracked changes incl. the CLI's own settings.json rewrites, plus
#      new files this session wrote. Never other repos, never known-sensitive filenames.
#   3. auto_commit_push_harness: same auto-commit behavior as job 2, but for the
#      separate ama-claude-harness repo that skills/hooks/CLAUDE.md/harness-config.json
#      are symlinked from -- job 2 never sees changes there since they're gitignored in
#      ~/.claude itself. Ticket-gated (always <harnessEpicKey>, see commit-ticket skill).
#      Bleed-through guard is path+hash, not path alone -- see harness-edit-hash.sh
#      (PostToolUse) and the comment at this function's unstage loop.
# Jobs 2/3 must run even if job 1 has nothing to do, so job 1's early-exits are contained
# in a function (a `return` there doesn't end the whole script).
#
# Claude Code's own hook "timeout" doesn't reliably kill orphaned children (confirmed
# twice: GCM credential prompts stalling git push/pull, and slow-under-load stalls with
# no stuck process at all -- likely the same pipe-inheritance mechanism either way).
# Re-exec ourselves under a hard ceiling -- TERM at 25s, KILL 5s later -- so this hook
# can never again pin a turn for double-digit minutes, whichever subprocess is slow.
if [ -z "${ON_STOP_BOUNDED:-}" ]; then
  export ON_STOP_BOUNDED=1
  exec timeout -k 5 25 bash "${BASH_SOURCE[0]}" "$@"
fi
. "$HOME/.claude/hooks/lib-claude-paths.sh"
payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0
# Headless/`-p`/SDK invocation -- see on-prompt.sh's matching guard for the full
# rationale. No chat file was ever mirrored into for this session, so there's nothing to
# mirror, no name to sync, and no render to trigger.
source "${BASH_SOURCE[0]%/*}/lib-session-kind.sh"
session_is_headless "$tr_path" && exit 0
# Normalize to forward slashes so "$cwd/<name>" never mixes separators.
cwd="$(printf '%s' "$cwd" | tr '\134' '/')"
# .session-chatfiles is internal bookkeeping, never a legitimate session cwd -- if it
# shows up here, a stray `cd` (in an earlier tool call) leaked into Claude Code's own
# reported cwd. Confirmed twice; fall back to the parent dir rather than corrupt paths.
case "$cwd" in */.session-chatfiles) cwd="${cwd%/.session-chatfiles}" ;; esac

source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"

# Snapshot Claude Code's derived-placeholder session name (a "<dir>-<n>" name like
# "exporterplus-37" when the user hasn't explicitly renamed -- NOT the AI-generated
# title, which lives in the transcript as "aiTitle" and is read directly by
# lib-fallback-rename.sh instead). This "name" field lives only in
# ~/.claude/sessions/<pid>.json, which vanishes when the session exits -- so a
# crashed/killed session would have nothing for lib-fallback-rename.sh to fall back
# to if the transcript somehow has no aiTitle either. Capture every turn end while the
# session is still alive; latest wins.
cname="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .name // empty' "$HOME/.claude/sessions"/*.json 2>/dev/null | head -1)"
[ -n "$cname" ] && printf '%s' "$cname" > "$HOME/.claude/.session-chatfiles/$sid.claudename" 2>/dev/null

# Real `--resume <name>` handle: prefer "customTitle" (user-set via /rename, `-n`, or
# Ctrl+R), else fall back to "agentName" (plan-accept's auto-derived name). The CLI docs
# say only an explicit name resumes directly and an AI title doesn't -- empirically false
# for plan-accept's agentName specifically: two separate agentName-only sessions (no
# customTitle at all) both confirmed to resume directly by hand
# ("fix-scrollbar-rendering-bug", "fix-duplicate-user-500-error"), so agentName is treated
# as valid here too.
# Also snapshot "aiTitle" (Claude Code's auto-generated title, distinct from customTitle/
# agentName above) into .aititle, and "customTitle" ON ITS OWN into .customtitle.
# Why .customtitle exists separately when .explicitname already prefers customTitle: those
# two are NOT interchangeable. .explicitname deliberately conflates customTitle with
# agentName because for a --resume handle either works. .customtitle answers a narrower
# question for on-prompt.sh's /rename nudge below: "has the USER already set a name?" --
# an agentName is Claude-assigned too, so it must NOT suppress that nudge the way a real
# customTitle should. Conflated into .explicitname, that distinction is unrecoverable --
# hence the third file.
# All three live as in-band metadata lines in the transcript itself (append-only, latest
# wins), not a separate index -- ONE grep pass for all three, not jq: this file can reach
# ~88MB and a full jq pass for one tail value is far slower, and a second/third grep pass
# would double/triple that cost every turn.
STATED="$HOME/.claude/.session-chatfiles"
_keys="$(grep -oh '"aiTitle":"[^"]*"\|"customTitle":"[^"]*"\|"agentName":"[^"]*"' "$tr_path" 2>/dev/null)"
aititle="$(printf '%s\n' "$_keys" | grep '^"aiTitle"' | tail -1 | sed 's/.*:"//;s/"$//')"
customtitle="$(printf '%s\n' "$_keys" | grep '^"customTitle"' | tail -1 | sed 's/.*:"//;s/"$//')"
ctitle="$customtitle"
[ -z "$ctitle" ] && ctitle="$(printf '%s\n' "$_keys" | grep '^"agentName"' | tail -1 | sed 's/.*:"//;s/"$//')"
prev_ctitle="$(cat "$STATED/$sid.explicitname" 2>/dev/null)"
prev_aititle="$(cat "$STATED/$sid.aititle" 2>/dev/null)"
prev_customtitle="$(cat "$STATED/$sid.customtitle" 2>/dev/null)"
[ -n "$ctitle" ] && printf '%s' "$ctitle" > "$STATED/$sid.explicitname" 2>/dev/null
[ -n "$aititle" ] && printf '%s' "$aititle" > "$STATED/$sid.aititle" 2>/dev/null
[ -n "$customtitle" ] && printf '%s' "$customtitle" > "$STATED/$sid.customtitle" 2>/dev/null
# session-ctx-sizes.pl's render is only ever CALLED after sessions.txt's own writers
# (on-prompt.sh/rename-topic.sh/relocate-session.sh) -- nothing renders when THESE
# change. Confirmed real gap: a name captured here lands in sessions.md only at the
# NEXT session's next on-prompt render, or never at all on a session's final turn (no
# next prompt to trigger it). Re-render here too, but only when something actually
# changed -- a no-op after the first turn that establishes a name, so this adds no
# per-turn cost in the steady state.
name_changed=0
if [ "$ctitle" != "$prev_ctitle" ] || [ "$aititle" != "$prev_aititle" ] \
   || [ "$customtitle" != "$prev_customtitle" ]; then
  name_changed=1
  bash "$(dirname "${BASH_SOURCE[0]}")/render-sessions-md.sh" 2>/dev/null || true
fi

mirror_reply() {
  [ -f "$tr_path" ] || return 0

  STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"; OFF="$STATED/$sid.stopoffset"
  default="$(chatfile_default_path "$cwd" "$sid")"
  if [ -f "$SF" ]; then CHAT="$(cat "$SF")"; else CHAT="$default"; fi

  # Wait for the transcript to stop growing before trusting its length. Stop can fire
  # right after the final assistant write, before that write is fully flushed to disk --
  # reading `wc -l` too early sees a stale (too-small) count, the guard below silently
  # exits, and the final text is permanently skipped (confirmed via a real incident:
  # hook ran successfully with 0 errors, but the last summary never made it to the log).
  total="$(wc -l < "$tr_path" | tr -d ' ')"
  for _ in 1 2 3; do
    sleep 0.2
    now="$(wc -l < "$tr_path" | tr -d ' ')"
    [ "$now" = "$total" ] && break
    total="$now"
  done

  last="0"; [ -f "$OFF" ] && last="$(cat "$OFF")"
  [ "$last" -lt "$total" ] || return 0

  # Reply text (unchanged): assistant "text" content blocks only, joined "\n\n" (pieces
  # within one reply, not separate blocks).
  slice="$(tail -n +"$((last + 1))" "$tr_path")"
  # tr -d '\r' strips CRLF-translation jq.exe applies to embedded newlines on Windows --
  # left in, it corrupts "---" dividers built from jq's own join() (found via local
  # testing: two recaps in one batch got an unmatchable "---\r" divider between them).
  reply_text="$(printf '%s' "$slice" | jq -s -r '
    [.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text]
    | join("\n\n")
  ' 2>/dev/null | tr -d '\r')"

  # Also mirror two Claude-Code-generated recap types, both prefixed "recap:" per the
  # user's request, zero tokens (plain text already generated by Claude Code, not by the
  # model here):
  #   - away_summary: a "system"-typed entry (subtype:"away_summary", plain .content)
  #     shown in the CLI as the short "recap:" bullet after idle periods -- confirmed via
  #     a real incident where this is what the user meant by "recap" (an EARLIER fix
  #     targeted isCompactSummary instead, which is a much longer, unrelated context-
  #     compaction summary -- kept below too since it's still worth logging).
  #   - isCompactSummary: a "user"-typed entry with isCompactSummary:true, plain-string
  #     .message.content, injected whenever context gets compacted.
  # Joined with a REAL "---" divider (own block), not "\n\n" -- confirmed via a real
  # incident that fusing it into the same block as the reply text made it unstrippable
  # by on-prompt.sh's next-prompt cleanup (which operates on whole blocks).
  recap_text="$(printf '%s' "$slice" | jq -s -r '
    [.[] |
      if (.type=="system" and .subtype=="away_summary") then ("recap:\n\n" + (.content // ""))
      elif (.type=="user" and .isCompactSummary==true) then ("recap:\n\n" + (.message.content // ""))
      else empty end
    ] | join("\n\n---\n\n")
  ' 2>/dev/null | tr -d '\r')"

  if [ -n "$reply_text" ] && [ -n "$recap_text" ]; then
    text="$reply_text
---

$recap_text"
  elif [ -n "$recap_text" ]; then
    text="$recap_text"
  else
    text="$reply_text"
  fi

  mkdir -p "$STATED" 2>/dev/null
  printf '%s' "$total" > "$OFF"
  [ -n "$text" ] || return 0

  if [ -s "$CHAT" ]; then printf '\n---\n\n%s\n' "$text" >> "$CHAT"; else printf '%s\n' "$text" >> "$CHAT"; fi
}

# Heuristic backstop for commit-ticket/SKILL.md's "found an issue along the way" rule --
# self-recognition alone missed it once (a reply flagged something "out of scope for this
# ticket" and never ticketed it, never asked). Narrow on purpose: only this literal phrase
# (broader wording like "out of scope" alone appears constantly in correctly-scoped asides
# and would false-positive relentlessly), and only when no ticket/task reference sits in
# the same paragraph -- if one's already named, it's tracked, not a naked flag. Can't
# block (Stop decisions are non-functional here, see CLAUDE.md), so it appends to
# harness-gaps.md and rides its existing on-prompt.sh surfacing -- zero changes needed
# there since the line shape ("- [session ...") is identical, just semantically two
# categories in one file now (see the file's own header).
#
# Confirmed real false positive on its own first day: a reply explaining THIS feature
# quoted the phrase (backtick+quote-wrapped, e.g. `"out of scope for this ticket"`) as a
# mention, not a real flag, and still got appended. Excludes a backtick (optionally
# followed by a quote) immediately before the phrase -- that shape is how this harness's
# own writing convention denotes "the literal term", not a live finding.
check_unticketed_flag() {
  [ -n "${text:-}" ] || return 0
  printf '%s\n\n' "$text" | awk '
    BEGIN { para="" }
    /^[[:space:]]*$/ { if (para != "") { print para; print "\x01" }; para=""; next }
    { para = (para=="" ? $0 : para " " $0) }
  ' | awk -v RS='\x01' '
    tolower($0) ~ /out of scope for this ticket/ &&
    tolower($0) !~ /`"?out of scope for this ticket/ &&
    $0 !~ /PROJ-[0-9]+/ && $0 !~ /task #[0-9]+/ { print; exit }
  ' | {
    read -r -d '' para || true
    [ -n "$para" ] || return 0
    snippet="$(printf '%s' "$para" | cut -c1-200)"
    printf -- '- [session %s, %s] UNTICKETED FLAG: "%s..." -- "out of scope for this ticket" with no PROJ-#/task # nearby. Resolve: ticket it, or confirm not needed.\n' \
      "${sid%%-*}" "$(date +%Y-%m-%d)" "$snippet" >> "$HOME/.claude/harness-gaps.md"
  }
}

# Confirmed real incident: a bare `git push`/`pull --rebase` here hung a whole turn for
# ~10 minutes. Root cause -- both remotes are HTTPS with credential.helper=manager; when
# Git Credential Manager decides to prompt (stale/missing cached credential), it spawns a
# SEPARATE child process that inherits this hook's stdout/stderr pipes. Claude Code kills
# the parent bash at its own configured hook timeout, but the orphaned GCM child keeps the
# pipe open, so Claude Code never sees EOF -- the turn just sits there, invisibly (stderr
# was already redirected to /dev/null). GIT_TERMINAL_PROMPT=0 makes git refuse to prompt
# and fail fast instead; GCM_INTERACTIVE=never is belt-and-suspenders directly on GCM.
# `timeout 15` is defense in depth against a stalled TCP connection, a different failure
# mode than an interactive prompt -- neither guard alone covers both cases.
_safe_push_pull_retry() {
  local dir="$1"
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never timeout 15 git -C "$dir" push -q 2>/dev/null; then
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never timeout 15 git -C "$dir" pull -q --rebase 2>/dev/null \
      && GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never timeout 15 git -C "$dir" push -q 2>/dev/null
  fi
}

# <harnessEpicKey>: the auto-commit path had NO scrub check. publish-scrub-gate.sh guards
# MODEL-driven `git commit` calls (PreToolUse/Bash), but this function commits by itself,
# in-process, so that gate never sees it -- and the staging exclusions here are
# NAME-based (*secret*, *token*), which a file called `aws-access-notes.md` sails past.
# Confirmed live 2026-08-27: a fake-credentials demo prop written by the Write tool was
# auto-committed and pushed to the private Bitbucket remote. The public mirror refused it
# (publish_public_mirror's own gate), so nothing leaked -- but the mirror then stays stuck
# until a human notices, which is exactly the silent breakage this repo already fixed once
# for the model path. Same tool, same scrub map, no duplicated rules: unstage the offending
# paths and leave the rest of the commit intact (dropping ONLY the bad file keeps the
# harness moving; aborting the whole auto-commit would wedge every later turn too).
_unstage_scrub_failures() {
  local repo="$1" out bad f staged
  staged="$(git -C "$repo" diff --cached --name-only 2>/dev/null | tr -d '' | sed '/^$/d')"
  [ -n "$staged" ] || return 0
  [ -f "$repo/scripts/publish-public.sh" ] || return 0
  out="$(printf '%s
' "$staged" | xargs -d '
' -r bash "$repo/scripts/publish-public.sh" --check-paths 2>&1)" && return 0
  # `<repo-relative path>:<line>:<text>` is the gate's own output shape (publish-scrub-gate.sh
  # explains the same format to the model in its deny reason).
  bad="$(printf '%s
' "$out" | grep -oP '^[^:]+(?=:[0-9]+:)' | sort -u)"
  [ -n "$bad" ] || return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    git -C "$repo" reset -q -- "$f" 2>/dev/null
    printf -- '- [session %s, %s] Auto-commit refused to stage `%s` -- carries a scripts/public-scrub-gate.txt forbidden token and would abort the public mirror. Left uncommitted in the working tree; map the literal in scripts/public-scrub-map.txt or remove it.
'       "${sid%%-*}" "$(date +%F)" "$f" >> "$HOME/.claude/harness-gaps.md" 2>/dev/null
  done <<< "$bad"
}

# Fires right after the harness repo is confirmed pushed to Bitbucket (both
# auto_commit_push_harness call sites below) -- keeps the public GitHub mirror
# (scripts/publish-public.sh) from ever needing a human to remember it. Sha-marker
# gated so a quiet Stop (nothing new) is a true no-op, not a re-scrub-and-force-push.
publish_public_mirror() {
  local harness="$1" head upstream marker last
  head="$(git -C "$harness" rev-parse HEAD 2>/dev/null)"
  upstream="$(git -C "$harness" rev-parse '@{u}' 2>/dev/null)"
  # Only publish a commit CONFIRMED pushed to Bitbucket -- if push/pull-rebase both
  # failed above (offline, conflict), HEAD != upstream and this silently skips; the
  # harness commit stays local either way, same as before this function existed.
  [ -n "$head" ] && [ "$head" = "$upstream" ] || return 0

  marker="$(hstate harness .harness-last-published-sha)"
  last=""; [ -f "$marker" ] && IFS= read -r last < "$marker"
  [ "$head" != "$last" ] || return 0    # already published this exact commit

  # A publish unpacks, rewrites and re-commits ~550 files in %TEMP%, every one scanned by
  # Defender (IT's MDE data, 2026-10-14: tar/perl/git top this machine's file events). So it
  # waits until this is the only live session (at most hourly), or a day has passed. The
  # stamp counts attempts, so a failing publish no longer retries on every pushed commit.
  local stamp age=999999
  stamp="$(hstate harness .harness-publish-attempt)"
  [ -f "$stamp" ] && age=$(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 86400 ]; then
    [ "$age" -ge 3600 ] || return 0
    . "$HOME/.claude/hooks/lib-session-liveness.sh"
    [ "$(live_session_count 600)" -le 1 ] || return 0
  fi
  touch "$stamp"

  local publog; publog="$(hstate harness .harness-publish-public.log)"
  # Detached (headless-prune-check.sh's pattern): a publish, ~300 `bash -n` forks included,
  # can outlast this hook's 30s Stop timeout, which kills it with no marker and no gaps line.
  {
    if nohup timeout 300 bash "$harness/scripts/publish-public.sh" > "$publog" 2>&1; then
      printf '%s' "$head" > "$marker"
    else
      # Never fail/block Stop over a GitHub outage -- record per CLAUDE.md's harness-gap
      # convention instead, so a failed auto-publish isn't silently lost forever.
      printf -- '- [session %s, %s] Auto-publish to public GitHub mirror FAILED for %s -- see ~/.claude/harness-state/harness/.harness-publish-public.log; re-run scripts/publish-public.sh by hand.\n' \
        "${sid%%-*}" "$(date +%F)" "$head" >> "$HOME/.claude/harness-gaps.md" 2>/dev/null
    fi
  } < /dev/null > /dev/null 2>&1 &
  disown 2>/dev/null || true
}

auto_commit_push() {
  # Claude-Config: ~/.claude's own repo (private GitHub remote). Everything harness-shaped in it
  # is gitignored (hooks/, skills/, CLAUDE.md... -- auto_commit_push_harness owns those), so what
  # is left is Claude Code's own config plus a few notes. Runs whatever the session cwd
  # (2026-10-28): the old "cwd under ~/.claude" scope matched no session from mid-Sept, and its
  # own-paths filter dropped every change the CLI makes itself -- /config, plugin toggles,
  # "always allow" all rewrite settings.json with no Write/Edit call to own them. Six weeks of
  # settings.json went unpushed. The hooks/skills ticket gate went too: both are ignored here.
  local root root_lc f lc rel cands
  root="$(git -C "$HOME/.claude" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] || return 0
  root_lc="$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')"

  # Candidates: every change to a file already in HEAD, whoever made it (mostly the CLI -- there
  # is no owner to check), plus a NEW file only when this session's Write/Edit/NotebookEdit made
  # it and git does not ignore it. A new file another session staged is neither, so it stays
  # put. Transcript paths are Windows-form ("C:\..."), same as rev-parse's root.
  cands="$(git -C "$root" diff HEAD --name-only --no-renames --diff-filter=MDT 2>/dev/null)"
  if [ -f "$tr_path" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      f="$(printf '%s' "$f" | tr '\134' '/')"
      lc="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
      case "$lc" in "$root_lc"/*) rel="${f:${#root}+1}" ;; *) continue ;; esac
      [ -e "$root/$rel" ] || continue
      git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null && continue   # already a candidate
      # Exit 1 = not ignored. 0 = ignored; 128 = path runs through the hooks/ or skills/ junction.
      git -C "$root" check-ignore -q -- "$rel" >/dev/null 2>&1; [ $? -eq 1 ] || continue
      cands="$cands
$rel"
    done <<< "$(jq -r '.message.content[]? | select(.type=="tool_use") |
        select(.name=="Write" or .name=="Edit" or .name=="NotebookEdit") |
        .input.file_path // empty' "$tr_path" 2>/dev/null | tr -d '\r' | sort -u)"   # jq.exe ends lines CRLF
  fi

  local keep=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in .credentials.json|.env|.env.*|*secret*|*token*) continue ;; esac
    # The CLI may be mid-rewrite of its own JSON -- the next Stop takes it once it parses.
    case "$rel" in *.json) [ ! -e "$root/$rel" ] || jq empty "$root/$rel" >/dev/null 2>&1 || continue ;; esac
    keep+=("$rel")
  done <<< "$cands"

  if [ "${#keep[@]}" -eq 0 ]; then
    # Nothing new -- but an earlier Stop may have committed and then lost its push. Don't strand it.
    [ "$(git -C "$root" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" -gt 0 ] || return 0
  else
    # Pathspec commit: these paths only, so whatever a concurrent session has staged in the
    # shared index never rides along (the `add -A` sweep auto_commit_push_harness dropped).
    git -C "$root" add -A -- "${keep[@]}" 2>/dev/null
    git -C "$root" commit -q -m "Auto-commit: ~/.claude sync at session ${sid%%-*} stop" -- "${keep[@]}" >/dev/null 2>&1 || return 0
  fi
  # Detached, publish_public_mirror's pattern: a slow GitHub push (up to 3 x 15s) must not eat
  # the 25s ceiling that auto_commit_push_harness still needs for its Bitbucket push.
  { _safe_push_pull_retry "$root"; } < /dev/null > /dev/null 2>&1 &
  disown 2>/dev/null || true
}

check_queue_block() {
  # Mechanically dequeue the next queued item (marker: 1-2 hyphens, optional space,
  # Q/q -- "-- Q", "--Q", "-Q", "- Q", "-- q", "- q", "-q") the instant this turn
  # finishes, so the file's own state is correct immediately rather than waiting on
  # the next prompt.
  #
  # This USED to return decision:"block" to try to force the model to keep going.
  # Confirmed real, this session: decision:"block" from a Stop hook has never once
  # actually worked -- preventedContinuation is false on every real stop_hook_summary
  # transcript entry all session, hookAdditionalContext always empty, the reason text
  # only ever lands in hookErrors, never as model-visible input. A hook's own bash
  # logic runs regardless of whether Claude Code honors its JSON output, though -- so
  # the actual file mutation below still works even though "block" never did. The
  # model-visible half of this now lives in on-prompt.sh's injected context (the one
  # channel proven reliable this session), which reports what got dequeued here on
  # the NEXT prompt and is also a fallback dequeue if this hook didn't run at all
  # (crash, killed session). No dedup/hash tracking needed anymore -- this is a plain
  # idempotent mutation, not a decision the model could get stuck repeating.
  STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"
  default="$(chatfile_default_path "$cwd" "$sid")"
  if [ -f "$SF" ]; then CHAT="$(cat "$SF")"; else CHAT="$default"; fi
  [ -f "$CHAT" ] || return 0
  grep -qE '^-{1,2}[[:space:]]?[Qq][[:space:]]*$' "$CHAT" 2>/dev/null || return 0

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$SCRIPT_DIR/dequeue-prompt.sh" "$CHAT" >/dev/null 2>&1
}

auto_commit_push_harness() {
  # PROJ-15200: skills/, hooks/, CLAUDE.md, harness-config.json moved to their own
  # repo (ama-claude-harness) and are junctioned/symlinked back into ~/.claude. That
  # means auto_commit_push above never sees them -- they're gitignored in THIS repo,
  # tracked in a different one it never touches. This mirrors auto_commit_push's logic
  # (stage, drop other sessions' uncommitted bleed-through, ticket-gate, commit, push)
  # but scoped to the harness repo instead. Runs regardless of session cwd -- a session
  # working in an AMA_APP repo can still edit a skill/hook by absolute path.
  # PROJ-15203: harness-config.json is itself a shared, symlinked file, identical
  # for every adopter -- a per-adopter clone path can never correctly live inside it (was
  # tried as `paths.harnessRepo`, dropped). Resolve via git instead: it follows the
  # skills/ junction straight through to wherever THIS adopter actually cloned the repo,
  # correct regardless of clone location, no config needed.
  harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$harness" ] && [ -d "$harness" ] || return 0
  git -C "$harness" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [ -f "$tr_path" ] || return 0

  # Canonicalize both roots through `git rev-parse --show-toplevel` rather than trusting
  # $HOME/the config string's own form. CONFIRMED REAL BUG in an earlier version of this
  # function: $HOME is POSIX-drive form ("/c/Users/...") in git-bash, but Claude Code's
  # own tool_use file_path values (and this git's own rev-parse output) are Windows-drive
  # form ("C:/Users/...") -- comparing POSIX-built prefixes against Windows-form paths
  # silently never matched, so the check never fired. rev-parse gives both roots in the
  # same form the transcript paths are already in, no manual conversion needed.
  harness="$(git -C "$harness" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$harness" ] || return 0
  claude_root="$(git -C "$HOME/.claude" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$claude_root" ] || claude_root="$HOME/.claude"

  norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'; }
  harness_lc="$(norm "$harness")"
  skills_lc="$(norm "$claude_root/skills")"
  hooks_lc="$(norm "$claude_root/hooks")"
  claudemd_lc="$(norm "$claude_root/CLAUDE.md")"
  config_lc="$(norm "$claude_root/harness-config.json")"

  # This session's own touched files, translated from the ~/.claude symlink side to
  # harness-repo-relative paths (skills_lc/hooks_lc -> harness/skills, harness/hooks;
  # claudemd_lc/config_lc -> harness's own CLAUDE.md/harness-config.json). Anything
  # outside these four paths didn't touch the harness repo, so it's dropped here.
  own_paths=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    f_lc="$(norm "$f")"
    case "$f_lc" in
      "$skills_lc"/*) rel="skills${f_lc#"$skills_lc"}" ;;
      "$hooks_lc"/*) rel="hooks${f_lc#"$hooks_lc"}" ;;
      "$claudemd_lc") rel="claude.md" ;;
      "$config_lc") rel="harness-config.json" ;;
      "$harness_lc"/*) rel="${f_lc#"$harness_lc"/}" ;;
      *) continue ;;
    esac
    own_paths="$own_paths
$rel"
  done <<< "$(jq -r '.message.content[]? | select(.type=="tool_use") |
      select(.name=="Write" or .name=="Edit" or .name=="NotebookEdit") |
      .input.file_path // empty' "$tr_path" 2>/dev/null)"
  [ -n "$own_paths" ] || return 0

  # Stage ONLY this session's own paths (2026-08-21: `add -A` then unstage-the-rest still swept
  # a concurrent session's half-applied on-prompt.sh onto master, and nearly committed 19 real
  # chat-log symlinks before Local Chat Files/ was gitignored -- the unstage loop below is a
  # backstop, not a fence). Same sensitive-file exclusions as auto_commit_push. A path that no
  # longer exists (deleted this session) is staged as a deletion by `add -A -- <path>`.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in .credentials.json|.env|.env.*|*secret*|*token*) continue ;; esac
    git -C "$harness" add -A -- ":(icase)$rel" 2>/dev/null   # own_paths are lowercase-normalised
  done <<< "$own_paths"

  # Cross-session bleed-through guard: unstage anything this session didn't itself
  # touch, OR touched but no longer matches -- own_paths alone is a path allowlist, and
  # a path this session legitimately edited earlier in the SAME session stays allowed
  # even after a DIFFERENT session overwrites it before this Stop fires -- this once
  # committed 3 files a concurrent session had just edited, under its own message,
  # purely because the paths were still in own_paths.
  # harness-edit-hash.sh (PostToolUse) records this session's own sha256 per rel path in
  # .harnesshashes -- require BOTH path membership and a matching current hash. No
  # recorded hash for an own_paths entry (sidecar predates this fix, or lookup failed)
  # -> treat as mismatch and unstage; failing closed here just defers one commit,
  # failing open is the bug. Net effect: whoever's Stop fires LAST with a matching hash
  # is the one that commits a contested file -- correct, since that's the most current
  # content. A file A edits then never stops again on, until B's Stop -- stays
  # uncommitted till then; a real but small window, not a defect.
  HASHFILE="$HOME/.claude/.session-chatfiles/$sid.harnesshashes"
  [ -f "$HASHFILE" ] || HASHFILE=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    f_lc="$(norm "$f")"
    if printf '%s\n' "$own_paths" | grep -qxF "$f_lc"; then
      # $f is already harness-repo-relative (git diff --cached --name-only's own
      # form); f_lc is its lowercase/forward-slash norm() -- same shape harness-edit-
      # hash.sh writes as `rel`, so it's the direct lookup key, no further translation.
      cur_hash="$(sha256sum "$harness/$f" 2>/dev/null | cut -d' ' -f1)"
      cur_hash="${cur_hash#\\}"  # see harness-edit-hash.sh's note on sha256sum's backslash-escape mode
      rec_hash=""
      [ -n "$HASHFILE" ] && rec_hash="$(grep -P "^\Q$f_lc\E\t" "$HASHFILE" 2>/dev/null | tail -1 | cut -f2)"
      [ -n "$cur_hash" ] && [ "$cur_hash" = "$rec_hash" ] || git -C "$harness" reset -q -- "$f" 2>/dev/null
    else
      git -C "$harness" reset -q -- "$f" 2>/dev/null
    fi
  done <<< "$(git -C "$harness" diff --cached --name-only 2>/dev/null)"

  # Same single-call pattern as auto_commit_push above: one post-loop `diff --cached` for the
  # emptiness test, reused as `dirty` further down instead of a second call.
  _unstage_scrub_failures "$harness"
  harness_staged="$(git -C "$harness" diff --cached --name-only 2>/dev/null)"
  if [ -z "$harness_staged" ]; then
    if [ "$(git -C "$harness" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" -gt 0 ]; then
      _safe_push_pull_retry "$harness"
      publish_public_mirror "$harness"
    fi
    return 0
  fi

  # Same ticket gate as auto_commit_push's hooks/skills check -- harness content is
  # ENTIRELY hooks/skills-shaped, so it's unconditional here (see commit-ticket skill's
  # "Harness work" section: always <harnessEpicKey>, never a new sub-ticket).
  STATED="$HOME/.claude/.session-chatfiles"; TF="$STATED/$sid.ticket"
  ticket=""; [ -f "$TF" ] && ticket="$(cat "$TF")"
  if [ -z "$ticket" ]; then
    BF="$STATED/$sid.harnessblocked"
    dirty="$harness_staged"   # computed once above, right after the reset loop
    shash="$(printf '%s' "$dirty" | md5sum 2>/dev/null | cut -d' ' -f1)"
    last=""; [ -f "$BF" ] && last="$(cat "$BF")"
    [ "$shash" = "$last" ] && return 0
    mkdir -p "$STATED" 2>/dev/null
    printf '%s' "$shash" > "$BF"
    jq -cn --arg h "$harness" '{decision:"block",reason:("Staged changes touch the harness repo (" + $h + ") but no ticket is resolved for this session yet. Per the commit-ticket skill: harness work always commits against <harnessEpicKey> -- run `bash \"$HOME/.claude/hooks/set-session-ticket.sh\" \"<cwd>\" \"<chat file>\" <harnessEpicKey>` before this can auto-commit. Nothing has been committed yet -- changes remain staged.")}'
    exit 0
  fi

  # Hardcoded, NOT $ticket -- this function only ever commits the harness repo, whose
  # content is entirely hooks/skills-shaped, so the prefix is always <harnessEpicKey>
  # regardless of what the session's own active work ticket happens to be -- a session
  # working another ticket elsewhere once got its harness-doc edit auto-committed under
  # that other ticket's prefix. $ticket here is the session's
  # OWN ticket (still needed above just to gate that SOME ticket got resolved first),
  # not what the commit message should say.
  msg="<harnessEpicKey>: Auto-commit: session ${sid%%-*} changes"
  git -C "$harness" commit -q -m "$msg" 2>/dev/null

  _safe_push_pull_retry "$harness"
  publish_public_mirror "$harness"
}

# One-name-per-session: keep the chat file following Claude Code's OWN name for this
# session, live, EVERY time it changes -- not just once at exit. Gated on
# $name_changed (set above) so this is a no-op on the steady-state turn where nothing
# moved; sync_session_name's own basename check is the real idempotence guarantee if
# that gate is ever wrong. Runs last, after mirror_reply's transcript-settle loop
# above, so aiTitle is read post-settle (maximizes the chance it's on disk this turn)
# and so no job above sees the chat-path mutation mid-run.
sync_session_name_now() {
  [ "$name_changed" = 1 ] || return 0
  STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"
  default="$(chatfile_default_path "$cwd" "$sid")"
  local chat; if [ -f "$SF" ]; then chat="$(cat "$SF")"; else chat="$default"; fi
  source "$(dirname "${BASH_SOURCE[0]}")/lib-fallback-rename.sh"
  sync_session_name "$sid" "$chat" "$(dirname "$chat")" "$tr_path"
}

# Template/live settings wiring drift (the harness-gaps 2026-08-11 entry's suggested
# gate): a hook wired in only one of settings.template.json / live ~/.claude/settings.json
# is either dead for this user or missing for a fresh adopter. Deduped by drift-content
# hash -- a standing drift nags once, not every Stop; statefile clears on parity.
check_settings_parity() {
  local harness drift PF h
  harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$harness" ] && [ -f "$harness/scripts/check-settings-parity.sh" ] || return 0
  drift="$(bash "$harness/scripts/check-settings-parity.sh" "$harness" 2>/dev/null)"
  PF="$(hstate harness .settings-parity-last)"
  if [ -z "$drift" ]; then rm -f "$PF" 2>/dev/null; return 0; fi
  h="$(printf '%s' "$drift" | md5sum | cut -d' ' -f1)"
  [ -f "$PF" ] && [ "$(cat "$PF")" = "$h" ] && return 0
  printf '%s' "$h" > "$PF"
  printf -- '- [session %s, %s] settings.template.json vs live settings.json hook wiring drift: %s\n' \
    "${sid%%-*}" "$(date +%F)" "$(printf '%s' "$drift" | tr '\n' ';')" >> "$HOME/.claude/harness-gaps.md"
}

# Shared session names (/compact-continue, fork, bare /clear copy a name into a new sid):
# scripts/session-name-dedupe.pl renames the IDLE holders. Hourly at most, detached --
# each rename re-renders sessions.md (~30s), far past this hook's Stop timeout.
dedupe_session_names() {
  local harness stamp age=999999
  harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$harness" ] && [ -f "$harness/scripts/session-name-dedupe.pl" ] || return 0
  command -v perl >/dev/null 2>&1 || return 0
  stamp="$(hstate sessions .name-dedupe-last)"
  [ -f "$stamp" ] && age=$(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))
  [ "$age" -ge 3600 ] || return 0
  touch "$stamp"
  { nohup timeout 1800 perl "$harness/scripts/session-name-dedupe.pl" > "$(hstate sessions .name-dedupe.log)" 2>&1; } \
    < /dev/null > /dev/null 2>&1 &
  disown 2>/dev/null || true
}

mirror_reply
check_unticketed_flag
dedupe_session_names
auto_commit_push
auto_commit_push_harness
check_settings_parity
check_queue_block
sync_session_name_now
exit 0
