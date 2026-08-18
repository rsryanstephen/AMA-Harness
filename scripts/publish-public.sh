#!/usr/bin/env bash
# publish-public.sh -- export a sanitized, fresh-history snapshot of the harness and
# force-push it to the public GitHub mirror. The working repo's history NEVER goes to
# GitHub -- only a scrubbed single-commit tree. Companion data files (excluded from the
# export because they enumerate the secrets): public-scrub-map.txt (extra literal ->
# placeholder pairs) and public-scrub-gate.txt (forbidden ERE patterns).
#
# The other half of the scrub map is GENERATED here: every string leaf of the real
# harness-config.json is mapped to the same-path value in harness-config.example.json
# (or a <lastKey> placeholder when the example value is empty). New config values are
# therefore auto-covered without touching the map file.
#
# Usage: bash scripts/publish-public.sh [--dry-run | --check-paths <path>...]
#   --dry-run: build + scrub + gate, print the export path, skip the push, keep the tree.
#   --check-paths: scrub+gate the WORKING-TREE copies of the named repo-relative paths
#     only, then exit -- no archive, no push. For hooks/publish-scrub-gate.sh, which runs
#     pre-commit: the normal path exports `git archive HEAD`, so a pre-commit --dry-run
#     would inspect the PREVIOUS commit and miss the one being made. Same map, same scrub,
#     same gate, so a verdict here means what it means in a real publish.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_URL="https://github.com/rsryanstephen/AMA-Harness.git"
REAL_CFG="$REPO_ROOT/harness-config.json"
EXAMPLE_CFG="$REPO_ROOT/harness-config.example.json"
MAP_EXTRA="$REPO_ROOT/scripts/public-scrub-map.txt"
GATE_FILE="$REPO_ROOT/scripts/public-scrub-gate.txt"
DRY=0; CHECK=0
case "${1:-}" in
  --dry-run)     DRY=1 ;;
  --check-paths) CHECK=1; DRY=1; shift ;;   # DRY=1 keeps the work dir out of the push path
esac

