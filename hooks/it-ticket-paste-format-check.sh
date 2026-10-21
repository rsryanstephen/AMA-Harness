#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). An IT-ticket draft is PASTED by the user into IT's
# Jira Service Management portal (a rich-text box), so it must survive a plain-text paste.
#
# Why (2026-10-13): the Defender-exclusions ticket pasted with EVERY wrapped line as its own
# paragraph and `## 2. Why it matters` as literal text -- the box turns each newline into a
# paragraph and renders no Markdown. The it-ticket skill already said "must paste into a
# browser textbox" and banned pipe tables; hard wraps, headings and indentation were not
# covered, and self-recognition did not catch them (CLAUDE.md: mechanical triggers).
#
# Flags, with line numbers (decision:block -> Claude fixes the file; never a gate on the
# write itself, the file is a draft):
#   - hard wrap: a non-blank line directly after another non-blank line, unless it is a
#     `- ` list line (one line per paragraph; lists are the only multi-line blocks)
#   - `#` heading lines (paste as literal hashes) -> plain UPPERCASE title line
#   - leading-space indentation (stripped on paste) -> `- Label: value` lines
#   - fenced ``` blocks and `|` table rows (paste as literal noise)
# Fork-free until the path matches; one jq + one awk after that.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *'IT Tickets'*|*'IT-Ticket-'*) ;; *) exit 0 ;; esac

file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null | tr -d '\r')"
case "$file" in *.md|*.txt) ;; *) exit 0 ;; esac
case "$file" in *'IT Tickets'*|*'IT-Ticket-'*) ;; *) exit 0 ;; esac
[ -f "$file" ] || exit 0

found="$(awk '
  function add(m) { if (n < 8) msg = msg "\n  line " NR ": " m; n++ }
  { sub(/\r$/, "") }
  /^```/                      { add("fenced block -- write the command as a plain line"); prev = $0; next }
  /^#/                        { add("Markdown heading pastes as literal #s -- use a plain UPPERCASE title line") }
  /^\|/                       { add("pipe table row -- one `- Label: value` line per fact") }
  /^[ \t]+[^ \t]/ && $0 !~ /^[ \t]*- / { add("indented line loses its indentation on paste -- use `- Label: value`") }
  $0 != "" && prev != "" && $0 !~ /^- / { add("hard-wrapped paragraph -- join it onto the previous line (one line per paragraph)") }
  { prev = $0 }
  END { if (n) printf "%d%s", n, msg }
' "$file")"
[ -n "$found" ] || exit 0

count="${found%%$'\n'*}"; detail="${found#*$'\n'}"
jq -cn --arg f "${file##*[/\\]}" --arg c "$count" --arg d "$detail" '{
  decision: "block",
  reason: ("IT ticket " + $f + " will paste badly into the IT portal description box (" + $c + " issue(s), first ones below). The box turns every newline into a paragraph and renders no Markdown. Paste-ready shape: one line per paragraph, blank line between paragraphs, plain UPPERCASE section titles, lists and label/value facts as `- ` lines, commands as plain lines. Fix the file now:\n" + $d)
}'
exit 0
