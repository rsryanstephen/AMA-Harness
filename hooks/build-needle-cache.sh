#!/usr/bin/env bash
# Builds dispatch.sh's needle cache from a dispatch manifest. Run automatically by
# dispatch.sh whenever any gate is newer than the cache; safe to run by hand.
#
#   bash build-needle-cache.sh <manifest> <cache-out>
#
# Manifest line:  <timeout>\t<gate.sh>\t<args>        (`-` when there are no args)
# Cache line:     <timeout>\t<gate.sh>\t<args>\t<pat1|pat2|...>   (or @ALWAYS)
#
# No column is ever empty. Bash classes a tab in IFS as whitespace, so `read -r a b c d`
# COLLAPSES consecutive tabs -- an empty middle column shifts every later field left, and
# the needle silently lands in the args slot. See gen-dispatch-manifest.sh's header.
#
# The needle is read OUT of the gate, never duplicated here -- a hand-maintained needle
# table would go stale the moment someone edited a gate, and a stale skip means the gate
# silently never fires while the call looks exactly like a pass. We only extract a needle
# from the gate's first `case "$payload" in` block, and only when that block has a `*)`
# branch that exits 0 -- i.e. it provably is a "no match, nothing to do" prefilter and not
# some other dispatch on the payload. Anything we cannot parse with confidence becomes
# @ALWAYS, which runs the gate exactly as today.
set -u

manifest="${1:-}"; cache="${2:-}"
[ -n "$manifest" ] && [ -n "$cache" ] || { echo "usage: build-needle-cache.sh <manifest> <cache>" >&2; exit 1; }
HOOKS="$(dirname "$manifest")"

