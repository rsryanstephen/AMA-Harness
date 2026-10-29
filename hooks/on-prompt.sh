#!/usr/bin/env bash
# UserPromptSubmit hook (single). The per-session chat log path is tracked in
# ~/.claude/.session-chatfiles/<session_id>. Behavior:
#   * Pointer prompt ("see ... prompt in <name> Chat.md"): YOU named the file — record
#     that "<name> Chat.md" as this session's log; do NOT stream the pointer text.
#   * Real prompt: append it to the current log file. Fallback name when none chosen yet:
#     "<folder>-<shortid> Chat.md" in the cwd.
#   * Backfill the log's name as the <topic> in the sessions.txt master line (first time).
#   * Inject the current log filename so the model appends its commentary to the same file.
# Only the final jq line writes to stdout.
payload="$(cat)"
printf '%s' "$payload" > "${TMPDIR:-/tmp}/claude-ups-last-payload.json" 2>/dev/null || true
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
prompt="$(printf '%s' "$payload" | jq -r '.prompt // .user_prompt // .message // .text // empty')"
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0
# Headless/`-p`/SDK invocation (every harness unattended scheduled run: standup-notes,
# support-notices, embs-notices, team-meeting-notes) -- Claude Code stamps this on the
# transcript's own first real user-message line, no per-script cooperation needed. These
# never get a chat file or a sessions.txt row -- the user never started or wants to see
# them (confirmed real: they cluttered sessions.md with unnamed "ama-claude-harness-NN"
# rows once a prior fix gave them a writable cwd instead of failing silently in System32).
# A real interactive terminal session has "entrypoint":"cli" instead. Detection itself is
# in lib-session-kind.sh -- the `head -c 4000` window this line used to carry never
# contained the field, so this guard silently never fired once (measurements in that file).
source "${BASH_SOURCE[0]%/*}/lib-session-kind.sh"
if session_is_headless "$tr_path"; then
  # Zero trace, not merely an invisible row. log-session-start.sh:38-50 already wrote this
  # session's statefile and a DANGLING "Local Chat Files/<shortid> Chat.md" symlink before
  # any prompt existed -- it cannot know the session's kind that early, because the
  # entrypoint field only lands with the first user message. Skipping the append below is
  # exactly what leaves that symlink dangling forever, so undo it here, at the first moment
  # the kind IS knowable. Only ever unlinks a symlink whose target does not exist; a real
  # chat file is never touched.
  _hk_sf="$HOME/.claude/.session-chatfiles/$sid"
  if [ -f "$_hk_sf" ]; then
    _hk_chat="$(cat "$_hk_sf" 2>/dev/null)"
    if [ -n "$_hk_chat" ] && [ -L "$_hk_chat" ] && [ ! -e "$_hk_chat" ]; then rm -f "$_hk_chat"; fi
  fi
  rm -f "$_hk_sf" "$_hk_sf".aititle "$_hk_sf".claudename "$_hk_sf".explicitname         "$_hk_sf".namesync "$_hk_sf".entrypoint
  exit 0
fi
# Normalize to forward slashes so "$cwd/<name>" never mixes separators.
cwd="${cwd//\\//}"
# .session-chatfiles is internal bookkeeping, never a legitimate session cwd -- if it
# shows up here, a stray `cd` (in an earlier tool call) leaked into Claude Code's own
# reported cwd. Confirmed twice; fall back to the parent dir rather than corrupt paths.
case "$cwd" in */.session-chatfiles) cwd="${cwd%/.session-chatfiles}" ;; esac

# Computed ONCE -- $(dirname "${BASH_SOURCE[0]}") used to be re-forked at every source/
# child-call site (6 forks for one constant value, ~60ms each on this machine). Always
# absolute in practice: settings.json invokes this hook by full path.
HOOKS_DIR="${BASH_SOURCE[0]%/*}"

STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"
source "$HOOKS_DIR/lib-chatfile-link.sh"

# NOTE: an explicit-session-name capture used to live here, watching $prompt for a
# literal "/rename ..." string -- that was dead code. /rename is a client-side slash
# command; it never reaches this hook as prompt text (confirmed: grepping every
# transcript on this machine for a literal "/rename" line found zero, even though
# several sessions visibly have a real custom name). The real capture now lives in
# on-stop.sh, reading the transcript's own "customTitle" metadata line instead.

# Fallback name when no pointer names the file: just the short session id (no folder
# prefix — the folder is redundant with the project you're already in). Lives in
# "Local Chat Files/", not the cwd root (<harnessEpicKey> follow-up).
default="$(chatfile_default_path "$cwd" "$sid")"
# `read` not $(cat) -- statefiles have no trailing newline, so read exits 1 while still
# populating the variable (see the claimed_paths loop's gotcha comment below).
if [ -f "$SF" ]; then CHAT=""; IFS= read -r CHAT < "$SF" 2>/dev/null || true; else CHAT="$default"; fi

# Relocation: if this session's recorded chat file lives in a DIFFERENT directory than
# the current cwd, that MIGHT mean the user just ran Claude Code's own `/cd <dir>` -- but
# NOT necessarily. Confirmed real incident (3rd occurrence): this same `.cwd` field also
# drifts from an ordinary bare `cd` left unreverted in a Bash tool call (persistent shell
# state, same mechanism, indistinguishable from cwd alone). A prior version of this
# comment wrongly assumed "cwd only changes mid-session via /cd" -- that assumption was
# the actual bug. Disambiguate structurally instead: a real `/cd` ALSO relocates Claude
# Code's own transcript to a new project folder (hash of the new cwd) -- a leaked bare
# `cd` never does. Only treat this as a genuine `/cd` if that transcript move already
# happened.
projhash() { printf '%s' "$1" | sed -E 's|[:/._]|-|g'; }
relocate_ctx=""
bare_adopt_ctx=""
badcd_ctx=""
rename_nudge_ctx=""
chat_cwd="$(chatfile_session_cwd "$CHAT")"
if [ -f "$SF" ] && [ "$chat_cwd" != "$cwd" ]; then
  if [ -f "$HOME/.claude/projects/$(projhash "$cwd")/$sid.jsonl" ]; then
    reloc_out="$(bash "$HOOKS_DIR/relocate-session.sh" "$sid" "$CHAT" "$cwd" 2>/dev/null)"
    new_chat="$(printf '%s\n' "$reloc_out" | sed -n 's/^NEWCHAT=//p')"
    resume_cmd="$(printf '%s\n' "$reloc_out" | sed -n 's/^RESUME=//p')"
    if [ -n "$new_chat" ]; then
      CHAT="$new_chat"
      relocate_ctx=" This session was just relocated (via /cd) -- its chat file, bookkeeping, and sessions.txt entry now point at $cwd. Mention this to the user and give them the new resume command: \`$resume_cmd\`."
    fi
  else
    # No matching transcript move -> this is a leaked bare `cd`, not a real /cd. Do NOT
    # relocate anything; warn so the model fixes its shell cwd before it drifts further.
    badcd_ctx=" Your shell's cwd ($cwd) no longer matches this session's actual working directory ($chat_cwd) -- that's a bare \`cd\` left unreverted in an earlier tool call, not a real /cd (confirmed: no matching Claude Code transcript relocation happened). This session's chat log was correctly NOT moved. cd back to $chat_cwd now, and going forward use (cd X && cmd) subshells instead of a bare cd, per CLAUDE.md."
  fi
fi

# One-time map of "chat file path -> claimed by a DIFFERENT session", read via bash
# builtins (parameter expansion + `read`) instead of forked basename/cat per file.
# Used below by both the named-pointer "claimed by other" check and the bare-pointer
# candidate scan, which previously each re-scanned this directory from scratch (the
# candidate scan even nested per-candidate -- O(candidates x files)) -- on a machine
# with pathological per-fork cost that alone timed out the whole 30s hook budget
# (confirmed real: measured >50s against a real 117-entry .session-chatfiles/).
declare -A claimed_paths
for sf in "$STATED"/*; do
  # Dotted-suffix skip: real sid statefiles never contain a dot, every bookkeeping
  # suffix does (.explicitname/.claudename/.readmenudge/.aititle/.customtitle/
  # .renamenudge) -- suffix lists drift, the structural check doesn't.
  case "${sf##*/}" in *.*) continue ;; esac
  [ -f "$sf" ] || continue
  other_sid="${sf##*/}"
  [ "$other_sid" = "$sid" ] && continue
  # `read`'s exit status is 1 on EOF-with-no-trailing-newline -- and every statefile IS
  # written that way (`printf '%s' "$CHAT" > "$SF"`, no `\n`) -- even though it still
  # populates the variable correctly. `read ... || continue` therefore silently dropped
  # the content of nearly every real statefile (confirmed: 63 of 67 candidates on this
  # machine's actual .session-chatfiles/). Check the variable's content after the read,
  # never the read command's own exit status.
  other_path=""
  IFS= read -r other_path < "$sf" 2>/dev/null
  [ -n "$other_path" ] && claimed_paths["$other_path"]=1
