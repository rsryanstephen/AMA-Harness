#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell), warn-only. After a `git commit` in an AMA repo, reads the
# REAL commit and nudges when it REWRITES PERSISTED DATA: a migration/backfill/datafix file, or
# added lines carrying a bulk-write shape (Mongo IMigration / Up(IMongoDatabase) / UpdateMany /
# BulkWrite / FindOneAndUpdate / ReplaceOne, SQL `UPDATE ... SET` / ALTER TABLE). Injects the
# six-check protocol from skills/ama-debugging-notes/PERSISTED-DATA-REWRITES.md.
#
# Why (PROJ-15274 -> 15835, 2026-08-04..10-20). cohortreports re-apply migrations
# _1_0_7.._1_0_13 were each analysed and tested ALONE and declared "guarded and idempotent".
# _1_0_10 re-split a `|`-joined `value` into `rawValue` AFTER _1_0_8 had formatted it; the only
# reader of rawValue (the Spark dynamic-cohorts builder, another repo) rejected the cohort on
# every production build for six weeks. The QA log said "4 actual writes" and nobody read them.
# The sibling hook shared-input-contract-nudge.sh covers code that parses shared INPUT; this one
# covers code that rewrites shared DATA -- the same bug class, one level down.
#
# Post-commit, not Edit-time: the commit is where the sequence exists to be reasoned about, it
# still precedes push/deploy, and an Edit-time nudge would fire per keystroke of a migration file.
# Dedupe: once per TICKET (ledger `hstate tickets persisted-rewrite-nudged`); firings logged to
# `hstate logs persisted-rewrite-nudge.log`. Seams: PERSISTED_REWRITE_NUDGE_REV (rev to read,
# default HEAD), CLAUDE_STATE_DIR. Fails open everywhere.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *commit*) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_target_unresolved "$command" commit && exit 0   # never read a guessed repo's HEAD
target_dir="$(git_target_dir "$command" "$cwd" commit)"
[ -n "$target_dir" ] || exit 0
git -C "$target_dir" remote get-url origin 2>/dev/null | grep -q 'ama-claude-harness' && exit 0

rev="${PERSISTED_REWRITE_NUDGE_REV:-HEAD}"
sha="$(git -C "$target_dir" rev-parse --short "$rev" 2>/dev/null)"
[ -n "$sha" ] || exit 0
subject="$(git -C "$target_dir" log -1 --format=%s "$rev" 2>/dev/null)"
ticket="$(printf '%s' "$subject" | grep -oP '^[A-Z]+-\d+' | head -1)"
[ -n "$ticket" ] || ticket="$sha"

. "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null || exit 0
ledger="$(hstate tickets persisted-rewrite-nudged)"
touch "$ledger" 2>/dev/null || exit 0
grep -qxF "ticket|$ticket" "$ledger" && exit 0

# Paths that ARE data rewrites by construction (dir names, any repo/language).
REWRITE_PATHS='(^|/)[Mm]igrations?(\.[A-Za-z]+)?/|(^|/)migrations?/|[Bb]ackfill|[Dd]ata-?[Ff]ix'
# Added lines that rewrite stored data in bulk. Mongo driver + Mongo shell + SQL DDL/DML.
REWRITE_OPS='IMigration\b|Up\(IMongoDatabase|\.UpdateMany(Async)?\(|\.BulkWrite(Async)?\(|\.FindOneAndUpdate(Async)?\(|\.ReplaceOne(Async)?\(|\.updateMany\(|\.bulkWrite\(|^\+\s*UPDATE\s+\S+\s+SET\s|^\+\s*ALTER\s+TABLE\s'

hits=""
files="$(git -C "$target_dir" show --format= --name-only "$rev" -- '*.cs' '*.ts' '*.js' '*.sql' '*.scala' '*.py' 2>/dev/null \
  | grep -viE '(Tests?/|\.Tests?\.|Tests?\.cs$|\.spec\.ts$|\.test\.ts$|/test/|Mock|Fixture)')"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  why=""
  printf '%s' "$f" | grep -qE "$REWRITE_PATHS" && why="migration path"
  # Comment and logging lines name these ops without performing them.
  added="$(git -C "$target_dir" show --format= --unified=0 "$rev" -- "$f" 2>/dev/null | grep -E '^\+[^+]' \
    | grep -vE '^\+\s*(//|/?\*|--|#)|[Ll]og(ger)?\.|\.Log(Information|Warning|Error|Debug|Trace|Critical)\(|console\.(log|warn|error)')"
  o="$(printf '%s\n' "$added" | grep -oE "$REWRITE_OPS" | sed 's/^+\s*//' | sort -u | tr '\n' ' ')"
  [ -n "$o" ] && why="${why:+$why, }bulk write: ${o% }"
  [ -n "$why" ] || continue
  hits="$hits$f ($why); "
done <<< "$files"
[ -n "$hits" ] || exit 0

printf 'ticket|%s\n' "$ticket" >> "$ledger"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$ticket" "$sha" "${hits%; }" \
  >> "$(hstate logs persisted-rewrite-nudge.log)" 2>/dev/null

msg="Just committed $ticket ($sha). It REWRITES PERSISTED DATA: ${hits%; }. A migration, backfill or datafix is a chokepoint change on data: every reader of the rewritten field is a consumer, and every sibling step in the same run is a producer a later step can undo. PROJ-15274's re-apply migrations were each 'guarded and idempotent' and tested alone; 1.0.10 re-split a value into rawValue AFTER 1.0.8 had formatted it, and the only reader (a Spark job in another repo) rejected the cohort on every production build for six weeks (PROJ-15835). Before pushing, put EVIDENCE in the ticket for each of these:
1. SEQUENCE, not units -- one test runs EVERY step above the current high-water mark, in the runner's own order, on one fixture set. A later step writing a field an earlier step formatted is a mandatory case.
2. REAL-SHAPE FIXTURES -- census the live shapes of every touched field (read-only docdb-query.sh / pg-connect.sh): single, multi, delimiter-joined, missing, null, legacy. One hand-typed happy shape tests your assumption against itself.
3. DRY-RUN DIFF -- run against prod-shaped data and READ the per-document before/after of every write. 'N actual writes' in a log is a list to inspect, not a count to note.
4. READER CENSUS -- grep the FLEET (AMA_APP, AMA_ETL, yourproduct-spark-jobs) for every reader of each rewritten field; state its expected shape; run or type-check the rewritten value against it.
5. A test asserting the overwrite (rawValue == value on a field with a formatter) is the bug, not coverage.
6. ROLLBACK -- snapshot ids + prior values before the prod run; a Mongo _migrations record is a high-water mark (re-running one step means removing it AND every higher one).
Protocol: ama-debugging-notes/PERSISTED-DATA-REWRITES.md. Already covered? Say so in one line, naming the sequence test and the reader list."

jq -cn --arg r "$msg" '{decision:"block", reason:$r}'
