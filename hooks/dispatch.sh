#!/usr/bin/env bash
# One hook entry that runs a WHOLE matcher block's gates in a single process, instead of
# Claude Code spawning `hook-run.sh` + an inner bash per gate.
#
# Usage (settings.json):
#   bash "$HOME/.claude/hooks/dispatch.sh" "$HOME/.claude/hooks/dispatch-<block>.manifest"
#
# Why (<harnessEpicKey>, 2026-09-18): a single Bash tool call had grown to 76 hook commands
# (49 PreToolUse + 21 PostToolUse on Bash|PowerShell, + 6 on combined Jira/* matchers), each
# its own process tree. Measured on an IDLE box: ~40ms per exec, ~57ms per gate => ~4s of
# pure tax per shell command; under real concurrent load the same spawn storm degrades
# per-exec cost to 777-8,739ms (harness-gaps, session 9149fa95), which is where the observed
# 30-40s per tool call came from. The count is the problem, not the per-exec cost, so this
# cuts the count.
#
# How the count drops: every Bash-matched gate already opens with a pure-bash needle test on
# the RAW payload (`case "$payload" in *foo*) ;; *) exit 0 ;; esac` -- the convention in
# GATES-AND-HOOKS.md "Hook fork budget"). Those needles are extracted ONCE into a cache and
# evaluated here in-process, so a gate that would have exited on its own needle never gets
# spawned at all. Measured selectivity over 44 unique gates: `echo hello world` runs 6,
# `cat $HOME/.claude/memory/foo.md` runs 8, a `git commit` runs 13. 44 -> 6-13.
#
# SAFETY -- the failure this design must not have is "gate silently never fires, call runs
# unguarded, looks exactly like a pass" (GATES-AND-HOOKS.md records that class as unexplained
# for psql/mongo). Three defences:
#   1. A gate whose needle cannot be parsed is ALWAYS run (fail-open to today's behaviour).
#   2. `scripts/check-dispatch-equivalence.sh` replays every payload the check-gates suite
#      exercises and asserts: if a gate DECIDES on a payload, that gate's needle MUST match
#      it. A needle that is too broad only costs a spawn; one that is too narrow is the bug.
#   3. The cache is rebuilt whenever any gate is newer than it, so editing a gate's needle
#      cannot leave a stale skip behind.
#
# Each gate still gets its own `timeout`, from the manifest. One slow gate must not eat the
# whole block's budget -- under a single dispatcher a chain-wide timeout would fail EVERY
# gate open at once, which is the enforcement gap above, industrialised.
#
# Like hook-run.sh (which this replaces for dispatched blocks), the dispatcher is the only
# process holding Claude Code's stdio pipes; gates get files. See hook-run.sh's header for
# the 50-min "Percolating..." incident that requires this.
set -u

manifest="${1:-}"
[ -n "$manifest" ] && [ -f "$manifest" ] || exit 0

# Parameter expansion, not `dirname`/`basename` forks (two processes per dispatch, every
# Bash call, each one scanned by Defender -- <harnessEpicKey>, 2026-10-12).
HOOKS="${manifest%/*}"; [ "$HOOKS" = "$manifest" ] && HOOKS="."
manifest_base="${manifest##*/}"
IFS= read -r -d '' payload || true
[ -n "$payload" ] || exit 0

# Event + session, by bash regex (no fork). PostToolUse blocks speak `{decision:"block",
# reason}`, so the merge at the bottom must emit that dialect for them; and every gate run
# leaves a breadcrumb line (see GATES-AND-HOOKS.md "gate-invocations.log") so "ran and
# allowed", "killed by its timeout" and "never invoked" stop being byte-identical -- the
# fail-open class harness-gaps recorded three times before anything could see it.
ev="PreToolUse"
[[ $payload =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]+)\" ]] && ev="${BASH_REMATCH[1]}"
sid8=""
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{8}) ]] && sid8="${BASH_REMATCH[1]}"
# Needles are matched against the payload WITHOUT its transcript_path. That path always
# contains `.claude` and `.jsonl`, so needles like `*.claude*` (inplace-edit,
# claude-dir-clutter) and `*.js*` (running-script-edit) matched every call and spawned their
# gates for nothing (<harnessEpicKey>, 2026-10-12). Gates still receive the full payload.
# Same for `scratchpad_dir` (holds the 8.3 `RYAN~1.STE` -> short-path-gate's `*~[0-9]*` hit
# every call) and the Bash `description` (`*cd*` hit "description" -> bare-cd-gate ran on every
# call) -- 2026-10-22. No gate decides on either value.
# Pure parameter expansion -- a greedy regex here would backtrack on large payloads.
np="$payload"
for _tk in '"transcript_path"' '"scratchpad_dir"' '"description"'; do
  case "$np" in
    *"$_tk"*)
      _pre="${np%%"$_tk"*}"; _rest="${np#*"$_tk"}"
      _rest="${_rest#*\"}"; _rest="${_rest#*\"}"   # past the value's opening, then closing quote
      np="$_pre$_rest"
      ;;
  esac
