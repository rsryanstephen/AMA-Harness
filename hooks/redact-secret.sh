#!/usr/bin/env bash
# Redact a literal secret out of local Claude Code state -- transcripts, file-history
# snapshots, chat logs, hook logs. Hygiene tool, NOT containment: if the value is also
# committed in a repo or lives on a server, redacting local files changes nothing about
# the real exposure. Rotate the credential; this just stops it being re-read from disk.
#
# Usage: redact-secret.sh <literal-secret> [replacement] [--skip <substring>]...
#        printf '%s' "$s" | redact-secret.sh -   (read secret from stdin, never argv)
#
# Prints per-file match counts only -- never the secret, never the surrounding line.
# Idempotent: re-running finds nothing once a file is clean.

set -uo pipefail

secret="${1:?usage: redact-secret.sh <literal-secret|-> [replacement] [--skip <substring>]...}"
shift
if [ "$secret" = "-" ]; then
  secret="$(cat)"
fi
[ -n "$secret" ] || { echo "redact-secret.sh: empty secret, refusing" >&2; exit 1; }

replacement="[REDACTED-CREDENTIAL]"
skips=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skip) skips+=("${2:?--skip needs a value}"); shift 2 ;;
    *) replacement="$1"; shift ;;
  esac
done

command -v perl >/dev/null || { echo "redact-secret.sh: perl required" >&2; exit 1; }

# Search the WHOLE tree, not an enumerated subset -- enumeration is how you miss
# shell-snapshots/, .session-chatfiles/, subagents/. `.git` excluded (rewriting object
# files would corrupt the repo, and the harness repo is checked separately anyway).
roots=("$HOME/.claude")
harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$harness" ] && roots+=("$harness")

mapfile -t hits < <(
  for r in "${roots[@]}"; do
    [ -d "$r" ] || continue
    grep -rIl --exclude-dir=.git --exclude-dir=node_modules -F -- "$secret" "$r" 2>/dev/null
  done | sort -u
)

if [ "${#hits[@]}" -eq 0 ]; then
  echo "redact-secret.sh: no occurrences found -- nothing to do"
  exit 0
fi

total_files=0
total_hits=0
for f in "${hits[@]}"; do
  for s in ${skips+"${skips[@]}"}; do
    case "$f" in *"$s"*) echo "SKIP  $f"; continue 2 ;; esac
  done

  n="$(grep -c -F -- "$secret" "$f" 2>/dev/null || echo 0)"

  # \Q..\E quotes regex metacharacters in the secret; the replacement goes through a
  # variable so `&`/`$` in it are never interpreted (sed would expand `&` here -- a real
  # corruption risk, since these values routinely contain & and ?).
  if SECRET="$secret" REPL="$replacement" perl -i -pe 's/\Q$ENV{SECRET}\E/$ENV{REPL}/g' "$f" 2>/dev/null; then
    echo "CLEAN $f  ($n occurrence(s))"
    total_files=$((total_files + 1))
    total_hits=$((total_hits + n))
  else
    echo "FAIL  $f  (could not rewrite -- check permissions/locks)" >&2
  fi
done

echo "redact-secret.sh: rewrote $total_hits occurrence(s) across $total_files file(s)"
echo "NOTE: local hygiene only. If the value is committed anywhere or live on a server, rotate it -- this changed nothing about that."
