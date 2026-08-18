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
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0
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
# prefix — the folder is redundant with the project you're already in).
default="$cwd/${sid%%-*} Chat.md"
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
if [ -f "$SF" ] && [ "${CHAT%/*}" != "$cwd" ]; then
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
    badcd_ctx=" Your shell's cwd ($cwd) no longer matches this session's actual working directory (${CHAT%/*}) -- that's a bare \`cd\` left unreverted in an earlier tool call, not a real /cd (confirmed: no matching Claude Code transcript relocation happened). This session's chat log was correctly NOT moved. cd back to ${CHAT%/*} now, and going forward use (cd X && cmd) subshells instead of a bare cd, per CLAUDE.md."
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
  # suffix does. The previous enumerated list was six suffixes behind reality
  # (.explicitname/.claudename/.readmenudge/.aititle/.customtitle/.usertopic all
  # missing) -- suffix lists drift, the structural check doesn't.
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
  case "$named" in /*|[A-Za-z]:[\\/]*) named_path="$named" ;; *) named_path="$cwd/$named" ;; esac
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
  case "$named" in /*|[A-Za-z]:[\\/]*) CHAT="$named" ;; *) CHAT="$cwd/$named" ;; esac
  mkdir -p "$STATED" 2>/dev/null; printf '%s' "$CHAT" > "$SF"
  # This filename came out of the user's OWN prompt text, so the resulting topic is
  # user-assigned -- mark it so render-sessions-md.sh's bold field keeps it instead of
  # substituting Claude Code's own session name over it (see that script's priority list).
  : > "$STATED/$sid.usertopic" 2>/dev/null
  # Named file was hand-written by the user directly in cwd, not created through the
  # symlink mechanism -- migrate it into <harness>/Chat files/ now so it's centralized
  # like every other session's log (see lib-chatfile-link.sh). No-ops if it's already
  # a symlink.
  chatfile_ensure_link "$CHAT" "${sid%%-*}" >/dev/null 2>&1 || true
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
    done < <(find "$cwd" -maxdepth 1 -iname "*Chat.md" -print0 2>/dev/null)

    if [ "${#candidates[@]}" -eq 1 ] && [ "${candidates[0]}" != "$CHAT" ]; then
      CHAT="${candidates[0]}"
      # Adopted file was hand-written by the user, with a name they chose themselves --
      # same user-assigned-topic marker as the named-pointer branch above. Only set here,
      # inside the actually-adopted case: the fall-through and the ambiguous
      # multi-candidate case below both leave $CHAT alone, so neither is user-named.
      mkdir -p "$STATED" 2>/dev/null; : > "$STATED/$sid.usertopic" 2>/dev/null
      bare_adopt_ctx=" Adopted the existing chat file \"${CHAT##*/}\" in this directory as this session's log (bare pointer named no file, but exactly one unclaimed candidate existed) -- read its last non-queued block as the real task and act on it."
    elif [ "${#candidates[@]}" -gt 1 ]; then
      names=""
      for f in "${candidates[@]}"; do names="$names\"${f##*/}\", "; done
      names="${names%, }"
      bare_adopt_ctx=" Multiple unclaimed chat files exist in this directory ($names) and the prompt didn't name one -- ask the user (list them as selectable options) which one has the real task before doing anything else; don't guess or stream anything yet."
    fi
  fi
  mkdir -p "$STATED" 2>/dev/null; printf '%s' "$CHAT" > "$SF"
  # Same as the named-pointer branch above: an adopted candidate was a real file sitting
  # in cwd, not yet centralized.
  chatfile_ensure_link "$CHAT" "${sid%%-*}" >/dev/null 2>&1 || true
  # do NOT stream -- heuristically classified as a no-content pointer, filename unchanged