extract() {
  # stdout: the gate's needle as a bash case-pattern list (`a|b|c`), VERBATIM from source --
  # quotes and all. Nothing (exit 1) when there is no confident prefilter.
  #
  # Two rules, both learned from check-dispatch-equivalence.sh catching 7 real silent drops:
  #
  # 1. OR together EVERY `case "$payload"` prefilter in the file, not just the first.
  #    octopus-lambda-delete-gate.sh has two -- `*delete-function*` inside a conditional at
  #    line 31, and `*deployments*` at top level at line 42. Taking only the first missed
  #    every deployment payload the gate actually decides on. Over-matching costs one spawn;
  #    under-matching runs the call UNGUARDED, so OR is the safe direction.
  #
  # 2. Do NOT strip the quotes and re-interpret. unanalyzable-script-gate.sh's needle is
  #    `*'\n'*` -- a literal backslash then n. Stripping the quotes left `*\n*`, where the
  #    backslash is a glob escape meaning a bare `n`: a different pattern entirely, and one
  #    that silently stopped matching multi-line commands. The text is kept exactly as
  #    written and dispatch.sh `eval`s it as a case pattern, so bash applies the same parse
  #    the gate itself does. That is also why the unsafe-character refusal below exists --
  #    these strings reach `eval`.
  local gate="$1" blk
  # Handles both shapes: the one-liner `case "$payload" in *x*) ;; *) exit 0 ;; esac` and the
  # multi-line form where `case "$payload" in` sits alone and the branches follow.
  blk="$(awk '
    {
      line = $0
      # Drop whole-line comments BEFORE buffering. The buffer concatenates every line
      # between `case` and `esac`, so a comment sitting above the pattern line used to be
      # glued onto the front of it and the branch-head cut below then found nothing.
      # shell-write-bypass-gate.sh -- the most expensive gate in the set -- was @ALWAYS for
      # exactly this reason, with a perfectly good needle two lines further down. Only a
      # leading `#` counts: a `#` mid-pattern is a legitimate glob character.
      if (line ~ /^[ \t]*#/) next
      if (!inblk) {
        if (match(line, /case[ \t]+"\$payload"[ \t]+in/)) {
          inblk = 1
          line = substr(line, RSTART + RLENGTH)
        } else next
      }
      if (line ~ /esac/) { sub(/esac.*/, "", line); buf = buf " " line; print buf; buf = ""; inblk = 0; next }
      buf = buf " " line
    }
  ' "$gate" 2>/dev/null)"
  [ -n "${blk// /}" ] || return 1
  # Must have a catch-all that bails, else this is not a prefilter.
  case "$blk" in *'*)'*) : ;; *) return 1 ;; esac
  case "$blk" in *'exit 0'*) : ;; *) return 1 ;; esac

  local pats
  # Scratch-root alternatives (`*scratch*`, `*Temp/claude*`, either separator) are DROPPED:
  # the gates that scan a referenced script carry them so that `bash scratch/x.sh` reaches
  # the scan, but as a needle they spawn every such gate on every scratch-script call.
  # dispatch.sh appends the referenced script's text to what the needle is matched against,
  # so the remaining keywords still catch a write hidden in the script (2026-10-14).
  #
  # Cut each `;`-delimited chunk at its first UNQUOTED `)` -- the branch head -- tracking
  # quote state character by character. The previous form was
  # `grep -E '^\(?[^[:space:]]*\)'`, which required no whitespace anywhere before the `)`
  # and therefore silently dropped every needle with a space inside quotes:
  # trace-secret-gate.sh's `*" -x"*` and dev-server-teardown-reminder.sh's `*"ng serve"*`
  # were both @ALWAYS purely because their patterns contain a space. A chunk with no
  # unquoted `)` is not a branch head and prints nothing, which is the old behaviour for
  # trailing body text like ` exit 0 `.
  pats="$(printf '%s\n' "$blk" \
    | tr ';' '\n' \
    | awk '
      {
        s = $0
        sub(/^[ \t]+/, "", s)
        if (s == "") next
        if (substr(s, 1, 1) == "(") s = substr(s, 2)
        q = ""; out = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (q != "") { if (c == q) q = ""; out = out c; continue }
          if (c == "\"" || c == "'"'"'") { q = c; out = out c; continue }
          if (c == ")") { print out; next }
          out = out c
        }
      }
    ' \
    | tr '|' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' \
    | grep -vx '\*' \
    | grep -vE 'scratch|[Tt]emp(/|\\+)claude' \
    | sort -u \
    | paste -sd '|' -)"
  [ -n "$pats" ] || return 1

  # LITERAL path, tried first. When EVERY alternative is a fully single-quoted glob --
  # `*'...'*` with no quote inside -- the gate's own `case` is doing a plain substring test,
  # because single quotes suppress every glob metacharacter. dispatch.sh can then match it
  # with a quoted `case` and no `eval` at all, which is strictly safer than the eval path
  # below AND recovers the patterns the refusal rightly rejects: substitution-stdin-hang-
  # gate.sh's needle is `*'$('*|*'`'*`, the most selective in the whole set (almost no
  # command contains `$(`), and it was @ALWAYS solely because those characters cannot be
  # eval'd. The literals are carried verbatim, so unanalyzable-script-gate.sh's `*'\n'*`
  # stays a literal backslash-then-n exactly as the gate means it.
  #
  # Emitted as `@LIT <lit>|<lit>|...`. A literal containing `|` or a tab would be ambiguous
  # in that encoding, and an empty one would match everything, so any of those falls through
  # to the eval path (and from there, if need be, to @ALWAYS).
  local alt lit lits="" all_lit=1
  local oldifs="$IFS"
  IFS='|'
  for alt in $pats; do
    case "$alt" in
      \*\'*\'\*) : ;;
      *) all_lit=0 ;;
    esac
    [ "$all_lit" = 1 ] || break
    lit="${alt#\*\'}"; lit="${lit%\'\*}"
    case "$lit" in ''|*"'"*|*'|'*|*"	"*) all_lit=0 ;; esac
    [ "$all_lit" = 1 ] || break
    lits="${lits}${lits:+|}${lit}"
  done
  IFS="$oldifs"
  if [ "$all_lit" = 1 ] && [ -n "$lits" ]; then
    printf '@LIT %s' "$lits"
    return 0
  fi

  # These strings are eval'd as case patterns. Anything that could RUN something is refused
  # outright; the gate then falls back to @ALWAYS, which is only today's behaviour.
  #
  # The test is on UNQUOTED occurrences only. Checking the joined string blindly refused
  # patterns whose metacharacter is inert because the gate itself quoted it -- e.g.
  # octopus-config-push-reminder.sh's `*'>'*harness-config.json*`, where the `>` is inside
  # single quotes and eval re-parses it as the literal it is. The whole point of eval'ing the
  # text verbatim is that bash applies the same parse the gate does; the refusal has to
  # respect the same quoting, or it throws away correct needles.
  if printf '%s' "$pats" | awk '
      { q = ""
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (q != "") { if (c == q) q = ""; continue }
          if (c == "\"" || c == "'"'"'") { q = c; continue }
          if (c == "`" || c == ";" || c == "&" || c == "<" || c == ">") { exit 1 }
          if (c == "$" && substr($0, i + 1, 1) == "(") { exit 1 }
        }
      } END { exit 0 }'; then
    :
  else
    return 1
  fi
  printf '%s' "$pats"
}

