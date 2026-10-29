#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). Adding a key to harness-config.json means THREE files --
# the live config, harness-config.example.json, and harness-setup/SKILL.md's enumerated
# keys. Nothing enforced that: `releaseNotes.greetingNames` went live and was in NEITHER of
# the other two, so a new adopter would never be prompted for it, would get no template
# entry, and would first meet it as an ask-the-user prompt while drafting a client-facing
# release email. Same class as the settings.template.json-vs-live drift
# check-settings-parity.sh exists for, and the same reason CLAUDE.md's "Mechanical Triggers
# Over Self-Recognition" rule applies: the three-file rule was written down and still missed.
#
# Sibling of readme-currency-gate.sh, deliberately narrow so the two don't overlap: that one
# asks "does AGENTS.md still describe this file", this one asks "do the adopter-facing copies
# know about this key". Reuses that hook's PostToolUse decision:"block" mechanism, which is
# confirmed to reach the model, and its .session-chatfiles nudge-state convention.
#
# Checks BOTH directions since 2026-08-28: live-only keys (adopter files blind) AND
# example-only keys (live config silently lacks something the schema has -- was one-way,
# `aws.redshiftClusterId` sat missing live and nothing flagged it).
set -u

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$sid" ] && [ -n "$file_path" ] || exit 0

# Same normalisation readme-currency-gate.sh uses, for the same reason: the path can arrive
# in either slash form and either case, via the ~/.claude symlink or the real repo path.
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'; }
case "$(norm "$file_path")" in */harness-config.json) : ;; *) exit 0 ;; esac

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0
# Overridable for tests only -- the real files are the defaults. Without a seam the suite can
# only assert the SILENT direction (the clean tree), and a detector proven only by "it says
# nothing" is the shape this repo's own gate-suite header warns about. Same seam convention as
# lib-session-liveness.sh's CLAUDE_PROJECTS_DIR.
live="${CFGPARITY_LIVE:-$HOME/.claude/harness-config.json}"
example="${CFGPARITY_EXAMPLE:-$harness/harness-config.example.json}"
setup="${CFGPARITY_SETUP:-$harness/skills/harness-setup/SKILL.md}"
[ -f "$live" ] && [ -f "$example" ] || exit 0

# Key paths, NOT data. Array indices are dropped, and a path is truncated at the first
# segment that isn't a plain identifier -- those are map ENTRIES (`greetingNames` is keyed by
# email address, `emailRecipients` by address), so listing each one would report data as
# drift, put real names and addresses in a nudge, and bury the one line that matters. A
# map with a different set of entries either side is not a missing key; a missing map is.
# First cut listed every leaf and produced 19 findings for a config with 2 real gaps.
# Truncation happens INSIDE jq, on intact path segments. Doing it afterwards by splitting the
# joined string on "." was wrong: an email-keyed entry (`<one entry per line; this element only declares the type>`) splits into
# a segment that looks like a plain identifier ("Daniel"), so each map entry still reported
# separately AND leaked a real name. Segments must never be re-split.
keys() {
  jq -r '[paths]
         | map(map(select(type=="string"))) | map(select(length>0))
         | map(reduce .[] as $s ({acc:[],done:false};
             if .done then .
             elif ($s | test("^[A-Za-z][A-Za-z0-9]*$")) then {acc:(.acc+[$s]),done:false}
             else {acc:(.acc+["*"]),done:true} end)
           | .acc | join("."))
         | unique | .[]' "$1" 2>/dev/null | sort -u
}

# Drop a path whose ancestor is already reported -- a whole missing block would otherwise list
# itself plus every key inside it, which is one gap spelled N ways.
collapse() { awk '{ for (p in seen) if (index($0, p ".") == 1) next; seen[$0]; print }' | head -8; }
missing_example="$(comm -23 <(keys "$live") <(keys "$example") | collapse)"
# Reverse direction too: an example-only key means the live config lacks something a fetch
# would fill from the placeholder -- silent drift until 2026-08-20 (`aws.redshiftClusterId`).
missing_live="$(comm -13 <(keys "$live") <(keys "$example") | collapse)"

# harness-setup enumerates config in prose sections, so a nested key is usually covered by
# its parent's paragraph. Only a TOP-LEVEL key the skill never names at all is a real gap
# there -- checking every nested leaf reported 11 keys that the skill does describe, which is
# exactly how a nudge gets trained away (readme-currency-gate.sh's own suppression lesson).
missing_setup=""
if [ -f "$setup" ]; then
  # tr -d '\r': the Git-for-Windows jq (1.5rc1) emits CRLF, so a live key line is `azure\r`
  # while the grep -oE patterns are bare -- `grep -vxF` (whole-line) then never matches and
  # every key false-reports as missing. Strip it on the live side. (Same CRLF class as the
  # on-prompt.sh memory-index fix, 2026-08-20.)
  missing_setup="$(jq -r 'keys[]' "$live" 2>/dev/null | tr -d '\r' \
    | grep -vxF -f <(grep -oE '[A-Za-z][A-Za-z0-9]*' "$setup" | sort -u) 2>/dev/null | head -6 | tr '\n' ' ')"
fi
missing_setup="${missing_setup% }"

[ -n "$missing_example" ] || [ -n "$missing_live" ] || [ -n "$missing_setup" ] || exit 0

# One nudge per distinct missing-set per session: editing the config repeatedly while fixing
# the very thing being reported must not re-nudge on every keystroke.
STATED="$HOME/.claude/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
NUDGEFILE="$STATED/$sid.cfgkeynudge"
h="$(printf '%s|%s|%s' "$missing_example" "$missing_live" "$missing_setup" | md5sum | cut -d' ' -f1)"
[ -f "$NUDGEFILE" ] && grep -qxF "$h" "$NUDGEFILE" 2>/dev/null && exit 0
printf '%s\n' "$h" >> "$NUDGEFILE"

reason="harness-config.json key parity: adding a config key means THREE files (live config, harness-config.example.json, harness-setup/SKILL.md)."
[ -n "$missing_example" ] && reason="$reason Missing from harness-config.example.json: $(printf '%s' "$missing_example" | tr '\n' ' ')."
[ -n "$missing_live" ] && reason="$reason In harness-config.example.json but MISSING from the live config: $(printf '%s' "$missing_live" | tr '\n' ' ') -- add it (re-running scripts/install.ps1 merges example-only keys in as placeholders; octopus-config-sync.sh fetch also fills it; or set it by hand), or drop it from the example if dead."
[ -n "$missing_setup" ] && reason="$reason Top-level key never named in harness-setup/SKILL.md: $missing_setup."
reason="$reason Add the key (with a placeholder value, never a real org identifier) to the example, and to harness-setup's enumerated keys, so a new adopter is prompted for it. If a key is deliberately personal and should never ship, say so in the example file's own comment convention instead of leaving it absent."
# Since 2026-08-20 the example is not just documentation, it is the SCHEMA the Octopus sync
# rebuilds from -- so a key missing there is no longer only a doc gap, it BLOCKS the push.
# Saying so here is what turns this nudge from a nag into the cheaper half of a hard failure.
reason="$reason This is not only a docs gap: harness-config.example.json is the SCHEMA the Octopus sync rebuilds the config from, so octopus-config-sync.sh push will REFUSE (exit 3) until the key exists there -- a value stored under a key the example lacks could never be placed by a fetch and would vanish silently on the next machine. An ARRAY in the example must also carry one element even when empty in practice, or its element type is unknowable; placeholder elements never reach a rebuilt config."

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