done

# pointer? Detected STRUCTURALLY by a backtick-quoted "...Chat.md" reference ANYWHERE
# in the prompt -- independent of wording ("see", "check", "prompt file in", "after the
# divider in", typos, etc). Phrase-matching was tried first and proved too brittle: real
# messages vary in wording and a dropped/rephrased word silently defeated it, causing the
# pointer text itself to be streamed as if it were a real prompt. A named file reference
# is a reliable, low-false-positive signal on its own.
# BUT: gate on overall message length. A genuine pointer is short ("See prompt in `X`",
# ~5-12 words); a longer discursive message (e.g. a bug report that merely QUOTES a
# filename as an example) can also contain a backtick Chat.md reference without meaning
# to repoint this session -- confirmed via a real incident where a bug report describing
# this exact hook, containing an example path in backticks, silently hijacked the
# session's own log file. Long messages fall through to being streamed as real content.
named="$(printf '%s' "$prompt" | grep -oE '`[^`]*Chat\.md`' | tail -1 | tr -d '`')"
# Word count in pure bash (was a 4-exec tr|tr|tr|grep chain): lowercase, squash every
# non-letter to a space, let word-splitting count the runs. set -- is safe here --
# this script takes no positional args (payload arrives on stdin).
_words="${prompt,,}"; _words="${_words//[!a-z]/ }"
set -- $_words
prompt_wc=$#
is_pointer=0
if [ -n "$named" ] && [ "$prompt_wc" -le 18 ]; then
  # Extra guard: if the referenced file is ALREADY another session's active log, this
  # is almost certainly a reference to its content ("do the same for `X`", "refer to
  # `X`"), not a genuine "adopt this as my log" pointer -- confirmed via a real incident
  # where a short message asking to reuse work from a NAMED past chat file hijacked the
  # CURRENT session's own log to that file instead. A real redirect pointer only makes
  # sense for a file this session doesn't already know is someone else's.
  case "$named" in /*|[A-Za-z]:[\\/]*) named_path="$named" ;; *) named_path="$(chatfile_resolve_named "$cwd" "$named")" ;; esac
  claimed_by_other=0
  [ -n "${claimed_paths[$named_path]:-}" ] && claimed_by_other=1
  [ "$claimed_by_other" = 0 ] && is_pointer=1
fi

# Fallback: a "bare" pointer with NO filename ("See latest prompt", "check the prompt
# above", etc.) has no structural signal to key off -- this is a best-effort keyword
# heuristic, not a reliable structural match like the backtick case above. It fires only
# when the ENTIRE message (after stripping filler words) is made of pointer-ish words and
# is short, to keep false positives on genuine short real prompts rare.
is_bare_pointer=0
if [ "$is_pointer" = 0 ] && [ -n "$prompt" ]; then
  # Same pure-bash lowercase/split as prompt_wc above (was 3 more execs). Counting
  # in-loop is equivalent to the old post-loop grep -c: the count is only ever USED
  # when all_pointerish stayed 1, i.e. when the loop ran to completion anyway.
  words="${prompt,,}"; words="${words//[!a-z]/ }"
  wc_count=0; all_pointerish=1
  for w in $words; do
    wc_count=$((wc_count + 1))
    case "$w" in
      a|an|the|in|at|to|for|on|of|is|are|was|were|it|its|that|this) continue ;;
      see|check|read|look|view|latest|prompt|prompts|file|files|chat|chats|log|logs|md|above|below|previous|next|again|refer|referring|reference|pointer) continue ;;
      pick|picking|up|address|addressing|process|processing|work|working|through|queue|queued|queues|item|items) continue ;;
      *) all_pointerish=0; break ;;
    esac
  done
  [ "$all_pointerish" = 1 ] && [ "$wc_count" -ge 1 ] && [ "$wc_count" -le 10 ] && is_bare_pointer=1
fi

# A message can be REAL content with a content-free pointer clause tacked on the end
# ("Let's keep it for now. See the next prompt") -- the whole thing isn't a bare pointer
# (is_bare_pointer requires the ENTIRE message to be pointer-ish), but the trailing
# clause carries no information of its own and shouldn't be preserved verbatim either.
# Confirmed via a real incident: streamed in full, including the meaningless trailing
# "go look at the next thing" clause. Strip just that clause, keep the real content
# before it. Reuses the same pointer-word whitelist as the bare-pointer check, applied
# only to the last sentence/line.
strip_trailing_pointer_clause() {
  local text="$1" leading="" trailing=""
  case "$text" in
    *$'\n'*) leading="${text%$'\n'*}"; trailing="${text##*$'\n'}" ;;
    *". "*) leading="${text%. *}."; trailing="${text##*. }" ;;
    *) printf '%s' "$text"; return ;;
  esac
  [ -n "$trailing" ] || { printf '%s' "$text"; return; }
  # Same pure-bash split-and-count as the bare-pointer check above (was 3 execs).
  local words wc_count all_pointerish w
  words="${trailing,,}"; words="${words//[!a-z]/ }"
  wc_count=0; all_pointerish=1
  for w in $words; do
    wc_count=$((wc_count + 1))
    case "$w" in
      a|an|the|in|at|to|for|on|of|is|are|was|were|it|its|that|this) continue ;;
      see|check|read|look|view|latest|prompt|prompts|file|files|chat|chats|log|logs|md|above|below|previous|next|again|refer|referring|reference|pointer) continue ;;
      pick|picking|up|address|addressing|process|processing|work|working|through|queue|queued|queues|item|items) continue ;;
      *) all_pointerish=0; break ;;
    esac
  done
  if [ "$all_pointerish" = 1 ] && [ "$wc_count" -ge 1 ] && [ "$wc_count" -le 10 ]; then
    printf '%s' "$leading"
  else
    printf '%s' "$text"
  fi
}

if [ "$is_pointer" = 1 ]; then
  case "$named" in /*|[A-Za-z]:[\\/]*) CHAT="$named" ;; *) CHAT="$(chatfile_resolve_named "$cwd" "$named")" ;; esac
  mkdir -p "$STATED" 2>/dev/null; printf '%s' "$CHAT" > "$SF"
  # One-name-per-session: this filename came out of the user's OWN prompt text, but
  # Claude Code's own session name is the only name that persists (sync_session_name
  # in on-stop.sh renames the file to follow it as soon as it changes) -- so THIS name
  # only sticks if the user also sets it as the session's real name via /rename. Nudge
  # for it explicitly rather than silently letting the next auto-title overwrite the
  # name the user just typed.
  pointer_named="${CHAT##*/}"; pointer_named="${pointer_named% Chat.md}"
  rename_nudge_ctx=" Also: the chat file you're using is named \"$pointer_named\" because the user wrote it themselves -- but this harness now keeps the chat file synced to Claude Code's own session name (not a separate harness topic), so an auto-title change will rename it away from that. Tell the user to run \`/rename $pointer_named\` to make it the session's actual name and keep it."
  # Named file was hand-written by the user (possibly directly in cwd, pre-subfolder), or
  # never centralized -- migrate/relocate it now so it's under "Local Chat Files/" and
  # centralized like every other session's log (see lib-chatfile-link.sh). No-op if
  # already correct. MUST capture the result -- chatfile_ensure_link can relocate the
  # link, leaving $CHAT/$SF stale if the output is discarded.
  ensured="$(chatfile_ensure_link "$CHAT" "${sid%%-*}" 2>/dev/null)"
  if [ -n "$ensured" ] && [ "$ensured" != "$CHAT" ]; then
    CHAT="$ensured"; printf '%s' "$CHAT" > "$SF"
  fi
  # do NOT stream the pointer (the real prompt is already in the file)