# Paths the export drops (step 1 below) -- a check-mode caller passes whatever is staged,
# so the skip list lives HERE, next to the removals it mirrors, not in the caller.
excluded_from_export() {
  case "$1" in
    memory/*|docs/*|harness-config.json|harness-gaps.md) return 0 ;;
    scripts/public-scrub-map.txt|scripts/public-scrub-gate.txt) return 0 ;;
    skills/ama/*|*.skill) return 0 ;;
    skills/company-slides/assets/reference-deck.html) return 0 ;;
  esac
  return 1
}

for f in "$REAL_CFG" "$EXAMPLE_CFG" "$MAP_EXTRA" "$GATE_FILE"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-public.XXXXXX")"
EXPORT="$WORK/tree"; mkdir "$EXPORT"
[ "$DRY" = 1 ] || trap 'rm -rf "$WORK"' EXIT

SRC_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
# skills/ama/ is a browsing-only index of relative symlinks -- still never exported
# (symlink tar extraction is unreliable on MSYS, and the index adds nothing to the mirror).
if [ "$CHECK" = 1 ]; then
  # Working-tree copies of just the named paths, relative layout preserved so the gate's
  # path-pattern check (4b) sees the same names a real export would.
  copied=0
  for p in "$@"; do
    excluded_from_export "$p" && continue
    [ -f "$REPO_ROOT/$p" ] || continue          # deleted/renamed-away in this commit
    mkdir -p "$EXPORT/$(dirname "$p")"
    cp "$REPO_ROOT/$p" "$EXPORT/$p"
    copied=$((copied + 1))
  done
  [ "$copied" -gt 0 ] || { echo "check-paths: nothing to check (all paths excluded from the export)"; exit 0; }
else
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$EXPORT" --exclude='skills/ama' --exclude='skills/ama/*'

# ---- 1. Exclusions: personal/internal content and unscrubbabale binaries -------------
rm -rf "$EXPORT/memory" "$EXPORT/docs"
rm -f  "$EXPORT/harness-config.json" "$EXPORT/harness-gaps.md" \
       "$EXPORT/scripts/public-scrub-map.txt" "$EXPORT/scripts/public-scrub-gate.txt"
find "$EXPORT/skills" -name '*.skill' -type f -delete   # ZIP bundles (derived artifacts)
rm -f  "$EXPORT/skills/company-slides/assets/reference-deck.html"  # internal deck content
mv "$EXPORT/skills/company-slides" "$EXPORT/skills/company-slides" # text refs mapped below
fi

# ---- 2. Combined scrub map (extras first: they win literal collisions) ---------------
MAP="$WORK/map.tsv"
{
  grep -vE '^[[:space:]]*(#|$)' "$MAP_EXTRA" | sed 's/\r$//'
  # (input-based file reads: the Git-for-Windows jq is 1.5rc1, which lacks --slurpfile)
  jq -rn '
    input as $real | input as $ex
    | $real | paths(scalars) as $p
    | ($p | map(tostring) | join(".")) as $dotted
    | select($dotted != "embs.calendarUrl")            # public vendor URL, not sensitive
    | ($real | getpath($p) | tostring) as $rv
    | select(($rv | length) >= 4)                       # too-short values: mangle risk > leak risk
    | ($ex | (try getpath($p) catch null)) as $ev
    | (if ($ev != null) and (($ev | tostring) | length) > 0 then ($ev | tostring)
       else "<" + ($p | map(select(type == "string")) | last) + ">" end) as $repl
    | select($rv != $repl)
    | [$rv, $repl] | @tsv' "$REAL_CFG" "$EXAMPLE_CFG"
} | awk -F'\t' 'NF >= 2 && !seen[$1]++' \
  | awk -F'\t' '{ print length($1) "\t" $0 }' | sort -rn -k1,1 | cut -f2- > "$MAP"

# ---- 3. Substitute (word-boundary aware, longest literal first) -----------------------
SCRUB_PL="$WORK/scrub.pl"
cat > "$SCRUB_PL" <<'PERL'
BEGIN {
  my $map = $ENV{SCRUB_MAP} or die "SCRUB_MAP not set\n";
  open my $fh, '<', $map or die "cannot open $map: $!\n";
  while (<$fh>) {
    chomp; s/\r$//;
    next if /^\s*(#|$)/;
    my ($lit, $rep) = split /\t/, $_, 2;
    die "map line without TAB: $_\n" unless defined $rep && length $rep;
    # letter/digit lookarounds, NOT \b: underscore must count as a separator so
    # compound forms like PROJ_RELEASE / YourProduct_Exporter_* still match.
    my $pre  = ($lit =~ /^[A-Za-z0-9]/) ? '(?<![A-Za-z0-9])' : '';
    my $post = ($lit =~ /[A-Za-z0-9]$/) ? '(?![A-Za-z0-9])'  : '';
    push @main::MAP, [qr/$pre\Q$lit\E$post/, $rep];
  }
  close $fh;
}
for my $m (@main::MAP) { s/$m->[0]/$m->[1]/g; }
PERL
export SCRUB_MAP="$MAP"
find "$EXPORT" -type f -print0 | xargs -0 perl -i -p "$SCRUB_PL"

# ---- 4. Gate: ANY hit aborts ----------------------------------------------------------
fail=0

# 4a. Idempotency: rerunning the scrub must change nothing (word-boundary-accurate proof
#     that no map literal survived -- avoids fixed-string false positives on short names).
find "$EXPORT" -type f -print0 | sort -z > "$WORK/files0"
xargs -0 cat < "$WORK/files0" > "$WORK/pass1"
xargs -0 perl -p "$SCRUB_PL" < "$WORK/files0" > "$WORK/pass2"
if ! cmp -s "$WORK/pass1" "$WORK/pass2"; then
  echo "GATE FAIL: scrub is not idempotent -- a mapped literal survived substitution:" >&2
  diff "$WORK/pass1" "$WORK/pass2" | head -40 >&2
  fail=1
fi

# 4b. Forbidden patterns (case-insensitive ERE) over content AND file paths.
GATE_PATTERNS="$WORK/gate.txt"
grep -vE '^[[:space:]]*(#|$)' "$GATE_FILE" | sed 's/\r$//' > "$GATE_PATTERNS"
# Hits are captured rather than let-print so the temp-dir prefix can be stripped: the
# reader (or hooks/publish-scrub-gate.sh's deny message) needs the repo-relative path they
# actually edited, not /tmp/harness-public.XXXXXX/tree/... . `|| true` because a clean
# grep exits 1 under `set -e`.
hits="$(grep -rInEi -f "$GATE_PATTERNS" "$EXPORT" || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | sed "s|$EXPORT/||g" >&2
  echo "GATE FAIL: forbidden pattern(s) above found in export content." >&2
  fail=1
fi
pathhits="$(find "$EXPORT" | grep -Ei -f "$GATE_PATTERNS" || true)"
if [ -n "$pathhits" ]; then
  printf '%s\n' "$pathhits" | sed "s|$EXPORT/||g" >&2
  echo "GATE FAIL: forbidden pattern(s) above found in export file paths." >&2
  fail=1
fi

if [ "$CHECK" = 1 ]; then
  # Path prefixes in gate output are temp-dir noise to a pre-commit caller -- rewrite them
  # back to repo-relative so the message names the file the committer actually edited.
  [ "$fail" = 0 ] || { echo "CHECK FAIL: the paths above would abort a real publish (scripts/public-scrub-gate.txt)." >&2; rm -rf "$WORK"; exit 1; }
  echo "check-paths clean: $copied file(s) scrub+gate clean."
  rm -rf "$WORK"
  exit 0
fi

[ "$fail" = 0 ] || { echo "Publish ABORTED -- nothing was pushed. Export kept at: $EXPORT" >&2; trap - EXIT; exit 1; }
echo "Gate clean: no sensitive tokens in the export."

# ---- 5. Sanity: scrub must not have broken shell/JSON syntax --------------------------
while IFS= read -r -d '' sh; do bash -n "$sh"; done \
  < <(find "$EXPORT" -type f \( -name '*.sh' -o -name '*.bash' \) -print0)
jq -e . "$EXPORT/harness-config.example.json" > /dev/null
echo "Sanity clean: shell scripts parse, example config is valid JSON."

if [ "$DRY" = 1 ]; then
  echo "DRY RUN -- not pushing. Inspect the export at: $EXPORT"
  exit 0
fi

# ---- 6. Fresh single-commit history, pushed by URL (no standing remote) ---------------
git -C "$EXPORT" init -q -b master
git -C "$EXPORT" add -A
git -C "$EXPORT" -c user.name="rsryanstephen" -c user.email="rsryanstephen@users.noreply.github.com" \
  commit -qm "Public snapshot of $SRC_SHA ($(date +%F))"
git -C "$EXPORT" push --force "$PUBLIC_URL" HEAD:master
echo "Published snapshot of $SRC_SHA to $PUBLIC_URL"
