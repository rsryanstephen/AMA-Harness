#!/usr/bin/env bash
# Seen ledger for ama-feedback-notices: harness-state/notices/.feedback-notices-seen, one
# tab-separated row per handled feedback mail: msgid \t received \t ref \t disposition.
# Disposition: <TICKET-KEY> | replied (checked: already answered, no ticket needed) |
# pre-existing (seeded at install, NEVER CHECKED -- feedback-next.sh offers it for an
# answered/ticketed check; 2026-10-21: 17 of 28 seeded mails had neither).
# Dedupe on BOTH the Gmail message id and the form's Ref number -- a re-sent/forwarded form
# carries the same Ref under a new message id, and one ticket per Ref is the whole point.
#
#   add <msgid> <received-YYYY-MM-DD> <ref> <ticket-key|pre-existing>   idempotent
#   set <ref> <ticket-key|replied>   the check's outcome for an existing row
#   has <msgid> <ref>        exit 0 if either value is already recorded
#   list                     prints the ledger (msgid \t received \t ref \t disposition)
set -uo pipefail

. "$HOME/.claude/hooks/lib-claude-paths.sh"
SEEN="$(hstate notices .feedback-notices-seen)"
touch "$SEEN"

# Strip CR from every argument -- this box's jq emits CRLF on -r output.
if [ $# -gt 0 ]; then
  _args=()
  for _a in "$@"; do _args+=("$(printf '%s' "$_a" | tr -d '\r')"); done
  set -- "${_args[@]}"
  unset _args _a
fi

has_row() {  # $1 msgid, $2 ref
  awk -F'\t' -v m="$1" -v r="$2" '($1==m) || (r!="" && $3==r) {f=1} END {exit !f}' "$SEEN"
}

cmd="${1:-}"
case "$cmd" in
  add)
    [ $# -eq 5 ] || { printf 'usage: feedback-notices-record.sh add <msgid> <received-YYYY-MM-DD> <ref> <ticket-key|pre-existing>\n' >&2; exit 1; }
    msgid="$2"; received="$3"; ref="$4"; disp="$5"
    printf '%s' "$msgid" | grep -qE '^[0-9a-f]{16}$' || { printf 'msgid must be a 16-hex Gmail id, got %s\n' "$msgid" >&2; exit 1; }
    printf '%s' "$received" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { printf 'received must be YYYY-MM-DD, got %s\n' "$received" >&2; exit 1; }
    printf '%s' "$ref" | grep -qE '^[0-9]{4,12}$' || { printf 'ref must be the digits after Ref:, got %s\n' "$ref" >&2; exit 1; }
    case "$disp" in
      pre-existing|replied) ;;
      *) printf '%s' "$disp" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' || { printf 'disposition must be a ticket key, replied or pre-existing, got %s\n' "$disp" >&2; exit 1; } ;;
    esac
    if has_row "$msgid" "$ref"; then
      printf 'already recorded: %s (Ref:%s)\n' "$msgid" "$ref"
      exit 0
    fi
    printf '%s\t%s\t%s\t%s\n' "$msgid" "$received" "$ref" "$disp" >> "$SEEN"
    printf 'recorded Ref:%s -> %s\n' "$ref" "$disp"
    ;;
  set)
    [ $# -eq 3 ] || { printf 'usage: feedback-notices-record.sh set <ref> <ticket-key|replied>\n' >&2; exit 1; }
    ref="$2"; disp="$3"
    [ "$disp" = replied ] || printf '%s' "$disp" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' \
      || { printf 'disposition must be a ticket key or replied, got %s\n' "$disp" >&2; exit 1; }
    awk -F'\t' -v r="$ref" '$3==r {f=1} END {exit !f}' "$SEEN" || { printf 'no row for Ref:%s\n' "$ref" >&2; exit 1; }
    tmp="$SEEN.tmp.$$"
    awk -F'\t' -v OFS='\t' -v r="$ref" -v d="$disp" '$3==r {$4=d} {print}' "$SEEN" > "$tmp" && mv -f "$tmp" "$SEEN"
    printf 'set Ref:%s -> %s\n' "$ref" "$disp"
    ;;
  has)
    [ $# -eq 3 ] || { printf 'usage: feedback-notices-record.sh has <msgid> <ref>\n' >&2; exit 1; }
    has_row "$2" "$3"
    ;;
  list)
    cat "$SEEN"
    ;;
  *)
    printf 'usage: feedback-notices-record.sh {add|set|has|list} ...\n' >&2
    exit 1
    ;;
esac