elif [ "$is_bare_pointer" = 1 ]; then
  # Bare pointer has no filename to key off structurally -- but if the user manually
  # pre-wrote a prompt in a "<name> Chat.md" file in cwd that no session has claimed yet,
  # that's almost certainly what they mean. Confirmed via a real incident: a pre-written
  # file sat right there, "see prompt" found and read it correctly, but the reply still
  # streamed to a NEW fallback-named file instead of the one the user actually meant.
  # Adopt it if there's exactly one such candidate; multiple candidates -> don't guess,
  # tell the model to ask the user which one instead.
  # ONLY do this scan if this session hasn't already picked a file (no prior $SF) --
  # confirmed via a real regression: once a session already has an established chat
  # file, a LATER "see prompt" in the same session re-ran this scan and asked the user
  # to disambiguate again, even though this session's own file was already known.
  if [ ! -f "$SF" ]; then
    candidates=()
    while IFS= read -r -d '' f; do
      [ -n "${claimed_paths[$f]:-}" ] && continue
      candidates+=("$f")
    done < <(
      # Both locations: the new convention (subfolder) AND the cwd root (a user who
      # hand-writes a prompt file still does it there; also catches not-yet-migrated
      # legacy files).
      find "$cwd/$CHATFILE_LOCAL_DIR" -maxdepth 1 -iname "*Chat.md" -print0 2>/dev/null
      find "$cwd" -maxdepth 1 -iname "*Chat.md" -print0 2>/dev/null
    )

    if [ "${#candidates[@]}" -eq 1 ] && [ "${candidates[0]}" != "$CHAT" ]; then
      CHAT="${candidates[0]}"
      # Adopted file was hand-written by the user, with a name they chose themselves --
      # same /rename nudge as the named-pointer branch above (one-name-per-session:
      # only /rename makes a user-chosen name stick). Only set here, inside the
      # actually-adopted case: the fall-through and the ambiguous multi-candidate case
      # below both leave $CHAT alone, so neither is user-named.
      pointer_named="${CHAT##*/}"; pointer_named="${pointer_named% Chat.md}"
      rename_nudge_ctx=" Also: the chat file you're using is named \"$pointer_named\" because the user wrote it themselves -- but this harness now keeps the chat file synced to Claude Code's own session name (not a separate harness topic), so an auto-title change will rename it away from that. Tell the user to run \`/rename $pointer_named\` to make it the session's actual name and keep it."
      bare_adopt_ctx=" Adopted the existing chat file \"${CHAT##*/}\" in this directory as this session's log (bare pointer named no file, but exactly one unclaimed candidate existed) -- read its last non-queued block as the real task and act on it."
    elif [ "${#candidates[@]}" -gt 1 ]; then
      names=""
      for f in "${candidates[@]}"; do names="$names\"${f##*/}\", "; done
      names="${names%, }"
      bare_adopt_ctx=" Multiple unclaimed chat files exist in this directory ($names) and the prompt didn't name one -- ask the user (list them as selectable options) which one has the real task before doing anything else; don't guess or stream anything yet."
    fi
  fi
  mkdir -p "$STATED" 2>/dev/null; printf '%s' "$CHAT" > "$SF"
  # Same as the named-pointer branch above: an adopted candidate may be a real file
  # sitting at cwd root, not yet centralized/relocated. Capture + persist per the note
  # on chatfile_ensure_link's return contract above.
  ensured="$(chatfile_ensure_link "$CHAT" "${sid%%-*}" 2>/dev/null)"
  if [ -n "$ensured" ] && [ "$ensured" != "$CHAT" ]; then
    CHAT="$ensured"; printf '%s' "$CHAT" > "$SF"
  fi
  # do NOT stream -- heuristically classified as a no-content pointer, filename unchanged
else
  # Defensive: normally already a correctly-located symlink from log-session-start.sh;
  # this also self-heals a session whose link is stale (still at the old cwd-root
  # location from before this feature existed) or whose statefile/link never got
  # created at all (feature rolled out mid-session, or SessionStart hook was skipped).
  ensured="$(chatfile_ensure_link "$CHAT" "${sid%%-*}" 2>/dev/null)"
  if [ -n "$ensured" ] && [ "$ensured" != "$CHAT" ]; then
    CHAT="$ensured"; mkdir -p "$STATED" 2>/dev/null; printf '%s' "$CHAT" > "$SF"
  fi
  # A resumed session leaves a stale "Resume session with `cd ... && claude --resume
  # ...`" notice (from on-session-end.sh) at the end of the file, and/or a trailing
  # "recap: ..." block (from mirror_reply/flush-reply's away_summary/isCompactSummary
  # handling) that's now stale too. Once a real prompt streams in, neither is useful
  # any more -- strip BOTH (in whichever order/combination they appear) from the end.
  # Only when the tail actually carries one: the rewrite below is two full-file writes
  # (awk to .tmp, cat back through the link) and Defender scans the whole file on each
  # close -- a hot recording during a spell showed those two closes plus the append as
  # the three slowest scans on the box, ~1.5 s of engine time per prompt (2026-10-15).
  # One `tail -c` fork and a builtin case replace an awk + cat + rm on every prompt.
  _ct_tail=""
  [ -f "$CHAT" ] && _ct_tail="$(tail -c 4096 "$CHAT" 2>/dev/null)"
  case "$_ct_tail" in
    *'Resume session with `cd '*|*$'\n'recap:*|recap:*) _ct_strip=1 ;;
    *) _ct_strip=0 ;;
  esac
  unset _ct_tail
  if [ "$_ct_strip" = 1 ]; then
    if awk '
      BEGIN { nb = 0; cur = "" }
      /^---[[:space:]]*$/ { blocks[++nb] = cur; cur = ""; next }
      { cur = (cur == "" ? $0 : cur "\n" $0) }
      END {
        blocks[++nb] = cur
        while (nb > 0) {
          last = blocks[nb]
          gsub(/^[\n]+|[\n]+$/, "", last)
          if (last ~ /^Resume session with `cd .*&& claude --resume [a-zA-Z0-9-]+`$/) { nb--; continue }
          if (last ~ /^recap:/) { nb--; continue }
          break
        }
        for (i = 1; i <= nb; i++) {
          b = blocks[i]
          gsub(/^[\n]+|[\n]+$/, "", b)
          if (b == "") continue
          if (out != "") out = out "\n\n---\n\n" b; else out = b
        }
        if (out != "") print out
      }
    ' "$CHAT" > "${CHAT}.tmp"; then
      # $CHAT is a symlink into <harness>/Chat files/ for a centralized session (see
      # lib-chatfile-link.sh) -- `mv` onto it would replace the LINK ITSELF with a
      # plain file (rename() doesn't follow symlinks at the destination), silently
      # detaching this session's future writes from the central copy. Write through
      # the link instead. Pre-centralization session (not yet a symlink) keeps the
      # original mv. Guarded on the awk command's own exit status, same as the
      # original bare `&&` -- a failed awk must leave $CHAT untouched, not truncate it.
      if [ -L "$CHAT" ]; then
        cat "${CHAT}.tmp" > "$CHAT" && rm -f "${CHAT}.tmp"
      else
        mv "${CHAT}.tmp" "$CHAT"
      fi
    fi
  fi

  # real prompt -> stream it to the current log file (trailing content-free pointer
  # clause stripped first, if any -- see strip_trailing_pointer_clause above)
  if [ -n "$prompt" ]; then
    prompt="$(strip_trailing_pointer_clause "$prompt")"
    if [ -s "$CHAT" ]; then printf '\n---\n\n%s\n' "$prompt" >> "$CHAT"; else printf '%s\n' "$prompt" >> "$CHAT"; fi
  fi
  mkdir -p "$STATED" 2>/dev/null; printf '%s' "$CHAT" > "$SF"
fi

