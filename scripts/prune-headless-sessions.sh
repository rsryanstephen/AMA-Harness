#!/usr/bin/env bash
# Remove every trace of headless (`claude -p` / SDK) sessions from the harness's session
# bookkeeping: the sessions.txt row, the central "Chat files/<name> Chat.md", the
# "Local Chat Files/" symlink pointing at it, and the .session-chatfiles statefile+sidecars.
#
# WHY THIS EXISTS AT ALL. on-prompt.sh deletes a headless run's residue the moment it knows
# the session's kind, so nothing new should accrue. This is the backstop for (a) the ~44
# sessions that accrued while that suppression was silently broken (<harnessEpicKey>: a
# `head -c 4000` window that never contained the entrypoint field, so the guard never once
# fired), and (b) anything that slips past in future. The user's standing instruction is
# that sessions.md and `Chat files/` hold ONLY sessions they started themselves, without
# having to ask for a cleanup again -- hence the auto-run via headless-prune-check.sh.
#
#   prune-headless-sessions.sh                        # dry run: print, delete nothing
#   prune-headless-sessions.sh --apply                # act
#   prune-headless-sessions.sh --apply --time-budget 5
#
# --time-budget SECONDS bounds only the CLASSIFICATION pass (transcript reads for sids with
# no cached verdict). Sids not reached this run are simply looked at next run.
#
# DELETIONS ARE UNRECOVERABLE -- `Chat files/` is gitignored by design (never publish real
# conversation content in a repo other adopters clone). Transcripts under
# ~/.claude/projects/ are NEVER touched, so a pruned session is still resumable with
# `claude -r <sid>`.
#
# FORK BUDGET IS THE DESIGN CONSTRAINT. Process spawn on this machine measured ~0.55s (20
# `cat` calls: 11s), and this walks ~270 sessions, so a `cat`/`grep`/`stat` per session is
# minutes of wall clock -- the first cut of this script ran over 10 minutes and was killed
# twice. Everything per-session is now a bash builtin; the only forks are three fixed ones
# (two `find`s and the sessions.txt rewrite) plus one batched `rm`.
set -u

APPLY=0
TIME_BUDGET=0   # 0 = unbounded
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --time-budget) TIME_BUDGET="${2:-0}"; shift ;;
    --time-budget=*) TIME_BUDGET="${1#*=}" ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "prune-headless-sessions.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

# `dirname`, not ${BASH_SOURCE%/*} -- invoked as `bash prune-headless-sessions.sh` from its
# own directory there is no slash to strip, and the expansion yields the script's own name
# as the directory (confirmed the hard way: every lib silently failed to load).
HOOKS_DIR="$(dirname "${BASH_SOURCE[0]}")/../hooks"
for lib in lib-session-kind lib-sessions-lock lib-chatfile-link; do
  [ -f "$HOOKS_DIR/$lib.sh" ] || { echo "prune-headless-sessions: missing $HOOKS_DIR/$lib.sh" >&2; exit 1; }
  . "$HOOKS_DIR/$lib.sh"
done

STATED="$HOME/.claude/.session-chatfiles"
SESS="$HOME/.claude/sessions.txt"
PROJECTS="$HOME/.claude/projects"
[ -d "$STATED" ] || exit 0

SECONDS=0   # bash builtin. The budget check below runs once per session, and `date` there
            # is a fork -- ~0.55s on this machine, so a 5s budget was spent almost entirely
            # on measuring itself (16 of 23 sids deferred for no reason).

# Two finds, once each, instead of per-session lookups. The second one IS the liveness
# gate: a transcript written in the last 10 minutes belongs to a run still in flight, which
# still owns its files (same rule and window as log-session-start.sh:85-89, and as
# lib-session-liveness.sh -- not reused here only because its session_is_live() re-walks
# the whole tree per sid).
declare -A TR_OF LIVE
while IFS= read -r f; do
  base="${f##*/}"
  TR_OF["${base%.jsonl}"]="$f"
done < <(find "$PROJECTS" -name '*.jsonl' -not -path "*/subagents/*" 2>/dev/null)
while IFS= read -r f; do
  base="${f##*/}"
  LIVE["${base%.jsonl}"]=1
done < <(find "$PROJECTS" -name '*.jsonl' -not -path "*/subagents/*" -newermt '-600 seconds' 2>/dev/null)

# Pass 1: classify every session AND record its chat-file claim in the same walk -- a
# per-headless-sid rescan of all statefiles was the other half of the slowness.
declare -A CHAT_OF
classified=0; kept_live=0; deferred=0
headless_sids=""