[ -d "${cache%/*}" ] || mkdir -p "${cache%/*}" 2>/dev/null

# Incremental: re-extract only the gates that are newer than the existing cache. A full
# rebuild forks awk+sed+grep+tr+paste per gate and measured ~10s over 38 gates -- far too
# slow to sit in dispatch.sh's hot path, where ANY gate edit triggers it. Reusing unchanged
# rows makes the usual rebuild cost one gate, not thirty-eight.
declare -A OLD
cr=$'\r'
# Reuse is keyed on each GATE's mtime, which is blind to a change in THIS file -- and this
# file is what decides the needle. Editing the extractor then left every previously-@ALWAYS
# row @ALWAYS forever, because no gate had changed: the rebuild ran and reused all the wrong
# answers. Caught 2026-09-22 while fixing exactly that. Self newer than the cache => full
# re-extract, no reuse.
if [ -f "$cache" ] && [ "${BASH_SOURCE[0]}" -nt "$cache" ]; then
  rm -f "$cache" 2>/dev/null
fi
if [ -f "$cache" ]; then
  while IFS=$'\t' read -r o_to o_gate o_args o_pats; do
    o_gate="${o_gate%$cr}"; o_pats="${o_pats%$cr}"
    [ -n "${o_gate:-}" ] && OLD["$o_gate"]="$o_pats"
  done < "$cache"
fi

tmp="$cache.tmp.$$"
: > "$tmp"
while IFS=$'\t' read -r to gate args; do
  # jq.exe emits CRLF and `read` does NOT strip it (GATES-AND-HOOKS.md, fork budget) -- a
  # stray \r in a gate name makes every `[ -f ]` below fail and silently yields @ALWAYS.
  to="${to%$cr}"; gate="${gate%$cr}"; args="${args%$cr}"
  [ -n "${gate:-}" ] || continue
  case "$gate" in \#*) continue ;; esac
  pats=""
  if [ -f "$HOOKS/$gate" ]; then
    # Reuse the cached needle when the gate has not changed since the cache was written.
    if [ -n "${OLD[$gate]:-}" ] && [ ! "$HOOKS/$gate" -nt "$cache" ]; then
      pats="${OLD[$gate]}"
    else
      pats="$(extract "$HOOKS/$gate" || true)"
    fi
  fi
  [ -n "$pats" ] || pats="@ALWAYS"
  printf '%s\t%s\t%s\t%s\n' "${to:-20}" "$gate" "${args:--}" "$pats" >> "$tmp"
done < "$manifest"

mv -f "$tmp" "$cache" 2>/dev/null || { cat "$tmp" > "$cache"; rm -f "$tmp"; }