# Every prompt: (1) backfill sessions.txt <name> (field 1) = log basename minus
# " Chat.md", once, while it's still the fallback shortid; (2) move this session's line
# to the top of the file, unconditionally -- no stored timestamp (removed per user
# request), so "most-recently-active first" is maintained structurally instead: the
# line that was just touched is spliced out and re-prepended, so position IS the
# recency signal. Self-heals a session missing from the file entirely (the exact class
# of gap the sessions.txt lock fix addresses going forward, but pre-existing/lost
# entries from before that fix still need this net) -- a newly-added line goes to the
# top too, since it's the most recently active by definition.
SESS="$HOME/.claude/sessions.txt"
if [ -f "$SESS" ]; then
  source "$HOOKS_DIR/lib-sessions-lock.sh"
  topic="${CHAT##*/}"; topic="${topic% Chat.md}"
  topic="$(printf '%s' "$topic" | tr -s '[:space:]' '-')"
  [ "$topic" = "${sid%%-*}" ] && topic=""

  sessions_lock
  # The awk extraction doubles as the existence check (empty output = no line) --
  # the old grep -qF before it was a redundant third pass over the same file.
  matched_line="$(awk -v s="$sid" '{ for (i=1;i<=NF;i++) if ($i=="-r" && $(i+1)==s) { print; exit } }' "$SESS")"
  if [ -n "$matched_line" ]; then
    shortid="${sid%%-*}"
    cur_name="${matched_line%% *}"
    if [ "$cur_name" = "$shortid" ] && [ -n "$topic" ]; then
      matched_line="$topic ${matched_line#* }"
    fi
    tmp="$(mktemp)"
    {
      printf '%s\n' "$matched_line"
      awk -v s="$sid" '{ matched=0; for (i=1;i<=NF;i++) if ($i=="-r" && $(i+1)==s) { matched=1; break }; if (!matched) print }' "$SESS"
    } > "$tmp" && sessions_write_through "$tmp" "$SESS"
  else
    # Missing entirely (lost to the pre-fix race, or a resumed session whose original
    # startup event never fired this hook) -- add it rather than leave it absent.
    # Real sids only (UUID shape): a harness test driving this hook with a synthetic
    # payload sid ("testpersist1") got a permanent sessions.txt/sessions.md line out of
    # this branch -- Claude's own test junk in the user's real session list. Shape alone
    # separates them, no marker file needed.
    case "$sid" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*)
        # Never add a row for a session whose chat file doesn't actually exist -- the
        # append above (streaming $prompt into $CHAT) can silently fail when $cwd is
        # unwritable (confirmed real: headless scheduled runs landing in
        # C:\WINDOWS\system32 left permanent unnamed sessions.txt/sessions.md rows with
        # no chat log behind them at all). A session with nothing real to show gets no
        # row, rather than a bare-shortid one that can never be named.
        [ -f "$CHAT" ] || break
        name="${topic:-${sid%%-*}}"
        tmp="$(mktemp)"
        { printf '%s cd %s && claude -r %s\n' "$name" "$(to_display_cwd "$cwd")" "$sid"; cat "$SESS"; } > "$tmp" && sessions_write_through "$tmp" "$SESS"
        ;;
    esac
  fi
  sessions_unlock
  bash "$HOOKS_DIR/render-sessions-md.sh" 2>/dev/null || true
fi

# inject the current chat filename so commentary lands in the same file. Report CHAT's
# OWN directory, not the raw shell $cwd -- they can legitimately differ (see the leaked-
# bare-cd case above), and telling the model to write to a directory the file isn't
# actually in would just be wrong.
# Injection refresh cadence (2026-09-01): the memory-note list below and this line's
# standing rules were re-injected in FULL on every prompt -- ~700-900 tokens of unchanging
# text per prompt, every session, the largest remaining always-on cost. Now: full on the
# first prompt, then every 10th; a short pointer in between. Deliberately NOT once-only --
# a mid-session /compact can summarize the descriptions away, and a memory rule going dark
# is exactly the failure mode the CRLF bug caused (see the memory loop below). A <=9-prompt
# gap before the full list returns is the accepted trade. The chat FILENAME stays on every
# prompt regardless: it changes on rename and a stale one sends commentary to the wrong file.
_pn_file="$STATED/$sid.promptn"
_pn=0
[ -f "$_pn_file" ] && read -r _pn < "$_pn_file" 2>/dev/null
case "$_pn" in ''|*[!0-9]*) _pn=0 ;; esac
_pn=$((_pn + 1))
printf '%s' "$_pn" > "$_pn_file" 2>/dev/null
_inject_full=0
[ $(( (_pn - 1) % 10 )) -eq 0 ] && _inject_full=1

if [ "$_inject_full" = 1 ]; then
  ctx="Append CLI Output Commentary for this session to the file \"${CHAT##*/}\" at \"${CHAT%/*}\" (NOT necessarily the shell's cwd -- that path is this session's own chat-log directory), NOT \"CLI Chat.md\". Do not append user prompts yourself; this hook streams them.$relocate_ctx$bare_adopt_ctx$badcd_ctx$rename_nudge_ctx"
else
  ctx="Chat log: \"${CHAT##*/}\" in \"${CHAT%/*}\" (rules injected earlier this session; refreshed every 10 prompts).$relocate_ctx$bare_adopt_ctx$badcd_ctx$rename_nudge_ctx"
fi

# Auto-dequeue rather than just reminding: the Stop hook's decision:"block" (meant to
# force the model to continue on a leftover queue) turned out to never actually work --
# checked every real stop_hook_summary transcript entry all session, preventedContinuation
# is false on every one, hookAdditionalContext always empty; the reason text lands in
# hookErrors only, never as model-visible input. Confirmed real, twice, that answering a
# queued item's content got conflated with actually dequeuing it. This hook's own
# injected context is the one channel proven to reach the model every time -- so do the
# mechanical removal HERE instead of asking the model to remember a separate command.
#
# grep's detection regex is looser than dequeue-prompt.sh's extraction regex (which
# requires content after the marker line) -- a bare "--Q" with nothing following it
# matches grep but makes the script exit 1 with nothing to return. Check the actual
# exit code and output, never claim an auto-dequeue that didn't happen.
if [ -f "$CHAT" ] && grep -qE '^-{1,2}[[:space:]]?[Qq][[:space:]]*$' "$CHAT" 2>/dev/null; then
  dequeued="$(bash "$HOOKS_DIR/dequeue-prompt.sh" "$CHAT" 2>/dev/null)"
  dq_rc=$?
  if [ "$dq_rc" -eq 0 ] && [ -n "$dequeued" ]; then
    remaining="$(grep -cE '^-{1,2}[[:space:]]?[Qq][[:space:]]*$' "$CHAT" 2>/dev/null)"
    more=""; [ "${remaining:-0}" -gt 0 ] && more=" ($remaining more still queued after this one.)"
    ctx="$ctx Also: a queued item was just auto-dequeued and is now sitting as plain text at the end of \"${CHAT##*/}\": \"$dequeued\" -- handle your current prompt as usual, then pick this up per the process-prompt-queue skill.$more"
  else
    qcount="$(grep -cE '^-{1,2}[[:space:]]?[Qq][[:space:]]*$' "$CHAT" 2>/dev/null)"
    ctx="$ctx Also: $qcount queued item(s) (marked \"-- Q\") are still waiting in this chat file, but couldn't be auto-dequeued (likely a bare marker with no content after it) -- check the file directly."
  fi
fi

# Cross-session harness-gap notification -- any session flagging a "Harness gap worth
# flagging" also appends one line to harness-gaps.md; surface unreviewed entries here,
# same proven channel as the auto-dequeue above, rather than a second delivery
# mechanism. "- (none yet)" is the scaffold placeholder, not a real entry -- only count
# lines actually shaped like "- [session ...".
GAPS_FILE="$HOME/.claude/harness-gaps.md"
if [ -f "$GAPS_FILE" ]; then
  gapcount="$(grep -cE '^- \[session ' "$GAPS_FILE" 2>/dev/null)"
  if [ "${gapcount:-0}" -gt 0 ]; then
    ctx="$ctx Also: $gapcount unreviewed harness gap(s) flagged by other sessions -- see harness-gaps.md."
  fi
fi

# Manual harness-config.json edit pickup: the file is untracked (syncs via the Octopus
# "Claude Harness" variable set, see octopus-config-push-reminder.sh), so an edit made
# outside any session (hand-edit in an editor) reaches no other machine until pushed.
# Zero-fork fast path: -nt mtime test against the sync-baseline statefile; only when the
# config is newer does one md5sum fork confirm the content actually changed (a fetch/push
# rewrites the file AND the statefile, so an in-sync config fails -nt or matches hashes).
# Re-injects every prompt until Claude pushes (the sync run re-baselines the statefile).
# PROJ-15342: state moved under harness-state/harness/ -- read new path, falling
# back to the pre-migration top-level path (absorbed into the new location the next
# time octopus-config-push-reminder.sh's PostToolUse fires) so a fork-cost-sensitive
# hook that runs on EVERY prompt doesn't need to call lib-claude-paths.sh just to check
# which of two paths currently holds the file.
OCTO_STATE="$HOME/.claude/harness-state/harness/.harness-config-synced-hash"
[ -f "$OCTO_STATE" ] || OCTO_STATE="$HOME/.claude/.harness-config-synced-hash"
OCTO_CFG="$HOME/.claude/harness-config.json"
if [ -f "$OCTO_CFG" ] && [ -f "$OCTO_STATE" ] && [ "$OCTO_CFG" -nt "$OCTO_STATE" ]; then
  octo_hash="$(md5sum "$OCTO_CFG" 2>/dev/null)"; octo_hash="${octo_hash%% *}"
  octo_last=""; IFS= read -r octo_last < "$OCTO_STATE" || true
  if [ -n "$octo_hash" ] && [ "$octo_hash" != "$octo_last" ]; then
    ctx="$ctx Also: harness-config.json changed on disk since its last Octopus sync baseline -- a manual/external edit (no session pushed it). Standing rule: run \`bash scripts/octopus-config-sync.sh push\` from the harness repo NOW, automatically (needs OCTOPUS_API_KEY + VPN), then tell the user it happened and summarize what changed. If the file is invalid JSON or the change looks unintended, ask the user instead of pushing."
  else
    # mtime moved but content identical (fetch rewrote the same bytes) -- quiet the -nt
    # test for future prompts by refreshing the statefile's mtime, content unchanged.
    touch "$OCTO_STATE" 2>/dev/null
  fi
