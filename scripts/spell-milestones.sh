#!/usr/bin/env bash
# Slow-spell measurement milestones (<harnessEpicKey>, 2026-10-15): each is logged when it
# happens and handed to the session that owns the investigation as a DURABLE reminder
# (scripts/reminder.sh: the owner claims it at once, idle or not, through its `reminder.sh
# watch`; owner closed -> any open session claims it 5 min later; none open -> it waits for the
# next session). Log: harness-state/logs/spell-milestones.log.
#
#   probe    each hot recording's evidence on dispatch.sh's per-minute file probe
#            (scratch/hook-run/scnprobe.in: a timed write, then a timed read-back). A recording
#            line "probe scanned Nx, D ms" gives d = D/N, the mean scan; it is compared with the
#            longest probe ROUND TRIP (write + read) timed inside the recording window, because
#            Defender may scan the new file when the write closes rather than on the read
#            (side-agent review 2026-10-15) -- "scanned" alone proves nothing was waited for:
#              validated  d >= 2x the normal round trip and a timed round trip >= 0.8 d
#              refuted    d >= 2x normal and every timed round trip < 0.5 d (the scan ran
#                         without the timed operations waiting: the probe cannot show waits)
#              not-seen   "probe not seen" although the probe was written inside the window
#            Each of the three is notified once; anything else (scan too short to tell, in
#            between, no timed sample in the window) is logged only.
#   verdict  proc-start-latency.sh --since 2026-10-15 reaching a verdict (>= 3 instrumented
#            spells over >= 2 days), then each change of its class. "insufficient" is skipped,
#            so engine-cpu.log rotating (5 MB) can never read as a change; skipped too while a
#            spell is still running (last slow sample < 15 min old). The analysis behind each
#            notice is kept in harness-state/logs/spell-verdict-latest.txt.
#
# Started by hooks/dispatch.sh, detached, only when something is new: the elevated recording
# log changed, or the last slow sample is 15+ min old.
# Usage: spell-milestones.sh check | owner <sid>
#   owner <sid>  the session to notify (none set -> any session claims, 5 min after due); the
#                first call also marks the recording lines already logged as seen.
# Seams: CLAUDE_STATE_DIR, DEFENDER_HOT_ADMIN_LOG, SPELL_ANALYSIS_OUT (analysis text to use).
set -u
S="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
LD="$S/logs"; ND="$S/notices"; mkdir -p "$LD" "$ND" 2>/dev/null
ML="$LD/spell-milestones.log"; OWN="$ND/spell-milestones.owner"; SEEN="$ND/.spell-milestones-admin-seen"
ADMIN="${DEFENDER_HOT_ADMIN_LOG:-/c/ProgramData/AMA-Harness/defender-hot/defender-hot.log}"
LAT="$LD/proc-start-latency.log"; PEND="$LD/.spell-pending"; SINCE=2026-10-15
HERE="$(dirname "${BASH_SOURCE[0]}")"
TAG="Slow-spell measurement (<harnessEpicKey>, the terminal-slowdown investigation):"

nlines() { local n=0 l; [ -s "$1" ] && while IFS= read -r l || [ -n "$l" ]; do n=$((n+1)); done < "$1"; printf '%s' "$n"; }
now() { date +%Y-%m-%dT%H:%M:%S; }

notify() {   # <milestone log text> <reminder task>
  local o="" id
  [ -s "$OWN" ] && { IFS= read -r o < "$OWN" || true; }; o="${o%$'\r'}"; o="${o:-unowned}"
  id="$(bash "$HERE/reminder.sh" add "$o" "$(date '+%Y-%m-%d %H:%M')" "$TAG $2" 2>/dev/null </dev/null)"
  printf '%s %s [reminder %s for %s]\n' "$(now)" "$1" "${id:-NOT FILED}" "${o:0:8}" >> "$ML"
  printf -- '- [spell-milestones, %s] %s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" >> "$ND/defender-notes.md"   # the shared Defender notes file
}