for sf in "$STATED"/*; do
  [ -f "$sf" ] || continue
  sid="${sf##*/}"
  case "$sid" in *.*) continue ;; esac
  case "$sid" in ????????-????-????-????-????????????) ;; *) continue ;; esac

  chat=""; IFS= read -r chat < "$sf" 2>/dev/null || true
  CHAT_OF["$sid"]="$chat"

  # A session's entrypoint never changes, so the verdict is cached in <sid>.entrypoint
  # (same sidecar convention as .aititle/.claudename/.explicitname). Written even on a dry
  # run: it is read-derived metadata, not a deletion, and without it every dry run repeats
  # the whole classification pass. Only a SUCCESSFUL read is cached -- "no transcript"
  # (aged out) and "field not found" stay unclassified on purpose, so they get another
  # chance instead of being permanently written off in either direction.
  ep=""; [ -f "$sf.entrypoint" ] && { IFS= read -r ep < "$sf.entrypoint" 2>/dev/null || true; }
  if [ -z "$ep" ]; then
    if [ "$TIME_BUDGET" -gt 0 ] && [ "$SECONDS" -ge "$TIME_BUDGET" ]; then
      deferred=$((deferred + 1)); continue
    fi
    [ -n "${TR_OF[$sid]:-}" ] || continue
    session_read_entrypoint "${TR_OF[$sid]}"
    ep="$SESSION_ENTRYPOINT"
    [ -n "$ep" ] || continue
    classified=$((classified + 1))
    printf '%s' "$ep" > "$sf.entrypoint" 2>/dev/null || true
  fi
  [ "$ep" = "sdk-cli" ] || continue

  if [ -n "${LIVE[$sid]:-}" ]; then kept_live=$((kept_live + 1)); continue; fi
  headless_sids="$headless_sids $sid"
done

# Pass 1b: sessions.txt rows with NO statefile. on-prompt.sh's headless branch deletes the
# statefile, so a row that slipped in anyway (first-prompt race, fixed 6b632c0) had no
# statefile and no chat file -- invisible to pass 1 and pass 2, and it outlived every daily
# prune (c90e27ba/85d96ef7/42cd46ed, 2026-10-08). Classified from the transcript, not cached.
if [ -f "$SESS" ]; then
  while IFS= read -r sid; do
    [ -n "${CHAT_OF[$sid]+x}" ] && continue
    [ -n "${TR_OF[$sid]:-}" ] || continue
    session_read_entrypoint "${TR_OF[$sid]}"
    [ "$SESSION_ENTRYPOINT" = "sdk-cli" ] || continue
    if [ -n "${LIVE[$sid]:-}" ]; then kept_live=$((kept_live + 1)); continue; fi
    CHAT_OF["$sid"]=""
    headless_sids="$headless_sids $sid"
  done < <(grep -oE 'claude -r [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$SESS" | cut -c11-)
fi

# Pass 2: ORPHANED chat files -- a file in `Chat files/` that no statefile records. Pass 1
# can't see these, and they are most of the visible clutter: a statefile is deleted when
# its session is pruned (and aged out on its own before that), while the chat file it
# pointed at only ever gets deleted deliberately. The first hand cleanup this session
# removed sessions.txt rows and left 30 files behind exactly this way.
#
# A sid is recovered from, in order: the "(shortid)" collision suffix in the name, the
# `claude --resume <uuid>` line on-session-end.sh appends inside the file, or a name that
# is nothing but a shortid. Anything that resolves to a headless session goes; anything
# unresolvable, or resolving to an interactive session, is KEPT -- a real session's log is
# never deleted on a guess.
orphan_paths=()
central="$(chatfile_central_dir 2>/dev/null)"
if [ -n "$central" ] && [ -d "$central" ]; then
  declare -A CLAIMED
  for osid in "${!CHAT_OF[@]}"; do
    c="${CHAT_OF[$osid]}"
    [ -n "$c" ] || continue
    # Basename, not `readlink -f` on each: the local symlink and the central file it
    # points at are created with the same basename, and a `readlink` per statefile is ~270
    # forks (~2.5 minutes here). Where the two names DO diverge -- the central file gets a
    # "(shortid)" collision suffix -- the central file simply looks like an orphan, and
    # then has to pass the same headless classification before anything is deleted.
    CLAIMED["${c##*/}"]=1
  done
  for f in "$central"/*" Chat.md"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    [ -z "${CLAIMED[$base]:-}" ] || continue

    osid=""
    stem="${base% Chat.md}"
    case "$stem" in
      *"("????????")") short="${stem##*\(}"; osid="${short%\)}" ;;
      ????????) osid="$stem" ;;
    esac
    if [ -z "$osid" ]; then
      full="$(grep -m1 -ohE 'claude --resume [0-9a-f-]{36}' "$f" 2>/dev/null)"
      osid="${full##* }"
    fi
    [ -n "$osid" ] || continue

    tr_path="${TR_OF[$osid]:-}"
    if [ -z "$tr_path" ]; then
      # A shortid: resolve it against the transcript index, and bail on ambiguity.
      hits=""
      for k in "${!TR_OF[@]}"; do
        case "$k" in "$osid"-*) hits="$hits $k" ;; esac
      done
      set -- $hits
      [ "$#" -eq 1 ] || continue
      tr_path="${TR_OF[$1]}"
    fi
    session_read_entrypoint "$tr_path"
    [ "$SESSION_ENTRYPOINT" = "sdk-cli" ] || continue
    orphan_paths+=("$f")
  done
fi

if [ -z "$headless_sids" ] && [ "${#orphan_paths[@]}" -eq 0 ]; then
  echo "prune-headless-sessions: nothing to prune ($classified newly classified, $kept_live live, $deferred deferred)"
  exit 0
fi

# Any chat file ALSO claimed by a session that is not being pruned is left on disk. Shared
# names are real here ("ama-claude-harness-e0" was two different sessions), and deleting a
# real session's log to tidy up an automation run is the worst possible outcome of a
# cleanup nobody is watching. Unclassified counts as "not headless" -- keep.
claimed_by_other() {
  local target="$1" osid
  [ -n "$target" ] || return 1
  for osid in "${!CHAT_OF[@]}"; do
    [ "${CHAT_OF[$osid]}" = "$target" ] || continue
    case " $headless_sids " in *" $osid "*) continue ;; esac
    return 0
  done
  return 1
}

doomed=()
removed=0
for sid in $headless_sids; do
  chat="${CHAT_OF[$sid]}"
  echo "headless $sid  (${chat##*/})"
  if [ -n "$chat" ]; then
    if claimed_by_other "$chat"; then
      echo "  SKIP chat file -- another session records the same path: $chat"
    else
      # The recorded path is the per-repo "Local Chat Files/<name> Chat.md" symlink; its
      # target is the real central file under "<harness>/Chat files/". A statefile that
      # records the central file directly (pre-centralization) is handled by the second
      # branch. A dangling symlink has no target to remove -- just unlink it.
      if [ -L "$chat" ]; then
        central="$(readlink -f "$chat" 2>/dev/null)"
        if [ -n "$central" ] && [ -f "$central" ]; then echo "  chat: $central"; doomed+=("$central"); fi
        doomed+=("$chat")
      elif [ -f "$chat" ]; then
        echo "  chat: $chat"; doomed+=("$chat")
      fi
    fi
  fi
  # Every sidecar, not a fixed list -- .jitptr/.promptn/.cgnudge etc. outlived the old one.
  doomed+=("$STATED/$sid")
  for f in "$STATED/$sid".*; do [ -e "$f" ] && doomed+=("$f"); done
  removed=$((removed + 1))