done
# Needles also see the CONTENTS of any scratch script the command runs. Six gates scan the
# referenced script (lib-scan-script-refs.sh) because `bash scratch/x.sh` is the shape the
# harness itself recommends, so their needles carried `*scratch*|*Temp/claude*` and every
# scratch-script call spawned all of them -- ~950 calls x 5 gates on 2026-10-14, a third of
# all gate runs, nearly every one exiting after its own scan found nothing.
# build-needle-cache.sh now drops those root alternatives and the script text is matched
# here instead, so a gate runs only when its real keyword appears in the command OR the
# script. Mirrors the lib's resolution ($HOME/~ forms, scratch roots only, 64 KB cap) with
# builtins: no fork. Only the part before tool_response is tokenised -- a PostToolUse
# payload can carry 30 KB of command output.
case "$np" in
  *scratch*|*Temp/claude*|*Temp\\claude*|*Temp\\\\claude*|*temp/claude*)
    _head="${np%%\"tool_response\"*}"
    set -f
    _q='"'
    for _tok in $_head; do
      case "$_tok" in *scratch*|*Temp/claude*|*Temp\\claude*|*Temp\\\\claude*|*temp/claude*) ;; *) continue ;; esac
      # The token is raw JSON: the command's own quotes arrive escaped, a bare quote is the
      # string boundary, and the last token drags `","description":"...` along with it. Cut
      # at the bare quotes either side of the scratch root (escaped ones parked in \1 first).
      _c="${_tok//\\\"/$'\1'}"
      _c="${_c//\\\\//}"          # JSON-escaped backslashes -> /
      for _r in scratch Temp/claude temp/claude; do
        case "$_c" in *"$_r"*) ;; *) continue ;; esac
        _b="${_c%%"$_r"*}"; _a="${_c#*"$_r"}"
        _b="${_b##*\"}"; _a="${_a%%\"*}"
        _c="$_b$_r$_a"; break
      done
      _c="${_c//$'\1'/$_q}"
      _c="${_c%\\n}"; _c="${_c%\\r}"; _c="${_c%;}"; _c="${_c%,}"; _c="${_c%)}"
      _c="${_c#\"}"; _c="${_c%\"}"; _c="${_c#\'}"; _c="${_c%\'}"
      case "$_c" in
        '$HOME'/*)   _c="$HOME/${_c#\$HOME/}" ;;
        '${HOME}'/*) _c="$HOME/${_c#\$\{HOME\}/}" ;;
        '~'/*)       _c="$HOME/${_c#\~/}" ;;
        [A-Za-z]:/*) _d="${_c:0:1}"; _c="/${_d,,}${_c:2}" ;;
      esac
      case "$_c" in *'$'*|*'`'*|*'*'*|*'?'*) continue ;; esac
      [ -f "$_c" ] || continue
      _s=""; IFS= read -r -d '' -n 65536 _s < "$_c" 2>/dev/null || true
      np="$np"$'\n'"$_s"
    done
    set +f
    ;;
esac
crumbs="$HOME/.claude/harness-state/logs/gate-invocations.log"
[ -d "${crumbs%/*}" ] || mkdir -p "${crumbs%/*}" 2>/dev/null

d="$HOME/.claude/scratch/hook-run"
[ -d "$d" ] || mkdir -p "$d" 2>/dev/null || d="/tmp"
in="$d/disp-$$.in"; out="$d/disp-$$.out"; err="$d/disp-$$.err"
printf '%s' "$payload" > "$in"

cache="$HOME/.claude/harness-state/hooks/needle-cache-$manifest_base.tsv"
[ -d "${cache%/*}" ] || mkdir -p "${cache%/*}" 2>/dev/null

# Rebuild the needle cache when any gate (or the manifest) is newer than it.
stale=1
if [ -f "$cache" ]; then
  # A glob + `-nt` in-process, not `find` (one fork per dispatch, <harnessEpicKey>,
  # 2026-10-12). History this must not regress: the `find` version once ran without `-L`
  # against ~/.claude/hooks, which is a SYMLINK into the harness repo, matched NOTHING, and
  # froze the cache for weeks -- every needle edit silently ignored, the "gate never fires,
  # looks exactly like a pass" failure this header forbids (found 2026-09-22). A bash glob
  # walks through the symlinked directory and `-nt` stats the targets, so both halves of
  # that trap are structurally gone; check-gates still asserts a touched gate rebuilds.
  stale=0
  [ "$manifest" -nt "$cache" ] && stale=1
  if [ "$stale" = 0 ]; then
    for _g in "$HOOKS"/*.sh; do
      [ "$_g" -nt "$cache" ] && { stale=1; break; }
    done
  fi
fi
[ "$stale" = 1 ] && bash "$HOOKS/build-needle-cache.sh" "$manifest" "$cache" 2>/dev/null

# Load the cache into parallel arrays -- pure bash, no forks. Every column is non-empty by
# construction (`-` for "no args"): bash classes a tab in IFS as whitespace and COLLAPSES
# consecutive tabs, so an empty column shifts the rest left and the needle lands in the args
# slot -- which silently turns every gate into @ALWAYS and defeats the whole prefilter.
declare -a G_NAME=() G_ARGS=() G_TO=() G_PAT=()
cr=$'\r'
while IFS=$'\t' read -r g_to g_name g_args g_pats; do
  g_to="${g_to%$cr}"; g_name="${g_name%$cr}"; g_args="${g_args%$cr}"; g_pats="${g_pats%$cr}"
  [ -n "${g_name:-}" ] || continue
  [ "${g_args:-}" = "-" ] && g_args=""
  G_NAME+=("$g_name"); G_ARGS+=("$g_args"); G_TO+=("${g_to:-20}"); G_PAT+=("${g_pats:-@ALWAYS}")
done < "$cache"

rc_final=0
merged_err=""
# n_out tracks the count rather than ${#json_out[@]}: under `set -u` this box's bash errors
# on the length of a declared-but-empty array, and the empty case is the common one.
n_out=0
declare -a json_out=()

i=0
n=${#G_NAME[@]}
while [ "$i" -lt "$n" ]; do
  name="${G_NAME[$i]}"; args="${G_ARGS[$i]}"; to="${G_TO[$i]}"; pats="${G_PAT[$i]}"
  i=$((i+1))
  [ -f "$HOOKS/$name" ] || continue

  # Needle prefilter. @ALWAYS = no parseable needle, so run it (defence 1 above).
  #
  # The pattern is eval'd rather than split on `|` and matched piecewise, so that BASH does
  # the parse -- identical to the `case` in the gate the pattern was copied from. Splitting
  # and re-quoting it by hand is what silently converted unanalyzable-script-gate.sh's
  # `*'\n'*` (literal backslash-n) into `*\n*` (a glob-escaped `n`). build-needle-cache.sh
  # refuses to emit any pattern containing $( ) ` ; & < >, so nothing here can run a command.
  #
  # `@LIT a|b|c` is the no-eval path: build-needle-cache.sh emits it when every alternative
  # was a fully single-quoted glob, i.e. the gate's own `case` was a plain substring test.
  # Matched with a QUOTED `case` pattern so bash does no glob or parameter expansion on the
  # needle at all -- which is how the patterns containing `$(` and a backtick can be honoured
  # instead of refused. The encoding guarantees no literal contains `|`.
  if [ "$pats" != "@ALWAYS" ]; then
    matched=0
    case "$pats" in
      "@LIT "*)
        lits="${pats#@LIT }"
        oldifs="$IFS"; IFS='|'
        for lit in $lits; do
          case "$np" in *"$lit"*) matched=1; break ;; esac
        done
        IFS="$oldifs"
        ;;
      *)
        eval "case \"\$np\" in $pats) matched=1 ;; *) matched=0 ;; esac" 2>/dev/null || matched=1
        ;;
    esac
    [ "$matched" = 1 ] || continue
  fi

  : > "$out"; : > "$err"
  # `-k 2`: a gate blocked on a hung native child defers SIGTERM, so plain `timeout` left it
  # running for hours -- 5 such orphans held forks on 2026-10-22 (<harnessEpicKey>). KILL -> 137.
  if [ -n "$args" ]; then
    timeout -k 2 "$to" bash "$HOOKS/$name" $args < "$in" > "$out" 2> "$err"
  else
    timeout -k 2 "$to" bash "$HOOKS/$name" < "$in" > "$out" 2> "$err"
  fi
  rc=$?
  [ "$rc" = 137 ] && rc=124
  # Breadcrumb: epoch, event, gate, rc (124 = timed out), session shortid. Builtins only.
  printf '%s\t%s\t%s\t%s\t%s\n' "$EPOCHSECONDS" "$ev" "$name" "$rc" "${sid8:--}" >> "$crumbs" 2>/dev/null

  o="$(<"$out")"; e="$(<"$err")"
  # 124 = timeout killed it. Fail open, exactly as a Claude-Code-killed hook does today,
  # but say so on stderr so it is visible rather than silent -- EXCEPT a gate whose header
  # declares `# dispatch: fail-closed-on-timeout` (the production gates): 11 live timeouts on
  # 2026-10-15 alone (standby, a background suite) each let a command through, and a prod
  # deploy runs on the same clock. Marker read with builtins, only on this rare path.
  if [ "$rc" = 124 ]; then
    fc=0; ln=0
    while IFS= read -r line && [ "$ln" -lt 40 ]; do
      ln=$((ln+1))
      case "$line" in
        *'dispatch: fail-closed-on-timeout-unless-nonprod'*) fc=2; break ;;
        *'dispatch: fail-closed-on-timeout'*) fc=1; break ;;
      esac
    done < "$HOOKS/$name"
    # fc=2 (all-env DB write gates): the gate never got to classify the env, so classify from
    # the text (command + referenced scripts): names production or names no env -> deny;
    # names only qa/staging -> fail open (user decision 2026-10-20).
    if [ "$fc" = 2 ]; then
      lcp="${np,,}"
      case "$lcp" in
        *production*|*prod-v1*|*prod_v1*) fc=1 ;;
        *staging*|*qa-v1*|*qa_v1*|*ama_qa*|*" qa "*) fc=0 ;;
        *) fc=1 ;;
      esac
    fi
    if [ "$fc" = 1 ] && [ "$ev" = PreToolUse ]; then
      json_out+=("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$name timed out after ${to}s and FAILS CLOSED -- it guards production, so a timeout is not a pass. The machine is slow right now (bash ~/.claude/scripts/proc-start-latency.sh; a background check-gates run, a Defender investigation or a fresh wake all do this): retry when it answers, or use the gate's own hatch after the user's explicit yes.\"}}")
      n_out=$((n_out+1))
      merged_err="${merged_err}[dispatch] $name exceeded ${to}s -- DENIED (fails closed)."$'\n'
    else
      merged_err="${merged_err}[dispatch] $name exceeded ${to}s and was skipped (failed open)."$'\n'
    fi
    continue
  fi
  [ -n "$e" ] && merged_err="${merged_err}${e}"$'\n'
  [ -n "$o" ] && { json_out+=("$o"); n_out=$((n_out+1)); }
  # exit 2 is the hard-block channel (only 4 gates use it). Never short-circuit -- run every
  # matching gate so the user sees every objection, not just the first.
  [ "$rc" = 2 ] && rc_final=2
done

: > "$in"; : > "$out"; : > "$err"
rm -f "$in" "$out" "$err" 2>/dev/null

[ -n "$merged_err" ] && printf '%s' "$merged_err" >&2

# stdout merge. Zero gates spoke -> zero forks, the overwhelmingly common case.
case "$n_out" in
  0) : ;;
  1) printf '%s' "${json_out[0]}" ;;
  *)
    # Two or more gates spoke. Precedence deny > ask > context-only; reasons concatenated.
    # Never synthesize `permissionDecision: "allow"` -- an explicit allow can override a
    # sibling's `ask` (GATES-AND-HOOKS.md, "Hook wiring" traps).
    #
    # `.reason` is read as well as `.hookSpecificOutput`: some gates speak the PostToolUse
    # `{decision:"block", reason}` dialect (check-gates.sh's reason_of reads both), and
    # dropping it here would silently swallow that gate's objection.
    #
    # If jq fails -- one gate emitted something that is not JSON -- do NOT swallow the batch.
    # Failing open across a whole block is exactly the enforcement gap this design exists to
    # avoid, so fall back to emitting the first decision verbatim and say so on stderr.
    merged="$(printf '%s\n' "${json_out[@]}" | jq -s -c --arg ev "$ev" '
      map(select(type == "object")) as $all
      # PostToolUse dialect: {decision:"block", reason} (reminders), plus optional
      # hookSpecificOutput.additionalContext. Concatenate every reason; never drop one.
      | if $ev == "PostToolUse" then
          ($all | map(select(.decision == "block") | .reason // "") | map(select(. != ""))) as $blk
          | ($all | map(.hookSpecificOutput.additionalContext // "") | map(select(. != "")) | join("\n\n")) as $ctx
          | if ($blk | length) > 0 then { decision: "block", reason: (($blk + (if $ctx != "" then [$ctx] else [] end)) | join("\n\n")) }
            elif $ctx != "" then { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $ctx } }
            else empty end
        else .
      | ($all | map(.hookSpecificOutput // {})) as $h
      | ($all | map(select(.decision == "block") | .reason // "") | map(select(. != ""))) as $blk
      | ($h | map(select(.permissionDecision == "deny"))) as $deny
      | ($h | map(select(.permissionDecision == "ask")))  as $ask
      | ($h | map(select(.additionalContext != null) | .additionalContext) | join("\n\n")) as $ctx
      | ($h | .[0].hookEventName // "PreToolUse") as $ev
      | if ($deny | length) > 0 or ($blk | length) > 0 then
          { hookSpecificOutput: { hookEventName: $ev, permissionDecision: "deny",
            permissionDecisionReason: (($deny | map(.permissionDecisionReason // "")) + $blk | map(select(. != "")) | join("\n\n")) } }
        elif ($ask | length) > 0 then
          { hookSpecificOutput: { hookEventName: $ev, permissionDecision: "ask",
            permissionDecisionReason: ($ask | map(.permissionDecisionReason // "") | join("\n\n")) } }
        elif ($ctx | length) > 0 then
          { hookSpecificOutput: { hookEventName: $ev, additionalContext: $ctx } }
        else empty end
        end
    ' 2>/dev/null)"
    if [ -n "$merged" ]; then
      printf '%s' "$merged"
    else
      # jq failed or produced nothing: emit the first gate's output verbatim rather than
      # dropping every decision in the block.
      printf '[dispatch] could not merge %s gate outputs; emitting the first verbatim.\n' "$n_out" >&2
      printf '%s' "${json_out[0]}"
    fi
    ;;
esac

# Process-start latency sample, at most once a minute per machine: the symptom itself
# (bash.exe took 444-1797 ms to start during the 2026-10-12 spell, ~60 ms normally), timed
# on the hooks' own spawn path. Deliberately NOT in console-window-watch.ps1: that task's
# wscript -> hidden powershell chain spawning a shell every minute is the shape EDR flags,
# so a probe there could raise the investigations it measures. scripts/proc-start-latency.sh
# joins the samples with defender-activity.log's SenseIR intervals. One extra fork a minute;
# the marker holds the last sample's epoch (builtin read, no stat).
_lat="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/logs/proc-start-latency.log"
_lm="${_lat%/*}/.proc-start-latency-last"
# Marker: "<epoch of last sample> <its ms> <the one before>" -- the previous two samples are
# what make a spell recognisable without reading the log back.
_last=0; _prev=0; _prev2=0; [ -f "$_lm" ] && IFS=' ' read -r _last _prev _prev2 < "$_lm" 2>/dev/null
case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
case "$_prev" in ''|*[!0-9]*) _prev=0 ;; esac
case "$_prev2" in ''|*[!0-9]*) _prev2=0 ;; esac
if [ $((EPOCHSECONDS - _last)) -ge 60 ]; then
  printf '%s %s %s' "$EPOCHSECONDS" "$_prev" "$_prev2" > "$_lm" 2>/dev/null
  _t0=$EPOCHREALTIME
  bash -c true 2>/dev/null
  _t1=$EPOCHREALTIME
  _ms=$(( (${_t1//[.,]/} - ${_t0//[.,]/}) / 1000 ))
  # Per-file scan wait, apart from process start (<harnessEpicKey>, 2026-10-15): rewrite a small
  # file where this dispatcher keeps its own temp files and read it back, builtins only, AFTER
  # the bash sample so its scan cannot inflate that one. A modified file is rescanned -- on the
  # write's close or the read's open, so the analysis uses the ROUND TRIP (write + read) --
  # UNVALIDATED until scripts/spell-milestones.sh finds a hot recording whose scan of scnprobe.in
  # shows up in a timed round trip (an 8.3-safe name reads the same in long and short paths).
  # Microseconds; the bash-start field stays second because the
  # trigger and proc-start-latency.sh parse it.
  _fp="$d/scnprobe.in"
  _t2=$EPOCHREALTIME
  printf 'probe %s\n' "$_t2" > "$_fp" 2>/dev/null
  _t3=$EPOCHREALTIME
  _fx=""; IFS= read -r _fx < "$_fp" 2>/dev/null
  _t4=$EPOCHREALTIME
  printf '%(%Y-%m-%dT%H:%M:%S)T bash-start=%sms file-write=%sus file-read=%sus\n' -1 "$_ms" \
    "$(( ${_t3//[.,]/} - ${_t2//[.,]/} ))" "$(( ${_t4//[.,]/} - ${_t3//[.,]/} ))" >> "$_lat" 2>/dev/null
  printf '%s %s %s' "$EPOCHSECONDS" "$_ms" "$_prev" > "$_lm" 2>/dev/null
  # A spell = one sample >= 700 ms, or two of the last three >= 400 ms (12 Oct: 444-1797 ms;
  # the 2026-10-15 lags were single spikes of 786-1033 ms that "two in a row" missed, while a
  # lone 500 ms is common) -> hooks/defender-hot-trigger.sh starts the elevated 120 s Defender
  # recording (30-min cooldown + 2/day there). One fork, only then; stdio detached so nothing
  # can hold the hook pipe.
  _slow=0; [ "$_ms" -ge 400 ] && _slow=1; [ "$_prev" -ge 400 ] && _slow=$((_slow+1)); [ "$_prev2" -ge 400 ] && _slow=$((_slow+1))
  if [ "$_ms" -ge 700 ] || [ "$_slow" -ge 2 ]; then
    bash "$HOOKS/defender-hot-trigger.sh" "bash-start=${_prev2},${_prev},${_ms}ms" >/dev/null 2>&1 </dev/null
  fi
  # Spell milestones (2026-10-15): a slow sample marks a spell pending; once the last one is
  # 15 min old (spell over, the watcher's counters in), or the elevated recording log has
  # changed, scripts/spell-milestones.sh runs DETACHED -- logs the milestone and files a durable
  # reminder for the investigation's session. The marker flips to "ran" before the launch so
  # the next sample cannot start it twice; the script holds its own lock. Builtins until then.
  _sp="${_lat%/*}/.spell-pending"; _sr="${_lat%/*}/.spell-milestones-ran"; _spe=""; _go=0
  [ "$_ms" -ge 400 ] && printf '%s' "$EPOCHSECONDS" > "$_sp" 2>/dev/null
  [ -f "$_sp" ] && IFS= read -r _spe < "$_sp" 2>/dev/null
  case "$_spe" in ''|*[!0-9]*) ;; *) [ $((EPOCHSECONDS - _spe)) -ge 900 ] && { printf 'ran %s' "$_spe" > "$_sp" 2>/dev/null; _go=1; } ;; esac
  _adm="${DEFENDER_HOT_ADMIN_LOG:-/c/ProgramData/AMA-Harness/defender-hot/defender-hot.log}"
  [ -f "$_adm" ] && [ "$_adm" -nt "$_sr" ] && { : > "$_sr" 2>/dev/null; _go=1; }
  if [ "$_go" = 1 ]; then
    nohup bash "${SPELL_MILESTONES_SCRIPT:-$HOME/.claude/scripts/spell-milestones.sh}" check >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi
fi

exit "$rc_final"