# One awk pass over the samples: the normal round trip (median, bash-start < 400 ms), and the
# probe writes inside [a, b] -> "<outcome> <longest us> <samples> <normal us> <mean scan us>".
probe_eval() {   # <a> <b> <D ms> <N>
  awk -v a="$1" -v b="$2" -v D="$3" -v N="$4" '
    / file-write=/ {
      bs = $2; sub(/^bash-start=/, "", bs); sub(/ms$/, "", bs)
      w = $3; sub(/^file-write=/, "", w); sub(/us$/, "", w)
      r = $4; sub(/^file-read=/, "", r); sub(/us$/, "", r)
      rt = w + r
      if (bs + 0 < 400) { n++; v[n] = rt }
      if ($1 >= a && $1 <= b) { k++; if (rt > mx) mx = rt }
    }
    END {
      r0 = 0; if (n) { asort(v); r0 = v[int((n + 1) / 2)] }
      d = (N > 0 ? D * 1000 / N : 0)
      if (!k) out = "no-timed-sample"
      else if (r0 == 0 || d < 2 * r0) out = "scan-too-short-to-tell"
      else if (mx >= 0.8 * d) out = "validated"
      else if (mx < 0.5 * d) out = "refuted"
      else out = "in-between"
      printf "%s %d %d %d %d\n", out, mx, k, r0, d
    }' "$LAT" 2>/dev/null
}

probe_check() {
  local seen=0 n=0 l p rep st a b e secs pn pd out mx k r0 d
  [ -s "$ADMIN" ] || return 0
  [ -f "$SEEN" ] && { IFS= read -r seen < "$SEEN" || true; }
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n+1)); [ "$n" -le "$seen" ] && continue
    l="${l%$'\r'}"; l="${l#$'\xEF\xBB\xBF'}"
    case "$l" in *" recorded "*"; probe "*"; report "*) ;; *) continue ;; esac
    p="${l#*; probe }"; p="probe ${p%%;*}"
    # Window from the report name (the recording's START stamp; the line's own is its end).
    rep="${l##*; report }"; st="${rep##*[\\/]}"; st="${st%.report.txt}"
    case "$st" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
    a="${st:0:10}T${st:11:2}:${st:14:2}:${st:17:2}"
    secs="${l#* recorded }"; secs="${secs%%s:*}"; case "$secs" in ''|*[!0-9]*) secs=120 ;; esac
    e="$(date -d "${a/T/ }" +%s 2>/dev/null)" || continue
    printf -v b '%(%Y-%m-%dT%H:%M:%S)T' "$((e + secs))"
    pn=0; pd=0
    case "$p" in "probe scanned "*x,*" ms")   # "{1:N1}" follows the culture: 0,8 or 0.8
      pn="${p#probe scanned }"; pn="${pn%%x*}"; pd="${p#*x, }"; pd="${pd% ms}"; pd="${pd//[!0-9,.]/}"; pd="${pd//,/.}" ;;
    esac
    read -r out mx k r0 d <<< "$(probe_eval "$a" "$b" "${pd:-0}" "${pn:-0}")"
    case "$p" in
      "probe scanned "*)
        case "$out" in
          validated)
            grep -q ' probe-validated ' "$ML" 2>/dev/null && continue
            notify "probe-validated recording $a: $p; longest timed round trip ${mx}us vs mean scan ${d}us (normal ${r0}us)" \
              "the file probe is VALIDATED by hot recording $a: Defender scanned scratch/hook-run/scnprobe.in ($p) and a probe round trip (write + read-back) timed inside that window took ${mx} us against a mean scan of ${d} us (normal round trip ${r0} us), so the timed operations do wait for Defender's scan. Tell the user in two sentences (logged in ~/.claude/harness-state/logs/spell-milestones.log). Then run  bash ~/.claude/scripts/proc-start-latency.sh --since 2026-10-15  and give its instrumented-spell count and verdict line; another reminder arrives by itself when the verdict is reached (>= 3 instrumented spells over >= 2 days)." ;;
          refuted)
            grep -q ' probe-refuted ' "$ML" 2>/dev/null && continue
            notify "probe-refuted recording $a: $p; longest timed round trip ${mx}us vs mean scan ${d}us (normal ${r0}us)" \
              "the file probe is REFUTED by hot recording $a: Defender scanned scratch/hook-run/scnprobe.in ($p, mean ${d} us a scan) but no probe round trip timed inside that window took longer than ${mx} us (normal ${r0} us) -- the scan ran without the timed write + read-back waiting for it. The decision rule's scan-wait / process-start split cannot be trusted (memory and cpu classes are unaffected). Tell the user, and propose a different probe to them rather than changing the rule's thresholds after seeing data. Evidence: ~/.claude/harness-state/logs/spell-milestones.log, the recording's report $rep." ;;
          *) printf '%s probe-undecided recording %s: %s; %s (longest timed round trip %sus over %s sample(s), mean scan %sus, normal %sus)\n' \
               "$(now)" "$a" "$p" "$out" "$mx" "$k" "$d" "$r0" >> "$ML" ;;
        esac ;;
      "probe not seen"*)
        [ "${k:-0}" -gt 0 ] 2>/dev/null || continue
        grep -q ' probe-not-seen ' "$ML" 2>/dev/null && continue
        notify "probe-not-seen recording $a: written ${k}x inside the window, not among the scanned files" \
          "hot recording $a did not list the file probe among the files Defender scanned (top 5000 by scan time), although dispatch.sh rewrote scratch/hook-run/scnprobe.in ${k} time(s) inside that window. Until a later recording validates it (another reminder arrives then), the probe's timing does not demonstrably include a scan, so the decision rule's scan-wait / process-start split is unreliable; memory and cpu classes are unaffected. Tell the user; the recording's report ($rep) lists what was scanned." ;;
    esac
  done < "$ADMIN"
  printf '%s' "$n" > "$SEEN"
}

