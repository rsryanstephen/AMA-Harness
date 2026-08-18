#!/usr/bin/env bash
# Fetches the eMBS publishing calendar, finds the two monthly-file arrival tags we
# care about (2000 GNMA I B -> GNM, 1630 FNMA LOAN -> FNM/FHL), and prints a JSON
# array of reminder dates (arrival + 1 literal day) that haven't already been synced
# to Google Calendar. Claude (the skill) does the actual MCP create_event calls --
# this script only plans, it never touches the calendar itself.
#
# Also refreshes ~/.claude/.embs-coverage with the latest YYYY-MM that actually
# carried a matching tag -- hooks/embs-coverage-check.sh uses that to nudge a re-run
# once the published window is about to run out. eMBS only publishes tags ~6 months
# out (confirmed empirically 2026-08-05: the page spans Jul 2026 - Dec 2027, but only
# Jul-Dec 2026 carry any of our tags), so this is the real "needs a refresh" signal --
# the page URL itself is evergreen/rolling, no year parameter.
#
# Usage: embs-plan-reminders.sh
# Output: JSON array on stdout, e.g. [{"date":"2026-08-07","kind":"FNM_FHL"}, ...]
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"

# Decides which external site gets hit -- a silent default is the bug here, not a
# convenience (same reasoning as lib-harness-repos.sh's own hr_config_required comment).
URL="$(hr_config_required '.embs.calendarUrl')" || exit 1

SYNCED="$HOME/.claude/.embs-reminders-synced"
COVERAGE="$HOME/.claude/.embs-coverage"
touch "$SYNCED"

resp="$(curl -s -m 30 -w '\n%{http_code}' "$URL")"
status="${resp##*$'\n'}"
body="${resp%$'\n'*}"
if [ "$status" != "200" ]; then
  printf 'embs-plan-reminders.sh: HTTP %s fetching %s\n' "$status" "$URL" >&2
  exit 1
fi

# Perl (already used in-repo, hooks/session-ctx-sizes.pl -- `python3` resolves to the
# Microsoft Store stub on this machine, confirmed; `python` is a real install but perl
# is already the house convention for this kind of parse, so no reason to switch).
# Splits month blocks, then day cells within each, strips
# tags, matches the two literal strings. Emits TSV: "ARR<TAB>KIND<TAB>YYYY-MM-DD" per
# arrival, plus one trailing "COVERAGE<TAB>YYYY-MM" line for the latest matching month.
tsv="$(printf '%s' "$body" | perl -0777 -ne '
  my %mon = (January=>1,February=>2,March=>3,April=>4,May=>5,June=>6,July=>7,
             August=>8,September=>9,October=>10,November=>11,December=>12);
  my @p = split /COLSPAN=5[^>]*>([A-Z][a-z]+ \d{4})/;
  my $latest = "";
  for (my $i=1;$i<@p;$i+=2){
    my ($label,$body) = ($p[$i],$p[$i+1]);
    my ($mname,$year) = $label =~ /^(\S+) (\d+)$/;
    my $ym = sprintf("%04d-%02d", $year, $mon{$mname});
    while ($body =~ m{<CENTER><B>(\d+)</B></CENTER>(.*?)(?=<CENTER><B>\d+</B></CENTER>|\z)}gs) {
      my ($day,$cell) = ($1,$2);
      (my $txt = $cell) =~ s/<[^>]+>/ /g;
      my $date = sprintf("%s-%02d", $ym, $day);
      if ($txt =~ /2000 GNMA I B/)    { print "ARR\tGNM\t$date\n"; $latest = $ym if $ym gt $latest; }
      if ($txt =~ /1630 FNMA LOAN/)  { print "ARR\tFNM_FHL\t$date\n"; $latest = $ym if $ym gt $latest; }
    }
  }
  print "COVERAGE\t$latest\n" if $latest;
')"

today="$(date +%F)"
out="[]"
first=1
entries=""

while IFS=$'\t' read -r tag kind arrival; do
  [ "$tag" = "ARR" ] || continue
  reminder="$(date -d "$arrival + 1 day" +%F)"
  # Literal next day, no weekend roll (confirmed: user wants Fri arrival -> Sat
  # reminder as-is, matching real ETL processing days rather than a calendar
  # convenience rule).
  [ "$reminder" \< "$today" ] && continue
  grep -qxF "$reminder	$kind" "$SYNCED" && continue
  entries="${entries}{\"date\":\"${reminder}\",\"kind\":\"${kind}\"},"
done <<< "$tsv"

if [ -n "$entries" ]; then
  out="[${entries%,}]"
fi

coverage="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="COVERAGE"{print $2}')"
[ -n "$coverage" ] && printf '%s\n' "$coverage" > "$COVERAGE"

printf '%s\n' "$out"
