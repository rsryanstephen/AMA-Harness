#!/usr/bin/env bash
# Summarise harness-state/logs/proc-start-latency.log -- how long `bash -c true` took to
# start, sampled by hooks/dispatch.sh at most once a minute on the hooks' own spawn path --
# split by whether a Defender for Endpoint investigation (SenseIR) was running, from the
# start/end lines scripts/console-window-watch.ps1 writes to defender-activity.log. The
# question it answers: are the terminals slow only while an investigation runs, or regardless?
# Usage: proc-start-latency.sh [YYYY-MM-DD] [--spells]
#        (default: every sample; standby windows and signature updates from the last 7 days)
#
# Modern Standby windows (System log, Kernel-Power 506 enter / 507 exit) are read too: a
# sample, a SenseIR "ran=", or a check-gates "took" that spans one is inflated by the sleep,
# not by anything running -- 2026-10-15's 73.6-minute SenseIR run and a 53-minute gate
# invocation were one 52-minute standby. Samples inside a window are reported apart.
#
# SPELL ANALYSIS (2026-10-15): do Defender's per-file scan waits cause the slow spells? Each
# sample now also carries file-write/file-read (us) -- a fresh file rewritten and read back by
# the dispatcher, the per-file scan wait apart from process start -- and is joined with the
# watcher's per-minute counter line (engine-cpu.log: Defender engine/sensor CPU, total CPU,
# processor queue, available memory, disk queue, process counts, top consumers on busy
# minutes). Also marked: full signature updates (Defender event 2000; a cache rebuild + 60 s
# post-update scan follow each) and harness test-suite runs (suite-runs.log, written by
# check-gates.sh, check-dispatch-equivalence.sh and mutate-gates.sh), so self-inflicted load
# is never counted as a spell.
#
# DECISION RULE -- written 2026-10-15 BEFORE any data, applied per slow sample (bash-start >=
# 400 ms, outside standby and suite runs), first match wins; rt0 = median probe round trip
# (file-write + file-read) of normal samples:
#   memory         available memory < 3000 MB
#   cpu            total CPU >= 70% or processor queue >= 10 (20 logical processors here)
#   scan-wait      round trip >= 3 x rt0 and Defender engine >= 100% of a core
#   process-start  round trip < 2 x rt0, engine < 100%   (image checks / sensor callbacks on
#                  process creation; path exclusions would NOT help this)
#   mixed          anything else (inconclusive)
#   no-probe       sample predates the file probe;  no-counters = no watcher counter line
# A spell = slow samples less than 10 min apart, classed by its majority. Only INSTRUMENTED
# spells (majority one of the five real classes) count toward the verdict, which needs >= 3 of
# them over >= 2 days; below that it prints "insufficient". Only "scan-wait" supports asking for
# exclusions. AMENDED 2026-10-15 ~19:30, file-read -> round trip: Defender may scan the new file
# when the WRITE closes, and then the read never waits, so a read-only rule could not see scan
# waits at all (side-agent review). Amended when two instrumented spells existed -- 18:54
# process-start (round trip 857 us, under the 970 us normal median) and 19:24 memory (decided
# before the probe is looked at); neither changes class. The probe
# stays UNVALIDATED until scripts/spell-milestones.sh finds a hot recording where the probe's
# scan time shows up in a timed round trip (it notifies the owner session either way).
# Usage for a verdict: proc-start-latency.sh --since 2026-10-15 (instrumentation began then).
S="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/logs"
L="$S/proc-start-latency.log"; D="$S/defender-activity.log"; C="$S/engine-cpu.log"; R="$S/suite-runs.log"
[ -f "$L" ] || { echo "no samples yet: $L"; exit 0; }
[ -f "$D" ] || D=/dev/null; [ -f "$C" ] || C=/dev/null; [ -f "$R" ] || R=/dev/null
day=""; list=0; from=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spells) list=1 ;;
    --since) shift; from="${1:-}" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) day="$1" ;;
  esac
  shift