verdict_check() {
  local pe="" out v inst c last lc ps kind said
  [ -f "$PEND" ] && { IFS= read -r pe < "$PEND" || true; }
  case "$pe" in ''|*[!0-9]*) ;; *) [ $(( $(date +%s) - pe )) -ge 900 ] || return 0 ;; esac   # spell still running
  if [ -n "${SPELL_ANALYSIS_OUT:-}" ]; then out="$(cat "$SPELL_ANALYSIS_OUT" 2>/dev/null)"
  else out="$(bash "$HERE/proc-start-latency.sh" --since "$SINCE" --spells 2>&1)"; fi
  v="$(printf '%s\n' "$out" | grep -m1 '^verdict: ' | tr -d '\r')"
  case "$v" in ''|'verdict: insufficient'*) return 0 ;; esac
  inst="$(printf '%s\n' "$out" | grep -m1 '^instrumented spells: ' | tr -d '\r')"
  c="${v#verdict: }"; c="${c%% *}"
  last="$(grep ' verdict-' "$ML" 2>/dev/null | tail -n 1)"; lc=""
  if [ -n "$last" ]; then lc="${last#* class=}"; lc="${lc%%[ :]*}"; [ "$lc" = "$c" ] && return 0; fi
  printf '%s\n' "$out" > "$LD/spell-verdict-latest.txt"
  ps="$(grep -E ' probe-(validated|refuted|not-seen) ' "$ML" 2>/dev/null | sed -e 's/^[^ ]* //' -e 's/ \[reminder .*//' | paste -sd ';' -)"
  if [ -n "$lc" ]; then kind="verdict-changed class=$c (was $lc)"; said="the verdict CHANGED from $lc"
  else kind="verdict-reached class=$c"; said="the verdict is IN"; fi
  notify "$kind: ${v#verdict: }" \
    "$said: ${v#verdict: } (${inst:-instrumented count not printed}). File probe: ${ps:-no decisive hot recording yet, so a scan-wait or process-start verdict is PROVISIONAL}. The full analysis is saved in ~/.claude/harness-state/logs/spell-verdict-latest.txt; for current numbers run  bash ~/.claude/scripts/proc-start-latency.sh --since 2026-10-15 --spells. Tell the user the verdict and what it means under the decision rule fixed before the data (the script prints it): scan-wait = Defender's per-file waits drive the spells, which supports asking IT for path exclusions -- the unsent draft IT Tickets/IT-Ticket-defender-exclusions-dev-tooling.md (harness repo) would then need rewriting around this wait data, a draft for the user only, never sent by Claude; process-start, cpu or memory = exclusions would not address it, so say what would; mixed = inconclusive, keep collecting. Unless the probe line above says validated, call a scan-wait or process-start verdict provisional."
}

case "${1:-}" in
  owner)
    printf '%s\n' "${2:?sid}" > "$OWN"
    [ -f "$SEEN" ] || nlines "$ADMIN" > "$SEEN"
    printf 'owner %s; recording-log lines already seen: %s\n' "${2:0:8}" "$(cat "$SEEN")" ;;
  check)
    LK="$LD/.spell-milestones.lock"
    if ! mkdir "$LK" 2>/dev/null; then
      [ -n "$(find "$LK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 0   # another run holds it
      rm -rf "$LK"; mkdir "$LK" 2>/dev/null || exit 0                      # left by a killed run
    fi
    trap 'rmdir "$LK" 2>/dev/null' EXIT
    probe_check; verdict_check ;;
  *) sed -n 2,31p "$0"; exit 2 ;;
esac