fi

# AGENTS.md-currency persistence: readme-currency-gate.sh (PostToolUse) nudges once per
# file, which nudge-then-forget can silently drop (Claude says "will update later", Stop
# auto-commits the stale doc anyway). Resurface every turn until AGENTS.md itself is
# touched, same proven channel as the two blocks above.
NUDGE_FILE="$HOME/.claude/.session-chatfiles/$sid.readmenudge"
if [ -f "$NUDGE_FILE" ]; then
  nudgecount="$(grep -cP '\t1$' "$NUDGE_FILE" 2>/dev/null)"
  if [ "${nudgecount:-0}" -gt 0 ]; then
    nudgekeys="$(grep -P '\t1$' "$NUDGE_FILE" 2>/dev/null | cut -f1 | tr '\n' ',' | sed 's/,$//')"
    ctx="$ctx Also: AGENTS.md currency still outstanding for $nudgecount harness file(s) edited this session ($nudgekeys) -- update ama-claude-harness/AGENTS.md, or if you checked and no change is needed run bash ~/.claude/hooks/readme-nudge-ack.sh <key> $sid per key (never to skip the check)."
  fi
fi

# Structural (not just CLAUDE.md prose) guard for pointers ("see prompt" etc): if the
# file's actual LAST block is a queued item (marker: 1-2 hyphens, optional space,
# Q/q -- "-- Q", "--Q", "-Q", "- Q", "-- q", "- q", "-q"), that's NOT this turn's task --
# it stays queued, handled after, via the normal queue flow. Confirmed via a real incident:
# a bare pointer picked up and worked the trailing queued block first, skipping a real
# non-queued block that came before it. CLAUDE.md prose alone isn't enough here -- it's
# only read once at session start (edits mid-session don't apply till /clear or restart,
# confirmed against Claude Code's own prompt-caching docs), so an already-running session
# can't pick up a wording fix. This check runs fresh every turn regardless.
if [ -f "$CHAT" ]; then
  last_is_queued="$(awk '
    BEGIN { nb = 0; cur = "" }
    /^---[[:space:]]*$/ { blocks[++nb] = cur; cur = ""; next }
    { cur = (cur == "" ? $0 : cur "\n" $0) }
    END {
      blocks[++nb] = cur
      last = blocks[nb]
      gsub(/^[\n]+|[\n]+$/, "", last)
      print (last ~ /^-{1,2}[[:space:]]?[Qq][[:space:]]*(\n|$)/) ? 1 : 0
    }
  ' "$CHAT" 2>/dev/null)"
  if [ "$last_is_queued" = "1" ]; then
    ctx="$ctx Also: this chat file's LAST block is a queued (\"-- Q\") item -- that is NOT this turn's task. If using a pointer (\"see prompt\" etc), the real task is the last NON-queued block before it; the queued one stays queued for the normal queue flow, handled after, not instead."
  fi
fi

# One-name-per-session: the chat file follows Claude Code's OWN name (sync_session_name
# in on-stop.sh), and that name keeps drifting until the user runs /rename -- measured
# across 71 real sessions with no /rename: mean 3 auto-title changes, worst 14, spread
# over days (see AGENTS.md). So nudge toward /rename with a CONCRETE name (not "go think
# of one") whenever no customTitle exists yet -- that's the harness's own signal for
# "the user hasn't pinned this session's name". Dedupe on the SUGGESTED NAME, not just
# "already nudged once" -- same one-shot pattern as .readmenudge above, but keyed so a
# later auto-title change (a worse name to keep silent about) re-nudges with the new one.
# Stay SILENT on the very first name a session ever gets -- nothing has churned yet at
# that point, and the whole point of this nudge is stopping repeat renames, not
# announcing the first one. Seed .renamenudge from empty without emitting anything;
# only a CHANGE away from a previously-seeded name proves real churn happened, and that's
# what earns the nudge (per explicit user instruction 2026-08-20).
# The ctx wording below is prescriptive, not incidental: a real session relayed an
# earlier version as "this session's chat file keeps auto-renaming itself" -- read as a
# harness bug report, when auto-retitling is normal Claude Code behavior. The text
# explicitly tells the model to frame it that way; don't let a future edit drop that
# instruction back to vaguer "keeps renaming/churn" language (per explicit user
# instruction 2026-08-20).
if [ ! -f "$STATED/$sid.customtitle" ]; then
  suggested="$(cat "$STATED/$sid.aititle" 2>/dev/null)"
  [ -n "$suggested" ] || suggested="$(cat "$STATED/$sid.explicitname" 2>/dev/null)"
  if [ -z "$suggested" ]; then
    b="${CHAT##*/}"; suggested="${b% Chat.md}"
    [ "$suggested" = "${sid%%-*}" ] && suggested=""
  fi
  if [ -n "$suggested" ]; then
    prev_nudge="$(cat "$STATED/$sid.renamenudge" 2>/dev/null)"
    if [ -n "$prev_nudge" ] && [ "$suggested" != "$prev_nudge" ]; then
      mkdir -p "$STATED" 2>/dev/null; printf '%s' "$suggested" > "$STATED/$sid.renamenudge" 2>/dev/null
      ctx="$ctx Also: Claude Code retitled this session -- by design it keeps a session's name tracking the most recent conversation topic, and the chat file follows that name. Relay this to the user as normal Claude Code behavior, NOT a harness bug (don't say the file \"keeps renaming itself\"): Claude retitles sessions as the topic moves, and running \`/rename $suggested\` pins the name so it stops changing."
    elif [ -z "$prev_nudge" ]; then
      mkdir -p "$STATED" 2>/dev/null; printf '%s' "$suggested" > "$STATED/$sid.renamenudge" 2>/dev/null
    fi
  fi
fi

# lib-claude-paths is sourced HERE, above the notice relays -- they need hstate, and it
# has to be defined before the FIRST use, not merely before the throttled
# block further down. Pure function definitions plus two ${VAR:-default} assignments, so
# sourcing it early costs nothing and has no side effects.
. "$HOOKS_DIR/lib-claude-paths.sh"

# A 5-hour/weekly USAGE THRESHOLD CROSSED relay used to sit here, fed by statusline.sh's
# .usage-notices. Removed 2026-09-08 -- the status bar shows both windows live and
# colored, so the notice only duplicated it, and a one-shot notice that queues up while
# the relay is broken gets delivered stale (this one had gone dark for weeks, then
# dumped a 2176-byte backlog quoting long-expired windows at 75%/88% into a reply whose
# bar read 12%/2%). The hstate lesson it left behind still binds every relay here: always
# resolve a notice path with hstate, never re-inline a literal $HOME/.claude/... path --
# statusline.sh had migrated the WRITE under harness-state/ while this kept reading the
# old location, and nothing errored, it just silently never matched.

# Idle-browser nudge (2026-09-14). chrome-activity-track.sh stamps .chrome-active-<sid> with
# the prompt number of every claude-in-chrome call. Two prompts later with no new call, the
# verify loop is over whether or not anyone remembered tabs_close_mcp -- the tab-close-only
# trigger (chrome-verify-compact-nudge.sh) missed every forgotten tab. Same one-shot guard
# as that hook; chrome-compact-rearm.sh clears both on /compact. Marker deleted on fire so a
# LATER loop (after the compact re-arm) starts a fresh count.
_cact="$(hstate sessions ".chrome-active-$sid")"
if [ -s "$_cact" ]; then
  read -r _cpn < "$_cact" 2>/dev/null
  case "$_cpn" in ''|*[!0-9]*) _cpn=0 ;; esac
  _cguard="$(hstate sessions ".usage-state/chrome-compact-nudged-$sid")"
  if [ $(( _pn - _cpn )) -ge 2 ]; then
    if [ ! -f "$_cguard" ]; then
      touch "$_cguard"
      printf 'No claude-in-chrome call in the last 2 prompts -- the verify loop looks finished. Token savings: its Claude-in-Chrome results (screenshots, page reads) are still in context and cost every later turn. Close any leftover verify tab (tabs_close_mcp) and recommend /compact now.\n' \
        >> "$(hstate sessions ".ctx-notices-$sid")"
    fi
    rm -f "$_cact"
  fi
fi

