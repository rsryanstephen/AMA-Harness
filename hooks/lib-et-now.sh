#!/usr/bin/env bash
# Sourced helper. Canonical Eastern-time resolver for the US-business-hours rules.
#
# WHY A SHARED LIB: two gates now need the identical resolution
# (prod-api-test-window-gate.sh for the Production api-testing pipelines,
# prod-deploy-business-hours-gate.sh for the Production Octopus deploy), and the prose in
# ama-deploy-release points here rather than restating the recipe a third time. Both gates
# source this -- prod-api-test-window-gate.sh's former inline copy was migrated 2026-09-15,
# because two agreeing copies is exactly how a later fix reaches one of them.
#
# THE TRAP THIS EXISTS FOR: `TZ=America/New_York date` does NOT work in git-bash on this
# machine -- git-bash ignores TZ entirely, so `TZ=UTC`, `TZ=America/New_York` and
# `TZ=Asia/Tokyo` all print the identical time (proven 2026-08-18, all three read 16:34).
# The HOUR is wrong, by 4-5 hours, not merely the `%Z` label. Trusting it would have fired
# Production API tests at 12:34 ET, mid-business-hours.
#
# NEVER convert from UTC with a hardcoded offset either. The user's own framing of the
# window start ("13:00 UTC or 9:00 ET") holds only under EDT: 9:00 ET is 13:00 UTC from
# March-November and 14:00 UTC from November-March. ET is the canonical form; no UTC number
# is stored anywhere in this harness.

# et_now -- prints "<hour> <isodow> <HH:MM> <Day> <+zzzz> <TZ>", e.g. "11 3 11:12 Wed -0400 EDT".
# Prints nothing and returns 1 if ET could not be resolved. Field 1 is zero-padded; strip
# with ${hour#0} before any arithmetic or `08` is read as invalid octal.
et_now() {
  local out
  out="$(python -c "from datetime import datetime; from zoneinfo import ZoneInfo; d=datetime.now(ZoneInfo('America/New_York')); print(d.strftime('%H %u %H:%M %a %z %Z'))" 2>/dev/null | tr -d '\r')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# et_next_morning_local -- prints "YYYY-MM-DD HH:MM", the DEFAULT slot for a reminder deferred
# past US business hours: the next weekday 08:00 LOCAL (today if it is a weekday before 08:00;
# weekend -> Monday). User rule 2026-10-14: the PC is off at 17:04 ET (= 23:04 SAST); 08:00 SAST
# is 01:00/02:00 ET (outside the window) and the machine is on. 17:04 ET only if the user asks
# for tonight. Test seam: DEFER_NOW_LOCAL="YYYY-MM-DD HH:MM" fixes "now". Returns 1 if python fails.
et_next_morning_local() {
  local out
  out="$(python -c "
import os
from datetime import datetime, timedelta
s = os.environ.get('DEFER_NOW_LOCAL')
n = datetime.strptime(s, '%Y-%m-%d %H:%M') if s else datetime.now()
t = n.replace(hour=8, minute=0, second=0, microsecond=0)
if n >= t: t += timedelta(days=1)
while t.weekday() >= 5: t += timedelta(days=1)
print(t.strftime('%Y-%m-%d %H:%M'))
" 2>/dev/null | tr -d '\r')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# et_window_state -- classifies "now" against the blocked window: Mon-Fri, 09:00-16:59 ET.
# Prints one of:
#   inside <pretty>       -- within the blocked window
#   outside <pretty>      -- outside it (weekend, or before 9am / from 5pm ET)
#   unresolved            -- python/zoneinfo unavailable
#   utcmatch <HH:MM>      -- ET read back identical to UTC, i.e. the lookup silently fell
#                            back rather than resolving ET. This is the original defect's
#                            signature -- callers must treat it as unresolved, never as
#                            "outside".
# Callers that guard a production action must FAIL CLOSED on unresolved/utcmatch: the whole
# point is that a wrong clock is the hazard, so "could not read the time" must not mean go.
et_window_state() {
  local et hour rest dow pretty utc_hm et_hm
  et="$(et_now)" || { printf 'unresolved'; return 0; }

  hour="${et%% *}"
  rest="${et#* }"; dow="${rest%% *}"; pretty="${rest#* }"

  utc_hm="$(date -u '+%H:%M')"
  et_hm="$(printf '%s' "$pretty" | awk '{print $1}')"
  if [ "$et_hm" = "$utc_hm" ]; then
    printf 'utcmatch %s' "$et_hm"
    return 0
  fi

  # Mon-Fri is ISO dow 1-5. Window is 09:00 through 16:59 ET inclusive.
  case "$dow" in
    [1-5])
      if [ "${hour#0}" -ge 9 ] && [ "${hour#0}" -lt 17 ]; then
        printf 'inside %s' "$pretty"
        return 0
      fi
      ;;
  esac
  printf 'outside %s' "$pretty"
}
