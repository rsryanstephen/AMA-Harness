#!/usr/bin/env bash
# Records support-notification triage state. Three subcommands, modelled on
# embs-notices-record.sh (msgId-keyed dedupe, same disposition-refusal shape).
#
#   add <msg-id> <received-YYYY-MM-DD> <verdict> <disposition|reason-slug> <slug>
#       Appends one seen row. Idempotent on msg-id.
#       verdict etl|sparc|app REFUSE a bare `-` disposition -- seen means TRIAGED,
#       never ACTIONED. Must carry a ticket key ([A-Z][A-Z0-9]*-[0-9]+), `stale`, or
#       `pending`. verdict no-action REFUSES an empty slug -- every no-action row needs
#       a written reason (this is the file that absorbs "there will be many
#       exceptions"; an unexplained no-action is a judgment nobody can review later).
#
#   settle <msg-id> <verdict> <ticket|stale|->
#       Resolves a `pending` row once its answer arrives. `-` allowed only for
#       verdict no-action.
#
#   finish --none | finish <candidate-msg-id ...>
#       Stamps lastrun ONLY if every candidate msg-id has a seen row -- coverage
#       checked against the ledger, so an interrupted run re-fires. `--none` is the
#       explicit clean-window form.
set -uo pipefail

. "$HOME/.claude/hooks/lib-claude-paths.sh"
SEEN="$(hstate notices .support-notices-seen)"
LASTRUN="$(hstate notices .support-notices-lastrun)"
touch "$SEEN"

# Strip CR from every argument -- this box's jq emits CRLF on -r output, same trap the
# sibling scripts guard against.
if [ $# -gt 0 ]; then
  _args=()
  for _a in "$@"; do _args+=("$(printf '%s' "$_a" | tr -d '\r')"); done
  set -- "${_args[@]}"
  unset _args _a
fi

seen_has() { cut -f1 "$SEEN" | grep -qxF -- "$1"; }

valid_verdict() {
  case "$1" in etl|sparc|app|no-action) return 0 ;; *) return 1 ;; esac
}

valid_date() {
  printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

cmd="${1:-}"
case "$cmd" in
  add)
    [ $# -eq 6 ] || { printf 'usage: support-notices-record.sh add <msg-id> <received-YYYY-MM-DD> <verdict> <disposition|reason-slug> <slug>\n' >&2; exit 1; }
    msgid="$2"; received="$3"; verdict="$4"; disp="$5"; slug="$6"
    valid_verdict "$verdict" || { printf 'verdict must be etl/sparc/app/no-action, got %s\n' "$verdict" >&2; exit 1; }
    valid_date "$received" || { printf 'received must be a real YYYY-MM-DD date, got %s\n' "$received" >&2; exit 1; }
    case "$verdict" in
      etl|sparc|app)
        case "$disp" in
          stale|pending) ;;
          -) printf 'REFUSING %s row with no disposition: needs a ticket key, `stale`, or `pending` -- seen means triaged, never actioned\n' "$verdict" >&2; exit 1 ;;
          *) printf '%s' "$disp" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' || { printf 'disposition must be a ticket key, stale, or pending, got %s\n' "$disp" >&2; exit 1; } ;;
        esac
        ;;
      no-action)
        [ -n "$slug" ] || { printf 'REFUSING no-action row with no reason slug -- every exception needs a written reason\n' >&2; exit 1; }
        ;;
    esac
    case "$msgid$slug" in *"$(printf '\t')"*) printf 'tab in msg-id/slug would corrupt the ledger\n' >&2; exit 1 ;; esac
    if seen_has "$msgid"; then
      printf 'already recorded: %s\n' "$msgid"
      exit 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$msgid" "$received" "$verdict" "$disp" "$slug" >> "$SEEN"
    printf 'recorded %s (%s, %s)\n' "$slug" "$verdict" "$disp"
    ;;
  settle)
    [ $# -eq 4 ] || { printf 'usage: support-notices-record.sh settle <msg-id> <verdict> <ticket|stale|->\n' >&2; exit 1; }
    msgid="$2"; verdict="$3"; disp="$4"
    valid_verdict "$verdict" || { printf 'verdict must be etl/sparc/app/no-action, got %s\n' "$verdict" >&2; exit 1; }
    if [ "$disp" = "-" ]; then
      case "$verdict" in etl|sparc|app) printf 'REFUSING: a settled %s needs a ticket key or `stale`\n' "$verdict" >&2; exit 1 ;; esac
    else
      case "$disp" in
        stale) ;;
        *) printf '%s' "$disp" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' || { printf 'disposition must be a ticket key, stale, or -, got %s\n' "$disp" >&2; exit 1; } ;;
      esac
    fi
    old="$(awk -F'\t' -v m="$msgid" '$1==m{print $3 "/" $4; exit}' "$SEEN")"
    [ -n "$old" ] || { printf 'no seen row for %s -- settle only updates existing rows\n' "$msgid" >&2; exit 1; }
    tmp="$SEEN.tmp.$$"
    awk -F'\t' -v OFS='\t' -v m="$msgid" -v v="$verdict" -v d="$disp" '$1==m{$3=v;$4=d}1' "$SEEN" > "$tmp" && mv "$tmp" "$SEEN"
    printf 'settled %s: %s -> %s/%s\n' "$msgid" "$old" "$verdict" "$disp"
    ;;
  finish)
    shift
    [ $# -gt 0 ] || { printf 'usage: support-notices-record.sh finish --none | finish <candidate-msg-id ...>\n(pass every candidate msg-id this run returned; --none only for a genuinely empty window)\n' >&2; exit 1; }
    if [ "$1" = "--none" ]; then
      [ $# -eq 1 ] || { printf -- '--none takes no other arguments\n' >&2; exit 1; }
      date -u +%FT%H > "$LASTRUN"
      printf 'lastrun updated: %s (clean window, zero candidates)\n' "$(cat "$LASTRUN")"
      exit 0
    fi
    missing=""
    for a in "$@"; do
      seen_has "$a" || missing="$missing $a"
    done
    if [ -n "$missing" ]; then
      printf 'REFUSING to update lastrun: candidate msg-id(s) with no seen row:%s\ntriage + record them first -- run stays stale and will re-fire\n' "$missing" >&2
      exit 1
    fi
    date -u +%FT%H > "$LASTRUN"
    printf 'lastrun updated: %s (%s candidate(s), every one covered by a seen row)\n' "$(cat "$LASTRUN")" "$#"
    ;;
  *)
    printf 'usage: support-notices-record.sh {add|settle|finish} ...\n' >&2
    exit 1
    ;;
esac