# Relay THIS session's context-window notices. Two writers: statusline.sh's check_context
# (60%/80% crossings, re-arms below 60%) and chrome-verify-compact-nudge.sh (a
# claude-in-chrome verify tab just closed, so its base64 screenshots -- the biggest single
# driver of that server's context cost -- are done being useful). Per-session by design: a
# shared file would leak session A's notice into session B's reply (statusline.sh:238-240).
#
# ALSO WENT DARK, and worse -- this drain did not exist AT ALL. Both writers had been
# appending since 2026-08-11 with no reader anywhere, leaving 18 stale files and 8
# fired-but-never-delivered Chrome nudges on disk, while four separate docs asserted that
# on-prompt.sh relayed them. check-gates.sh asserted only the WRITE side, so the suite
# stayed green the whole time; there is a read-side case now.
#
# The notice text recommends a USER action -- nothing exposes /compact or /clear to Claude
# (skills/context-hygiene/SKILL.md), so relay it as "tell the user to run", never as done.
_ctxn="$(hstate sessions ".ctx-notices-$sid")"
if [ -s "$_ctxn" ]; then
  ctx="$ctx Also: CONTEXT HYGIENE -- $(tr '\n' ';' < "$_ctxn" | sed 's/;$//') Relay this to the user as a recommendation to run it themselves; you cannot compact or clear the context yourself."
  : > "$_ctxn"
fi

# Fork-count throttle (2026-08-31): with concurrent sessions, cygwin's global fork lock
# serializes every process spawn, and the six sourced nudge checks below are dozens of
# forks each prompt (measured: on-prompt.sh 11s quiet, 59-72s with 2 other sessions live
# -- past the 60s timeout, so ALL injected context was being discarded). Every one is a
# daily/weekly-cadence nudge, so run them at most once per 30 min per machine; when the
# marker is fresh they are skipped wholesale and their vars stay empty. One-shot digests
# wait <=30 min, nothing at their cadence notices. hstate is already sourced above (the
# notice relays need it); the check scripts below and the unattended-blocked read rely on
# it being in scope even on a throttled prompt, so do not move that source back down.
embs_notice=""; followup_notice=""; embs_notices_notice=""
aws_notices_notice=""; fleet_health_notice=""; support_notices_notice=""
backlog_stale_notice=""; stale_in_progress_notice=""
_nudge_marker="$(hstate notices .nudge-checks-lastrun)"
_nudge_due=1
if [ -f "$_nudge_marker" ]; then
  _nudge_age=$(( $(date +%s) - $(stat -c %Y "$_nudge_marker" 2>/dev/null || echo 0) ))
  [ "$_nudge_age" -lt 1800 ] && [ "$_nudge_age" -ge 0 ] && _nudge_due=0
fi
[ "$_nudge_due" = 1 ] && touch "$_nudge_marker" 2>/dev/null

# <one entry per line; this element only declares the type> monthly-file calendar-reminder coverage nudge (see
# hooks/embs-coverage-check.sh + skills/ama-embs-reminders/SKILL.md). Pure bash, no
# network, throttled to once per calendar day inside the sourced script.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/embs-coverage-check.sh"
[ -n "$embs_notice" ] && ctx="$ctx Also: $embs_notice"

# Follow-up escalation ledger nudge (see hooks/followup-check.sh +
# skills/ama-followups/SKILL.md). Same sourced pure-bash shape as the <one entry per line; this element only declares the type> nudge above.
# AGENTS.md claimed this was wired since it was written; it never was, so two overdue
# rows sat un-nudged. Documented-but-unwired is a real failure mode here -- assert with
# `grep -n followup-check hooks/on-prompt.sh`, not by reading the docs.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/followup-check.sh"
[ -n "$followup_notice" ] && ctx="$ctx Also: $followup_notice"

# <one entry per line; this element only declares the type> Data Notice triage staleness nudge (see hooks/embs-notices-check.sh +
# skills/ama-embs-notices/SKILL.md). This nudge IS the scheduler for that skill --
# Gmail is MCP-only so no unattended bash job can read the notices. Also surfaces a
# one-shot digest if an unattended run ever writes one.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/embs-notices-check.sh"
[ -n "$embs_notices_notice" ] && ctx="$ctx Also: $embs_notices_notice"

# Worktree sprawl nudge (see hooks/worktree-prune-check.sh + scripts/worktree-prune.sh).
# One glob pass, no git, once a week inside the sourced script.
worktree_prune_notice=""
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/worktree-prune-check.sh"
[ -n "$worktree_prune_notice" ] && ctx="$ctx Also: $worktree_prune_notice"

# AWS notice sweep staleness nudge (see hooks/aws-notices-check.sh +
# skills/ama-aws-notices/SKILL.md). Same sourced pure-bash shape as the <one entry per line; this element only declares the type> nudges
# above, and the scheduler for that skill. Unlike <one entry per line; this element only declares the type> its source (AWS Health API) IS
# readable from plain bash, so an unattended runner needs no headless `claude -p` -- one
# isn't built yet, and the digest file is where it will hand off.
# Headless-session cleanup (see hooks/headless-prune-check.sh +
# scripts/prune-headless-sessions.sh). Sets no notice -- it detaches a once-a-day prune so
# unattended `claude -p` runs never accumulate in sessions.md or `Chat files/` again.
# Deliberately NOT gated on $_nudge_due: this is housekeeping with its own daily throttle,
# not a nudge competing for the user's attention.
source "$HOOKS_DIR/headless-prune-check.sh"

