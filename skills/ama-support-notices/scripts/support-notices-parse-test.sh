#!/usr/bin/env bash
# Regression harness for leg A's reply parser. Replicates ONLY the parsing logic, fed with
# the real 2026-09-02 reply from support-notices-ping.log (the one the old DONE* anchor
# threw away) plus the traps that anchor was protecting against.
pass=0; fail=0
check() { # name expect_ok expect_ids raw
  local name="$1" xok="$2" xids="$3" raw="$4"
  local head_a body_a id_start ids_region ids ok
  head_a="${raw%%---DM---*}"
  body_a="${raw#*---DM---}"
  [ "$body_a" = "$raw" ] && body_a=""
  id_start="$(printf '%s\n' "$head_a" | grep -nx '[[:space:]]*DONE[[:space:]]*' | head -1 | cut -d: -f1)"
  case "$head_a" in *"FAILED:"*) id_start="" ;; esac
  if [ -n "$id_start" ]; then
    ok=yes
    ids_region="$(printf '%s\n' "$head_a" | tail -n "+$((id_start + 1))")"
    ids="$(printf '%s' "$ids_region" | grep -oE '[0-9a-f]{16}' | sort -u | tr '\n' ' ')"
    ids="${ids% }"
  else
    ok=no; ids=""
  fi
  if [ "$ok" = "$xok" ] && [ "$ids" = "$xids" ]; then
    pass=$((pass+1)); printf 'PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL  %s  (ok=%s want %s | ids=[%s] want [%s])\n' "$name" "$ok" "$xok" "$ids" "$xids"
  fi
}

# The exact reply shape logged 2026-09-02 20:09 and wrongly discarded.
check "prose preamble then DONE (the 2026-09-02 false failure)" yes "" \
"Confirmed: mailbox live, sender delivering -- widened 14-day search returns 8 threads, but every message id is already in seenIds. No mail since 2026-09-01. Clean window, not a config gap.

DONE
NONE
---DM---
Support notification triage:
Nothing new since 2026-09-01."

check "clean canonical reply with ids" yes "1a0570e247ebc12a 1a05715787a40c34" \
"DONE
1a0570e247ebc12a
1a05715787a40c34
---DM---
Support notification triage:
two items"

# The hazard the old prefix anchor was incidentally guarding: hex in the preamble must
# NOT be recorded as a triaged mail id.
check "16-hex in the preamble is not harvested as an id" yes "1a0570e247ebc12a" \
"Note: thread deadbeefcafe1234 was already seen, skipping it.
DONE
1a0570e247ebc12a
---DM---
Support notification triage:
one item"

check "FAILED reply that also contains the word DONE" no "" \
"FAILED: graylog unreachable, nothing DONE this run"

check "empty reply (real timeout)" no "" ""

check "prose only, no DONE line" no "" \
"I could not reach Gmail so I am stopping here."

# 'DONE' inside a sentence is not a confirmation line.
check "DONE only as a substring, never on its own line" no "" \
"Everything is DONE now I think
---DM---
Support notification triage:
x"


# ---------------------------------------------------------------------------
# Send-or-suppress decision (2026-09-08): DM only when there is a real issue.
# Replicates the wrapper's predicate -- an EXPLICIT `NONE` id region suppresses; a region
# that merely yields no ids does NOT, because "saw mail, could not settle it" has to reach
# a human.
sup() { # name expect_send raw
  local name="$1" xsend="$2" raw="$3"
  local head_a id_start ids_region ids_trimmed send
  head_a="${raw%%---DM---*}"
  id_start="$(printf '%s\n' "$head_a" | grep -nx '[[:space:]]*DONE[[:space:]]*' | head -1 | cut -d: -f1)"
  case "$head_a" in *"FAILED:"*) id_start="" ;; esac
  if [ -z "$id_start" ]; then
    send=fail
  else
    ids_region="$(printf '%s\n' "$head_a" | tail -n "+$((id_start + 1))")"
    ids_trimmed="$(printf '%s' "$ids_region" | tr -d '[:space:]')"
    if [ "$ids_trimmed" = "NONE" ]; then send=no; else send=yes; fi
  fi
  if [ "$send" = "$xsend" ]; then
    pass=$((pass+1)); printf 'PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL  %s  (send=%s want %s)\n' "$name" "$send" "$xsend"
  fi
}

