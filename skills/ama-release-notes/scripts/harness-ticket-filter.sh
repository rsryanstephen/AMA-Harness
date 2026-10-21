#!/usr/bin/env bash
# Drop harness tickets from a release-notes ticket list. Mechanical -- never eyeball it.
# Usage: harness-ticket-filter.sh [--since YYYY-MM-DD] [--no-jira] [FILE]   (stdin if no FILE)
# Input: one ticket per line, TSV, col 1 = key; summary = col 3 if present else col 2
#        (jira-search.sh "key,summary,issuetype" output has summary in col 2; the
#        scratch rel130.tsv shape has it in col 3 -- both work).
# Output (stdout, tab-separated, greppable): `REMOVED<TAB>key<TAB>reason<TAB>summary` then
#        `KEPT<TAB>key<TAB>reason<TAB>summary`. Exit 0 always (bad input -> 2).
# Verdict per key, first match wins:
#   1. Epic-linked to .atlassian.harnessEpicKey (one batched Jira query)        -> REMOVED epic
#   2. commits naming the key exist ONLY in ama-claude-harness repo(s)          -> REMOVED harness-commits-only
#   3. commits in any non-harness repo (incl. mixed harness+app)                -> KEPT app-commits
#   4. no commits anywhere AND summary starts "Harness:" or names ~/.claude, a
#      skill/hook/gate/AGENTS.md                                                -> REMOVED harness-summary
#   5. else                                                                     -> KEPT no-harness-signal
# Why: epic link alone missed 6 of 26 harness tickets on release 130 (2026-10-14).
# Commit scan = ONE `git log --all --since` per repo from `lib-harness-repos.sh index`
# (~60 repos, ~1-3 min). --since default: 120 days ago -- widen if the release is older.
# Expected (release 130 data, 2026-10-14): PROJ-15361/15367 REMOVED harness-commits-only;
#   15362-15365 REMOVED harness-summary; 15376, 15321, 15411 KEPT (mixed/app).
# --no-jira skips rule 1 (offline / no token). ATLASSIAN_API_TOKEN needed otherwise.
set -uo pipefail
. "$HOME/.claude/hooks/lib-harness-repos.sh"

since=""; nojira=0; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="$2"; shift 2;;
    --no-jira) nojira=1; shift;;
    -h|--help) sed -n 2,22p "$0"; exit 0;;
    *) file="$1"; shift;;
  esac
done
[ -n "$since" ] || since="$(date -d '120 days ago' +%Y-%m-%d)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
if [ -n "$file" ]; then tr -d '\r' < "$file" > "$T/in"; else tr -d '\r' > "$T/in"; fi
# key<TAB>summary, de-duplicated by key
awk -F'\t' 'match($1,/PROJ-[0-9]+/){k=substr($1,RSTART,RLENGTH); if(!(k in s)){s[k]=1; print k "\t" (NF>=3?$3:$2)}}' "$T/in" > "$T/keys"
[ -s "$T/keys" ] || { echo "no ticket keys in input" >&2; exit 2; }

# rule 1: epic-linked keys
: > "$T/epic"
epic="$(hr_config '.atlassian.harnessEpicKey')"
if [ "$nojira" = 0 ] && [ -n "$epic" ]; then
  cut -f1 "$T/keys" | split -l 100 - "$T/chunk."
  for c in "$T"/chunk.*; do
    in="$(paste -sd, "$c")"
    bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
      "key in ($in) AND (parent = $epic OR \"Epic Link\" = $epic)" key 200 2>/dev/null | cut -f1 | tr -d '\r' >> "$T/epic"
  done
fi

# rules 2-3: key -> repo-kind map, one git log per distinct repo path
: > "$T/map"
bash "$HOME/.claude/hooks/lib-harness-repos.sh" index 2>/dev/null | tr -d '\r' | cut -f1,3 | sort -u -t$'\t' -k2,2 |
while IFS=$'\t' read -r name p; do
  [ -e "$p/.git" ] || continue
  case "$p" in *ama-claude-harness-local-chat-files*) continue;; esac
  kind=app; case "$name" in ama-claude-harness*) kind=harness;; esac
  # harness commits all read `<harnessEpicKey>: ... PROJ-X ...` -- a MENTION is not work on X
  # (15314 false-positived), so only the leading key counts there; app repos: any mention.
  if [ "$kind" = harness ]; then ex='s/^(PROJ-[0-9]+)[: ].*/\1/p'; else ex='s/.*/&/p'; fi
  git -C "$p" log --all --since="$since" --format=%s 2>/dev/null | sed -nE "$ex" | grep -oE 'PROJ-[0-9]+' | sort -u | sed "s/\$/\t$kind/" >> "$T/map"
done

harness_re='^Harness:|\.claude/|\<[Ss]kills?\>|\<[Hh]ooks?\>|\<[Gg]ates?\>|AGENTS\.md'
while IFS=$'\t' read -r k s; do
  h=$(awk -F'\t' -v k="$k" '$1==k&&$2=="harness"' "$T/map" | wc -l)
  a=$(awk -F'\t' -v k="$k" '$1==k&&$2=="app"' "$T/map" | wc -l)
  if grep -qx "$k" "$T/epic"; then v=REMOVED; r=epic
  elif [ "$h" -gt 0 ] && [ "$a" -eq 0 ]; then v=REMOVED; r=harness-commits-only
  elif [ "$a" -gt 0 ]; then v=KEPT; r=app-commits
  elif printf '%s' "$s" | grep -qE "$harness_re"; then v=REMOVED; r=harness-summary
  else v=KEPT; r=no-harness-signal; fi
  printf '%s\t%s\t%s\t%s\n' "$v" "$k" "$r" "$s"
done < "$T/keys" | sort -t$'\t' -k1,1r -k2,2