[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/aws-notices-check.sh"
[ -n "$aws_notices_notice" ] && ctx="$ctx Also: $aws_notices_notice"

# Fleet-health nightly-sweep staleness nudge (see hooks/fleet-health-check.sh +
# skills/ama-library-version-sync's fleet-health-check.sh). Unlike the monitors above,
# the sweep itself now pings on new findings directly -- this hook only covers the case
# where the nightly task stops firing entirely, which a ping living inside that script
# can't detect.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/fleet-health-check.sh"
[ -n "$fleet_health_notice" ] && ctx="$ctx Also: $fleet_health_notice"

# Backlog-page staleness nudge (see hooks/backlog-stale-check.sh +
# skills/commit-ticket-jira/scripts/backlog-prune-resolved.sh). Same sourced pure-bash
# shape as the nudges above, and the scheduler for that script. Detection is scheduled
# because most closures happen where no PostToolUse hook can see them -- another session,
# or the Jira UI -- but the Confluence write stays agent-invoked, since it is a whole-body
# replace on a page carrying an embedded image.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/backlog-stale-check.sh"
[ -n "$backlog_stale_notice" ] && ctx="$ctx Also: $backlog_stale_notice"

# Own tickets left In Progress/Review/QA after the work finished (hooks/stale-in-progress-check.sh
# + skills/commit-ticket-jira/scripts/stale-in-progress.sh). Same shape: daily, Jira read agent-side.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/stale-in-progress-check.sh"
[ -n "$stale_in_progress_notice" ] && ctx="$ctx Also: $stale_in_progress_notice"

# QA/Staging sleep schedule (see hooks/env-sleep-check.sh + skills/ama-env-sleep).
# Not gated on $_nudge_due as a whole: the off-hours hint is once per session per day.
source "$HOOKS_DIR/env-sleep-check.sh"
[ -n "$env_sleep_notice" ] && ctx="$ctx Also:$env_sleep_notice"

# Session NAME shared with another LIVE session (scripts/session-name-taken.pl). rename-topic
# runs that check before recommending a name, but a /compact-continued session INHERITS its
# source's customTitle with no rename at all (2026-09-26: d40f3a5d and its source 9ee763bb both
# "toprow-contradicting-detail-rows", and a peer routed a cross-session message to the fork).
# Perl walk ~0.55s, so it rides the 30-min $_nudge_due cycle; deduped on the collider set so a
# standing collision nags once, and re-nudges only when the set changes. Fail-open.
# ALSO on prompt 1: /clear copies the old customTitle as the new transcript's FIRST line
# (2026-10-12: 002e65be -> 2da0f3f0 -> 7f8386fd, one name, three sessions). On prompt 1 the
# .customtitle snapshot doesn't exist yet and the 30-min marker is global (another session
# usually just spent it), so read that first line directly or the user hears ~30 min late.
_nt_name=""
if [ "$_pn" = 1 ] && [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
  IFS= read -r _nt_l1 < "$tr_path" 2>/dev/null
  case "$_nt_l1" in
    '{"type":"custom-title"'*) _nt_name="$(printf '%s' "$_nt_l1" | jq -r '.customTitle // empty' 2>/dev/null | tr -d '\r')" ;;
  esac
fi
[ -z "$_nt_name" ] && [ "$_nudge_due" = 1 ] && _nt_name="$(cat "$STATED/$sid.customtitle" 2>/dev/null)"
if [ -n "$_nt_name" ]; then
  _nt_script="$(chatfile_harness_dir 2>/dev/null)/scripts/session-name-taken.pl"
  if [ -f "$_nt_script" ] && command -v perl >/dev/null 2>&1; then
    _nt_hits="$(perl "$_nt_script" "$_nt_name" "$sid" 2>/dev/null | tr '\n' ';')"
    if [ -n "$_nt_hits" ]; then
      _nt_guard="$(hstate sessions ".name-taken-nudged-$sid")"
      _nt_h="$(printf '%s' "$_nt_hits" | md5sum | cut -d' ' -f1)"
      if [ "$(cat "$_nt_guard" 2>/dev/null)" != "$_nt_h" ]; then
        printf '%s' "$_nt_h" > "$_nt_guard" 2>/dev/null
        ctx="$ctx Also: SESSION NAME SHARED -- this session's name \"$_nt_name\" is also held by live session(s): $_nt_hits A peer or \`claude -r\` routes to whichever it finds first. Usually /clear (or a /compact-continue) copying its source's name -- Claude Code does that, no hook can prevent it. In THIS reply tell the user to run \`/rename <outcome name for this session's task>\` (rename-topic rules; task not known yet -> recommend it at the end of the first task). The other session keeps its name. Also tell them: next time type \`/clear <outcome name>\` -- that names the session being LEFT and the new one starts unnamed (plain /clear copies the name, documented Claude Code behavior)."
      fi
    fi
  fi
fi

# Transition owed but refused fail-closed by ready-to-test-readiness-gate.sh (see
# hooks/pending-transition-check.sh). Not on the $_nudge_due cycle: an owed transition means
# a ticket is sitting at the wrong status where the tester cannot see it, and the file is
# empty in the normal case, so the check is two stat calls. It throttles itself once a day.
source "$HOOKS_DIR/pending-transition-check.sh"
[ -n "$pending_transition_notice" ] && ctx="$ctx Also: $pending_transition_notice"

# Durable cross-session reminders (hooks/reminder-check.sh, scripts/reminder.sh). Every prompt:
# a due reminder must land on the first prompt after it comes due. Empty queue = one glob.
source "$HOOKS_DIR/reminder-check.sh"
[ -n "$reminder_notice" ] && ctx="$ctx Also: $reminder_notice"

# Usage-limit resume audit (hooks/limit-resume-check.sh, scripts/limit-resume.py): a session cut
# off by the usage limit audits and resumes what was in flight. Zero forks unless statusline.sh
# saw a window at >= 99% or the prompt names the reset.
source "$HOOKS_DIR/limit-resume-check.sh"
[ -n "$limit_notice" ] && ctx="$ctx Also: $limit_notice"

# Defender recording made during a slow spell (hooks/defender-hot-check.sh, scripts/
# defender-hot-record.ps1). Every prompt: the log does not exist in the normal case, one -s test.
source "$HOOKS_DIR/defender-hot-check.sh"
[ -n "$defender_hot_notice" ] && ctx="$ctx Also: $defender_hot_notice"

# PR merge-on-approval watchers (hooks/pr-watch-check.sh): restart one whose process died.
# Silent -- no model involvement. No pending marker = one glob.
source "$HOOKS_DIR/pr-watch-check.sh"

# ~/.claude link integrity (scripts/harness-link-check.sh). While a linked file is a REAL
# file, everything written through the ~/.claude path stops reaching the repo and nothing
# says so -- harness-gaps.md was silently detached twice on 2026-09-01 and was only noticed
# because an unrelated suite case happened to go red. Gated on $_nudge_due like every other
# check here: this block was throttled to 30 min specifically for fork cost, and adding an
# ungated per-prompt fork to it is the exact regression the 6f6fb2f3 gap entry recorded.
# Reports only -- repair (--repair) stays a deliberate act, since it rewrites the repo copy.
# `$HOOKS_DIR/..` (not a git rev-parse, and not a $HARNESS_REPO that does not exist in this
# script -- the first draft of this block used one and would have been silently dead, the
# same documented-but-unwired shape the followup-check comment above records).
if [ "$_nudge_due" = 1 ] && [ -f "$HOOKS_DIR/../scripts/harness-link-check.sh" ]; then
  _lc="$(bash "$HOOKS_DIR/../scripts/harness-link-check.sh" "$HOOKS_DIR/.." 2>/dev/null | tr '\n' ' ')"
  [ -n "$_lc" ] && ctx="$ctx Also: ~/.claude LINK INTEGRITY BROKEN -- $_lc Writes through that path are NOT reaching the harness repo. Repair with: bash \"\$HOME/.claude/scripts/harness-link-check.sh\" --repair"
fi

# App support-notification (<one entry per line; this element only declares the type>) monitor
# (see hooks/support-notices-check.sh + skills/<amaSupportChannelName>-notices/SKILL.md). Same
# sourced pure-bash shape as the <one entry per line; this element only declares the type>/AWS nudges above. SECONDARY scheduler here -- the
# PRIMARY is the hourly AMA-Harness-Support-Notices-Ping scheduled task, since the
# cadence is data-driven (hourly on a monthly-file processing day) and no cron
# expression alone can express that.
# Unattended runs refused by a spend/usage limit (2026-08-25: three support-notices fires
# hit "individual spend limit", produced nothing, and looked exactly like "nothing new").
# Each runner appends a line to this file; surfaced once here, then cleared.
_ub="$(hstate notices unattended-blocked.txt)"
if [ -s "$_ub" ]; then
  ctx="$ctx Also: UNATTENDED RUN(S) BLOCKED by a spend/usage limit, no work done -- $(tr '\n' ';' < "$_ub" | sed 's/;$//'). Tell the user; the limit, not the data, is why nothing was reported."
  : > "$_ub"
fi
# Weekly unattended harness-gaps review (skills/ama-harness-gaps/scripts/
# harness-gaps-unattended-run.sh, task AMA-Harness-Gaps-Review). The wrapper writes one
# digest line per outcome (DONE / POSTPONED / SKIPPED / FAILED); surfaced once here, cleared.
_hg="$(hstate notices harness-gaps-review.txt)"
if [ -s "$_hg" ]; then
  ctx="$ctx Also: WEEKLY HARNESS-GAPS AUTO-REVIEW report -- $(tr '\n' ';' < "$_hg" | sed 's/;$//'). Surface it to the user in a short block near the top of the reply, especially any NEEDS USER lines (those await the user's decision)."
  : > "$_hg"
fi

# Biweekly QA backlog sweep (commit-ticket-jira/scripts/backlog-qa-sweep.sh, task
# AMA-Harness-Backlog-QA-Sweep). Digest line only when it added tickets or failed; surfaced once, cleared.
_qs="$(hstate notices backlog-qa-sweep.txt)"
if [ -s "$_qs" ]; then
  ctx="$ctx Also: QA BACKLOG SWEEP report -- $(tr '\n' ';' < "$_qs" | sed 's/;$//'). Tell the user in one line; a FAILED line needs a look (log: harness-state/logs/backlog-qa-sweep.log)."
  : > "$_qs"
fi

# Proactive VPN DNS probe digest (PROJ-15367: hooks/vpn-dns-probe.ps1, scheduled task
# AMA-Harness-VPN-DNS-Probe every 10 min) -- covers the fault the output-scraping logger
# can't see: Claude Code's own API calls degrading with no failing tool command. NOT gated
# on _nudge_due: episodes run minutes to ~25h (measured), and a 30-min throttle would eat
# the SHORT ones entirely -- which are exactly the ones needing an immediate capture. The
# decision stands; only the old "self-heals in minutes" reasoning for it was wrong.
# Zero forks on the steady path ([ -s ] on a resolved path). One-shot, cleared after read.
_vdp="$(hstate notices vpn-dns-probe.txt)"
if [ -s "$_vdp" ]; then
  ctx="$ctx Also: VPN DNS PROBE ALERT (background probe, not a tool failure) -- $(tr '\n' ';' < "$_vdp" | sed 's/;$//') Act on a FAULT line immediately per the message; a RECOVERED line means update the open ticket entry's duration."
  : > "$_vdp"
fi

# Console-window watcher digest (<harnessEpicKey>: scripts/console-window-watch.ps1, resident
# task AMA-Harness-Console-Window-Watch). It logs the owner chain of any VISIBLE console
# window a Claude-spawned process gets -- the blank cascading windows of a hook-timeout
# storm, never caught with their owner before. Relay only the sightings since last shown:
# a byte offset stamp, so the log itself stays intact as evidence. Zero forks steady-state.
_cww="$HOME/.claude/harness-state/logs/console-windows.log"
if [ -s "$_cww" ]; then
  _cww_seen="$(hstate notices .console-windows-shown)"
  _cww_off=0; [ -s "$_cww_seen" ] && _cww_off="$(<"$_cww_seen")"
  _cww_size="$(stat -c %s "$_cww" 2>/dev/null || echo 0)"
  if [ "$_cww_size" -gt "$_cww_off" ] 2>/dev/null; then
    # The watcher's own "<time> started pid=N" line is not a sighting (relayed as one, 2026-09-18).
    _cww_n="$(tail -c +"$((_cww_off + 1))" "$_cww" | grep '^20' | grep -vc ' started pid=')"
    [ "$_cww_n" -gt 0 ] 2>/dev/null && \
    ctx="$ctx Also: CONSOLE-WINDOW WATCHER logged $_cww_n new visible window(s) owned by a shell/console process since last shown -- read $_cww (new entries start at byte $_cww_off). The parent chain says who spawned it: claude/node/wscript in the chain = the flashing-terminal culprit the user asked about (<harnessEpicKey>); explorer.exe with no claude above it = the user's own shell, not evidence."
    printf '%s' "$_cww_size" > "$_cww_seen"
  fi
fi

# check-gates full-run reminder digest (daily 08:50 task AMA-Harness-CheckGates-Reminder;
# armed while hstate notices .check-gates-full-run-owed exists, self-clears via
# scripts/run-check-gates-full.sh on a green run). Same one-shot shape as above.
# HELD, not drained, while process start is slow: the reminder says "when the machine is quiet",
# and a session acting on it mid-spell adds a whole suite to the load (2026-10-22: two suites at
# once, gates 3-20 s). Same spell rule as dispatch.sh's latency marker (>=700 ms, or both of the
# last two >=400 ms); a marker older than 10 min = no recent evidence = not slow. Builtin read.
_cgr="$(hstate notices check-gates-reminder.txt)"
_cgslow=0
_cglm="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/logs/.proc-start-latency-last"
if [ -s "$_cgr" ] && [ -f "$_cglm" ]; then
  _cge=0; _cgm=0; _cgp=0; IFS=' ' read -r _cge _cgm _cgp < "$_cglm" 2>/dev/null
  case "$_cge$_cgm$_cgp" in ''|*[!0-9]*) ;; *)
    if [ $((EPOCHSECONDS - _cge)) -lt 600 ] && { [ "$_cgm" -ge 700 ] || { [ "$_cgm" -ge 400 ] && [ "$_cgp" -ge 400 ]; }; }; then
      _cgslow=1
    fi ;;
  esac