sup "clean window -> SUPPRESS (the 8-a-day noise)" no \
"DONE
NONE
---DM---
Support notification triage: nothing new since last check."

sup "clean window with prose preamble -> still SUPPRESS" no \
"Checked the mailbox, sender delivering, every id already seen.
DONE
NONE
---DM---
Support notification triage: nothing new."

sup "real issue -> SEND" yes \
"DONE
1a0570e247ebc12a
---DM---
Support notification triage:
ETL blew up"

# The distinction that matters: an id region that is neither NONE nor a clean list must
# NOT be read as silence. Suppressing here would hide a mail nobody triaged.
sup "saw mail but could not settle it -> SEND, never suppress" yes \
"DONE
could not settle 1 mail -- graylog unreachable
---DM---
Support notification triage:
1 mail unsettled, Investigated: no -- graylog unreachable"

sup "empty id region (no NONE, no ids) -> SEND, not silence" yes \
"DONE

---DM---
Support notification triage:
something odd happened"

sup "FAILED reply is a failure, not a clean window" fail \
"FAILED: gmail unreachable"

# ---------------------------------------------------------------------------
# Never-fail-to-send fit (2026-10-15). Sources the REAL lib + REAL gate, no replica.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DM_HOOKS="$(cd "$here/../../../hooks" && pwd)"
. "$here/lib-support-dm-fit.sh"
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$1"; else fail=$((fail+1)); printf 'FAIL  %s  (got %s want %s)\n' "$1" "$2" "$3"; fi; }
gate_says() { if dm_gate_ok "$1"; then echo pass; else echo deny; fi; }
line1() { printf '%s\n' "$1" | head -1; }
words_n() { awk -v n="$1" 'BEGIN{for(i=1;i<=n;i++) printf "w%d ", i}'; }

D301="$(printf 'Support notification triage:\n%s\n' "$(words_n 298)")"
ok "301-word triage (the 2026-10-14 denial) now passes as-is" "$(gate_says "$D301")" pass

# ~1500 words, bare IPs in subjects, an unbalanced backtick: the worst case for shrink.
big=""
for i in $(seq 1 12); do
  big="$big
ETL load failed on host 10.1.0.$i 10.1.1.$i 10.1.2.$i for PROJ-1540$i $(words_n 40)
\`System.Exception: boom $i $(words_n 30)\` -- first seen 09:0$i
Investigated: yes. $(words_n 40)
Ticket: none yet"
done
big="Support notification triage:$big
trailing \`unbalanced $(words_n 20)"
ok "1500-word fixture is denied before fit" "$(gate_says "$big")" deny
dm_shrink "$(dm_ensure_header "$big")" 12 "(Shortened to fit Slack. Full triage: /x/.support-notices-lastdm-full)"
ok "shrunk text passes the real gate" "$(gate_says "$DM_FIT_TEXT")" pass
ok "shrunk text keeps header on line 1" "$(line1 "$DM_FIT_TEXT")" "Support notification triage:"
ok "bare-IP subjects get backticked -> truncated, not minimal" "$DM_FIT_PATH" truncated
ok "truncated form keeps ticket keys" "$(printf '%s' "$DM_FIT_TEXT" | grep -c 'PROJ-1540' | awk '{print ($1>0)?"y":"n"}')" y
ok "shrunk text <= limit" "$([ "$(dm_words "$DM_FIT_TEXT")" -le "$SLACK_LIMIT_SUPPORT" ] && echo y)" y

# Pure prose overrun, no addresses: stage-1 truncation (not the minimal floor) must fit.
prose="$(printf 'Support notification triage:\n%s\n' "$(words_n 900)")"
dm_shrink "$prose" 3 "(Shortened. Full triage: /x/f)"
ok "900-word prose -> truncated path" "$DM_FIT_PATH" truncated
ok "900-word prose truncated passes gate" "$(gate_says "$DM_FIT_TEXT")" pass

lead="$(printf '\n\n%s\n' "$(words_n 200)")"
ok "missing header + blank lines -> header forced to line 1" "$(line1 "$(dm_ensure_header "$lead")")" "Support notification triage:"
ok "minimal floor passes gate" "$(gate_says "$(dm_minimal 5 '(Full triage: /x/f)')")" pass
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