else
  # Defensive: normally already a symlink from log-session-start.sh; only does
  # anything for a session whose statefile/link never got created (e.g. this feature
  # rolled out mid-session, or the SessionStart hook was skipped).
  chatfile_ensure_link "$CHAT" "${sid%%-*}" >/dev/null 2>&1 || true
  # A resumed session leaves a stale "Resume session with `cd ... && claude --resume
  # ...`" notice (from on-session-end.sh) at the end of the file, and/or a trailing
  # "recap: ..." block (from mirror_reply/flush-reply's away_summary/isCompactSummary
  # handling) that's now stale too. Once a real prompt streams in, neither is useful
  # any more -- strip BOTH (in whichever order/combination they appear) from the end.
  if [ -f "$CHAT" ]; then
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
ctx="Append CLI Output Commentary for this session to the file \"${CHAT##*/}\" in the current working directory (${CHAT%/*}), NOT \"CLI Chat.md\". Do not append user prompts yourself; this hook streams them.$relocate_ctx$bare_adopt_ctx$badcd_ctx"

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
OCTO_STATE="$HOME/.claude/.harness-config-synced-hash"
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
    ctx="$ctx Also: AGENTS.md currency still outstanding for $nudgecount harness file(s) edited this session -- update ama-claude-harness/AGENTS.md before calling this harness work done."
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

# Same backstop, same reason, for the fallback-rename rule: relying purely on the model
# noticing "topic is clear now, rename unprompted" mid-task was confirmed to get missed
# in a real session that exited still on its fallback name. Surface it every turn while
# the filename is still the bare fallback so there's more than one chance to catch it.
if [ "${CHAT##*/}" = "${sid%%-*} Chat.md" ]; then
  ctx="$ctx Also: this chat file still has its fallback name (${sid%%-*} Chat.md) -- once the topic is clear, rename it now via the rename-topic skill, unprompted, don't wait for session end."
fi

# Relay any pending usage-threshold-crossing notice from statusline.sh (see
# hooks/statusline.sh + skills/usage-monitor/SKILL.md) -- one-shot, cleared once read,
# so it surfaces in chat exactly once per crossing rather than every turn.
NOTICES="$HOME/.claude/.usage-notices"
if [ -s "$NOTICES" ]; then
  notice_text="$(cat "$NOTICES")"
  ctx="$ctx Also: USAGE THRESHOLD CROSSED -- $notice_text Surface this prominently and distinctly in your reply (bolded/blockquote, not buried in normal prose) per the usage-monitor skill, then continue with the actual task."
  : > "$NOTICES"
fi

# eMBS monthly-file calendar-reminder coverage nudge (see
# hooks/embs-coverage-check.sh + skills/ama-embs-reminders/SKILL.md). Pure bash, no
# network, throttled to once per calendar day inside the sourced script.
source "$HOOKS_DIR/embs-coverage-check.sh"
[ -n "$embs_notice" ] && ctx="$ctx Also: $embs_notice"

# Follow-up escalation ledger nudge (see hooks/followup-check.sh +
# skills/ama-followups/SKILL.md). Same sourced pure-bash shape as the eMBS nudge above.
# AGENTS.md claimed this was wired since it was written; it never was, so two overdue
# rows sat un-nudged. Documented-but-unwired is a real failure mode here -- assert with
# `grep -n followup-check hooks/on-prompt.sh`, not by reading the docs.
source "$HOOKS_DIR/followup-check.sh"
[ -n "$followup_notice" ] && ctx="$ctx Also: $followup_notice"

# eMBS Data Notice triage staleness nudge (see hooks/embs-notices-check.sh +
# skills/ama-embs-notices/SKILL.md). This nudge IS the scheduler for that skill --
# Gmail is MCP-only so no unattended bash job can read the notices. Also surfaces a
# one-shot digest if an unattended run ever writes one.
source "$HOOKS_DIR/embs-notices-check.sh"
[ -n "$embs_notices_notice" ] && ctx="$ctx Also: $embs_notices_notice"

# Harness memory (see skills/harness-memory/SKILL.md) -- replaces Claude Code's native
# per-directory auto-memory with a git-tracked, cross-machine store. Index is generated
# fresh every turn from each note's own frontmatter, not hand-maintained, so it can't
# drift the way the native MEMORY.md index did. Malformed frontmatter is skipped, not
# fatal -- one bad file must never break every prompt in every session.
MEMDIR="$HOME/.claude/memory"
if [ -d "$MEMDIR" ]; then
  mem_lines=""
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
    fi
  done
  if [ -n "$mem_lines" ]; then
    ctx="$ctx Also: durable harness memory notes apply this turn (read the named file under ~/.claude/memory/ before acting on one, per harness-memory skill):$mem_lines"
  fi
fi

jq -cn --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