done

for f in "${orphan_paths[@]+"${orphan_paths[@]}"}"; do
  echo "orphan chat file (no statefile, headless session)  (${f##*/})"
  doomed+=("$f")
done

if [ "${#doomed[@]}" -gt 0 ]; then
  if [ "$APPLY" -eq 1 ]; then
    rm -f "${doomed[@]}"
  else
    echo "would delete ${#doomed[@]} path(s) (chat files, symlinks, statefiles + sidecars)"
  fi
fi

# sessions.txt rows, in ONE locked write. Field 1 is the display topic, never the sid, so
# rows are matched on the resume command's own `-r <sid>` argument -- matching field 1 is
# what made an earlier hand cleanup silently remove nothing.
if [ -f "$SESS" ] && [ -n "$headless_sids" ]; then
  pat="${headless_sids// /|}"; pat="${pat#|}"
  hits="$(grep -cE "claude -r ($pat)" "$SESS" 2>/dev/null || true)"
  echo "sessions.txt rows to drop: ${hits:-0}"
  if [ "$APPLY" -eq 1 ] && [ "${hits:-0}" -gt 0 ]; then
    sessions_lock
    tmp="$(mktemp)"
    # Blank lines go too: three had accumulated at the tail and render as empty rows.
    # There are never interior blanks -- every line of this file is one session.
    grep -vE "claude -r ($pat)" "$SESS" | grep -v '^[[:space:]]*$' > "$tmp"
    sessions_write_through "$tmp" "$SESS"
    rm -f "$tmp"
    sessions_unlock
    bash "$HOOKS_DIR/render-sessions-md.sh" >/dev/null 2>&1 || true
  fi
fi

if [ "$APPLY" -eq 1 ]; then verb="pruned"; else verb="would be pruned"; fi
echo "prune-headless-sessions: $removed headless session(s) $verb; $classified newly classified, $kept_live live and kept, $deferred deferred"