done
EV="$(mktemp)"; trap 'rm -f "$EV"' EXIT
if [ -n "$day" ]; then since="$day"; until_="$(date -d "$day +1 day" +%F)"
elif [ -n "$from" ]; then since="$from"; until_="$(date -d '+1 day' +%F)"
else since="$(date -d '7 days ago' +%F)"; until_="$(date -d '+1 day' +%F)"; fi
# Standby (506/507) and full signature updates (2000), one PowerShell call, local time, in TRUE
# event order: a text sort put a 507 before the 506 logged in the same second and dropped a
# 52-minute standby window (2026-10-15).
timeout 45 powershell -NoProfile -Command "\$f=[datetime]'$since'; \$t=[datetime]'$until_'; @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=506,507; StartTime=\$f; EndTime=\$t} -ErrorAction SilentlyContinue) + @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational'; Id=2000; StartTime=\$f; EndTime=\$t} -ErrorAction SilentlyContinue) | Sort-Object TimeCreated | ForEach-Object { '{0:yyyy-MM-ddTHH:mm:ss} {1}' -f \$_.TimeCreated, \$_.Id }" 2>/dev/null | tr -d '\r' > "$EV"
awk -v day="$day" -v from="$from" -v list="$list" '
  function ep(s,  t) { t = s; gsub(/[-T:]/, " ", t); return mktime(t) }
  # A start with no end line = the watcher restarted mid-run (12 Oct pid 40180 had every later
  # sample counted "inside"); bound it at 3h, longer than any run seen awake (68 min).
  function cap(s) { return strftime("%Y-%m-%dT%H:%M:%S", ep(s) + 10800) }
  function kv(s, key,   p) { p = " " key "="; if (index(s, p)) { s = substr(s, index(s, p) + length(p)); sub(/ .*/, "", s); return s } return "" }
  function num(x) { return (x == "" ? -1 : x + 0) }
  function addv(g, m, v) { if (v < 0) return; N[g, m]++; V[g, m, N[g, m]] = v }
  function gmed(g, m,   t, i, n) { n = N[g, m] + 0; if (!n) return "-"; delete t; for (i = 1; i <= n; i++) t[i] = V[g, m, i]; asort(t); return t[int((n + 1) / 2)] }
  function grp(g, k) { NG[g]++; addv(g, "bash", B[k]); addv(g, "rt", PRT[k]); addv(g, "fw", FW[k]); addv(g, "fr", FR[k]); addv(g, "eng", ENG[k]); addv(g, "sense", SEN[k]); addv(g, "total", TOT[k]); addv(g, "queue", Q[k]); addv(g, "mb", MB[k]) }
  function show(g, label) {
    printf "  %-34s n=%-4d bash=%sms probe=%sus (write %s + read %s) eng=%s%% sense=%s%% total=%s%% queue=%s availmb=%s\n", label, NG[g] + 0,
      gmed(g, "bash"), gmed(g, "rt"), gmed(g, "fw"), gmed(g, "fr"), gmed(g, "eng"), gmed(g, "sense"), gmed(g, "total"), gmed(g, "queue"), gmed(g, "mb")
  }
  FILENAME == ARGV[1] {                       # standby pairs (506 -> next 507) and updates (2000)
    if ($2 == "506") cur = $1
    else if ($2 == "507" && cur != "") { ns++; sb_s[ns] = cur; sb_e[ns] = $1; cur = "" }
    else if ($2 == "2000") { nu++; up[nu] = ep($1) }
    next
  }
  FILENAME == ARGV[2] {                       # SenseIR intervals, by pid
    if ($2 == "senseir-start") { p = $3; sub(/^pid=/, "", p); c = $4; sub(/^created=/, "", c); st[p] = substr($1, 1, 10) "T" c }
    else if ($2 == "senseir-end") { p = $3; sub(/^pid=/, "", p); en[p] = $1 }
    next
  }
  FILENAME == ARGV[3] {                       # harness suite runs, by pid
    p = $4; sub(/^pid=/, "", p)
    if ($2 == "start") { so[p] = ep($1) }
    else if ($2 == "end" && (p in so)) { nr++; rs[nr] = so[p]; re[nr] = ep($1); delete so[p] }
    next
  }
  FILENAME == ARGV[4] { CM[substr($1, 1, 16)] = $0; next }    # watcher counter line per minute
  {                                           # the latency samples
    if (day != "" && index($1, day) != 1) next
    if (from != "" && $1 < from) next
    k = ++ns2; TS[k] = $1; E[k] = ep($1)
    b = $2; sub(/^bash-start=/, "", b); sub(/ms$/, "", b); B[k] = b + 0
    x = kv(" " $0, "file-read"); FR[k] = (x == "" ? -1 : x + 0)
    x = kv(" " $0, "file-write"); FW[k] = (x == "" ? -1 : x + 0)
    PRT[k] = (FR[k] < 0 || FW[k] < 0 ? -1 : FR[k] + FW[k])
    m = CM[substr($1, 1, 16)]
    if (m == "") m = CM[strftime("%Y-%m-%dT%H:%M", E[k] - 60)]
    if (m == "") m = CM[strftime("%Y-%m-%dT%H:%M", E[k] + 60)]
    ENG[k] = num(kv(m, "eng")); SEN[k] = num(kv(m, "sense")); TOT[k] = num(kv(m, "total"))
    Q[k] = num(kv(m, "queue")); MB[k] = num(kv(m, "availmb")); PR[k] = kv(m, "procs"); TP[k] = kv(m, "top")
  }
  END {
    for (p in so) { nr++; rs[nr] = so[p]; re[nr] = so[p] + 1800 }   # unterminated suite run
    # --- part 1, unchanged: SenseIR inside/outside/standby
    for (k = 1; k <= ns2; k++) {
      cls[k] = "outside"
      for (i = 1; i <= ns; i++) if (TS[k] >= sb_s[i] && TS[k] <= sb_e[i]) { cls[k] = "standby"; break }
      if (cls[k] != "standby") for (p in st) if (TS[k] >= st[p] && TS[k] <= ((p in en) ? en[p] : cap(st[p]))) { cls[k] = "inside"; break }
      n[cls[k]]++; v[cls[k], n[cls[k]]] = B[k]
    }
    split("inside outside standby", ks, " ")
    for (i = 1; i <= 3; i++) {
      kk = ks[i]; mm = n[kk] + 0
      if (!mm) { printf "%-7s SenseIR runs: no samples\n", kk; continue }
      delete t; for (j = 1; j <= mm; j++) t[j] = v[kk, j]
      asort(t)
      p90 = int(mm * 0.9); if (p90 < 1) p90 = 1
      printf "%-7s SenseIR runs: n=%-5d median=%4dms  p90=%4dms  max=%5dms\n", kk, mm, t[int((mm + 1) / 2)], t[p90], t[mm]
    }
    for (i = 1; i <= ns; i++) printf "standby %s..%s\n", sb_s[i], sb_e[i]
    # --- part 2: spell analysis
    for (k = 1; k <= ns2; k++) {
      if (cls[k] == "standby") continue
      self[k] = 0; for (i = 1; i <= nr; i++) if (E[k] >= rs[i] && E[k] <= re[i]) { self[k] = 1; break }
      post[k] = 0; for (i = 1; i <= nu; i++) if (E[k] - up[i] >= 0 && E[k] - up[i] <= 180) { post[k] = 1; break }
      slow[k] = (B[k] >= 400)
      if (post[k]) grp("post", k)
      if (self[k]) { if (slow[k]) grp("selfslow", k); continue }
      grp(slow[k] ? "slow" : "normal", k)
    }
    rt0 = gmed("normal", "rt")
    print ""
    printf "spell analysis (bash-start >= 400 ms = slow; standby excluded; probe round-trip baseline rt0=%sus)\n", rt0
    show("normal", "normal"); show("slow", "slow"); show("selfslow", "slow during a harness suite run")
    show("post", "0-3 min after a signature update")
    nsp = 0; lastE = -1e12
    for (k = 1; k <= ns2; k++) {
      if (cls[k] == "standby" || self[k] || !slow[k]) continue
      if (PRT[k] < 0) c = "no-probe"
      else if (ENG[k] < 0 && TOT[k] < 0 && MB[k] < 0) c = "no-counters"
      else if (MB[k] >= 0 && MB[k] < 3000) c = "memory"
      else if (TOT[k] >= 70 || Q[k] >= 10) c = "cpu"
      else if (rt0 != "-" && PRT[k] >= 3 * rt0 && ENG[k] >= 100) c = "scan-wait"
      else if (rt0 != "-" && PRT[k] < 2 * rt0 && ENG[k] >= 0 && ENG[k] < 100) c = "process-start"
      else c = "mixed"
      if (E[k] - lastE > 600) { nsp++; spday[nsp] = substr(TS[k], 1, 10); spfirst[nsp] = TS[k] }
      lastE = E[k]; spc[nsp, c]++
      if (list) printf "  %s bash=%dms probe=%sus (write %s + read %s) eng=%s sense=%s total=%s queue=%s availmb=%s class=%s%s procs=%s%s\n", TS[k], B[k], PRT[k], FW[k], FR[k], ENG[k], SEN[k], TOT[k], Q[k], MB[k], c, (post[k] ? " post-update" : ""), PR[k], (TP[k] != "" ? " top=" TP[k] : "")
    }
    split("scan-wait cpu memory process-start mixed no-probe no-counters", cl, " ")
    nu2 = 0
    for (s = 1; s <= nsp; s++) {
      best = ""; bn = 0
      for (i = 1; i <= 7; i++) if (spc[s, cl[i]] > bn) { bn = spc[s, cl[i]]; best = cl[i] }
      usable = (best != "no-probe" && best != "no-counters")
      if (usable) { nu2++; tally[best]++; days[spday[s]] = 1 }
      printf "  spell %d from %s: %s%s\n", s, spfirst[s], best, (usable ? "" : " (not instrumented, not counted)")
    }
    nd = 0; for (d in days) nd++
    out = ""; for (i = 1; i <= 5; i++) out = out sprintf(" %s=%d", cl[i], tally[cl[i]] + 0)
    printf "instrumented spells: %d of %d over %d day(s) ->%s\n", nu2, nsp, nd, out
    print "rule (fixed 2026-10-15; probe round trip from 19:30): memory <3000MB | cpu total>=70% or queue>=10 | scan-wait round trip>=3x rt0 & engine>=100% | process-start round trip<2x rt0 & engine<100% | else mixed"
    if (nu2 < 3 || nd < 2) printf "verdict: insufficient (%d instrumented spell(s) over %d day(s); need >= 3 over >= 2 days)\n", nu2, nd
    else {
      bestc = ""; bn = 0; for (i = 1; i <= 5; i++) if (tally[cl[i]] > bn) { bn = tally[cl[i]]; bestc = cl[i] }
      if (bestc == "scan-wait") v = " -- supports asking for path exclusions"
      else if (bestc == "mixed") v = " -- inconclusive"
      else v = " -- exclusions would not address this"
      printf "verdict: %s in %d of %d instrumented spells%s\n", bestc, bn, nu2, v
    }
  }' "$EV" "$D" "$R" "$C" "$L"
echo "latest:"; tail -n 3 "$L"
# Recordings the elevated task made during spells (scripts/defender-hot-record.ps1).
echo "hot recordings:"; { [ -s "/c/ProgramData/AMA-Harness/defender-hot/defender-hot.log" ] && tail -n 3 "/c/ProgramData/AMA-Harness/defender-hot/defender-hot.log"; } || echo "  none yet (trigger: one sample >= 700 ms or two of the last three >= 400 ms, or MsMpEng > 1 core for 2 min)"