fi
if [ -s "$_cgr" ] && [ "$_cgslow" = 0 ]; then
  ctx="$ctx Also: $(tr '\n' ';' < "$_cgr" | sed 's/;$//')"
  : > "$_cgr"
fi

# file-claim guard reminder digest (daily 09:05 task AMA-Harness-FileClaim-Reminder; armed
# while hstate notices .file-claim-firing-owed exists, and cleared by
# cross-session-repo-claim.sh the first time its file check actually warns -- which also
# writes the firing itself here, so the good news arrives the same way the nag does).
# PROJ-15368. Same one-shot shape as above.
_fcr="$(hstate notices file-claim-reminder.txt)"
if [ -s "$_fcr" ]; then
  ctx="$ctx Also: $(tr '\n' ';' < "$_fcr" | sed 's/;$//')"
  : > "$_fcr"
fi

# PROJ-15362: ONCE per session, a repo-keyed pointer to the on-demand reference docs
# (the AGENTS.md diet moved substance out of always-loaded context; a fresh session should
# know where it went without carrying it). String-match classification, zero extra forks
# on the steady path ([ -f ] short-circuits every later prompt). Sibling of
# jit-pointer-nudge.sh, which does the same per edited-file at PreToolUse time.
if [ ! -f "$STATED/$sid.jitptr" ]; then
  printf '1' > "$STATED/$sid.jitptr" 2>/dev/null
  case "$cwd" in
    *ama-claude-harness*|*/.claude|*/.claude/*)
      ctx="$ctx Also: harness session -- on-demand reference docs exist, read them before re-deriving: GATES-AND-HOOKS.md (hook authoring/wiring/testing), PORTABILITY.md (config sync, notice monitors, scheduled tasks), INSTALL.md (setup); AGENTS.md's gate table is the map." ;;
    *AMA_APP*)
      ctx="$ctx Also: AMA repo session -- the ama-debugging-notes and ama-architecture-notes skills carry per-repo bug-class and structural context; check the relevant one before deep-diving code." ;;
  esac
fi

[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/support-notices-check.sh"
[ -n "$support_notices_notice" ] && ctx="$ctx Also: $support_notices_notice"

# Daily client-feedback monitor digest (hooks/feedback-notices-check.sh + skills/
# ama-feedback-notices): tickets it created overnight, or a FAILED line. Shown once.
[ "$_nudge_due" = 1 ] && source "$HOOKS_DIR/feedback-notices-check.sh"
[ -n "${feedback_notices_notice:-}" ] && ctx="$ctx Also: $feedback_notices_notice"

# Audience communication policy (see hooks/audience-policy-check.sh +
# memory/audience-communication-levels.md). Fires only when the prompt is about writing to
# someone AND names a person the audiences config knows -- this is the ONLY point where the
# policy can still shape the first draft, since by the time create_draft/slack_send_message
# runs the message is already written.
source "$HOOKS_DIR/audience-policy-check.sh"
# Defaulted, unlike the nudges above: if this source ever fails (partial checkout, a
# missing lib) an unbound read here would take the WHOLE hook down -- chat log, memory
# injection and every other nudge with it. A dark policy is a bug; a dark on-prompt.sh is
# an outage.
[ -n "${audience_notice:-}" ] && ctx="$ctx Also: $audience_notice"

# Harness memory (see skills/harness-memory/SKILL.md) -- replaces Claude Code's native
# per-directory auto-memory with a git-tracked, cross-machine store. Index is generated
# fresh every turn from each note's own frontmatter, not hand-maintained, so it can't
# drift the way the native MEMORY.md index did. Malformed frontmatter is skipped, not
# fatal -- one bad file must never break every prompt in every session.
MEMDIR="$HOME/.claude/memory"
if [ -d "$MEMDIR" ]; then
  mem_lines=""; mem_count=0
  for f in "$MEMDIR"/*.md; do
    [ -f "$f" ] || continue
    # Pure-bash frontmatter scan (no awk/grep/head/basename forks per file -- 9 files x
    # 6 forks each measured 6.4s on this machine's degraded fork cost, unconditional on
    # EVERY prompt, confirmed real contributor to the 30s hook timeout). Plain
    # prefix-stripping, not field-splitting -- a description containing its own ": "
    # (e.g. "AMA_APP: user works alone...") would otherwise lose everything up to that
    # inner colon when split into fields. Confirmed real, caught before commit.
    scope=""; desc=""; fm_seen=0
    while IFS= read -r line || [ -n "$line" ]; do
      # CRLF-tolerant. git autocrlf rewrites these notes on checkout (every commit here
      # warns "LF will be replaced by CRLF"), and a trailing CR made "---" never match,
      # so fm_seen stayed 0 and the note silently stopped injecting -- no error, the rule
      # just vanished. Confirmed live 2026-08-20: ama-harness-no-epic-comments (a rule
      # commit-ticket actively cites) and deploy-develop-to-staging were both dark.
      # Parameter expansion, no fork -- keeps this loop's fork budget intact.
      line="${line%$'\r'}"
      if [ "$line" = "---" ]; then
        fm_seen=$((fm_seen + 1))
        [ "$fm_seen" -ge 2 ] && break
        continue
      fi
      [ "$fm_seen" -eq 1 ] || continue
      case "$line" in
        scope:*) [ -z "$scope" ] && scope="${line#scope: }" ;;
        description:*) [ -z "$desc" ] && desc="${line#description: }" ;;
      esac
    done < "$f"
    desc="${desc%\"}"; desc="${desc#\"}"
    name="${f##*/}"; name="${name%.md}"
    [ -n "$scope" ] && [ -n "$desc" ] || continue
    if [ "$scope" = "global" ] || case "$cwd" in *"$scope"*) true ;; *) false ;; esac; then
      mem_lines="$mem_lines
- $name: $desc"
      mem_count=$((mem_count + 1))
    fi
  done
  if [ -n "$mem_lines" ]; then
    if [ "$_inject_full" = 1 ]; then
      ctx="$ctx Also: durable harness memory notes apply this turn (read the named file under ~/.claude/memory/ before acting on one, per harness-memory skill):$mem_lines"
    else
      ctx="$ctx Also: $mem_count durable harness memory notes apply (full list injected earlier this session, refreshed every 10 prompts) -- \`ls ~/.claude/memory/\` and read the relevant one before acting on a rule."
    fi
  fi
fi

jq -cn --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
