#!/usr/bin/env bash
# PreToolUse hook (mcp__.*__updateConfluencePage). Denies an html-format body write to a
# page known to hold an image nested inside a list item.
#
# Why a gate and not a doc line: commit-ticket-jira/BACKLOG-PAGE.md already told writers to "verify the image
# survived" the write. It never survives -- updateConfluencePage(contentFormat="html")'s
# HTML->ADF converter silently drops a <figure data-type="media-single"> nested in a <li>
# (top-level siblings are fine). So that instruction was a post-mortem dressed as a guard,
# and it failed exactly as you'd expect: 2026-08-17, inserting one ticket into the AMA
# Backlog page destroyed its Terraform screenshot (v88), restored via an ADF write (v89).
# Body written faithfully, version bumped, image gone -- no error anywhere.
#
# The attachment itself is never deleted, only the body reference, so this is recoverable
# -- but only if someone notices, which is the part that can't be relied on.
#
# Pages to protect: .atlassian.pagesWithNestedMedia in harness-config.json (array of page
# ids). Empty/missing -> this gate is inert, which is correct for an adopter with no such
# page. Sibling of symlink-write-gate.sh in spirit: block the silent-corruption path at
# the point of use rather than documenting it and hoping.
set -u

payload="$(cat)"

# Cheap needle check on the RAW payload before any jq fork (~60ms/fork on this machine;
# precedent aggregation-secret-gate.sh). Non-Confluence calls exit on zero forks.
case "$payload" in *updateConfluencePage*|*confluence-update-page.sh*) : ;; *) exit 0 ;; esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
page=""
case "$tool" in
  mcp__*__updateConfluencePage)
    # Only html is lossy. adf carries the media node through, which is the whole fix.
    fmt="$(printf '%s' "$payload" | jq -r '.tool_input.contentFormat // empty' 2>/dev/null | tr -d '\r')"
    [ "$fmt" = "html" ] || exit 0
    page="$(printf '%s' "$payload" | jq -r '.tool_input.pageId // empty' 2>/dev/null | tr -d '\r')"
    ;;
  Bash|PowerShell)
    # Post-MCP-retirement path (2026-08-31): confluence-update-page.sh in storage (XHTML)
    # format. Whether the v2 REST storage->ADF conversion preserves an <li>-nested image is
    # UNPROVEN, so a protected page gets the same deny until someone verifies it live and
    # narrows this. Default (atlas_doc_format) writes pass -- ADF carries the media node.
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    case "$cmd" in *confluence-update-page.sh*) : ;; *) exit 0 ;; esac
    case "$cmd" in *storage*) : ;; *) exit 0 ;; esac
    page="$(printf '%s' "$cmd" | grep -o 'confluence-update-page\.sh[^|;&]*' | grep -o '[0-9]\{6,\}' | head -1)"
    ;;
  *) exit 0 ;;
esac
[ -n "$page" ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] || exit 0
protected="$(jq -r '.atlassian.pagesWithNestedMedia[]? // empty' < "$CONFIG" 2>/dev/null | tr -d '\r')"
[ -n "$protected" ] || exit 0
printf '%s\n' "$protected" | grep -qxF -- "$page" || exit 0

jq -cn --arg page "$page" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Page " + $page + " holds an image nested inside a list item, and a contentFormat=\"html\" write WILL destroy it -- every time, not occasionally. The HTML->ADF converter silently drops a <figure data-type=\"media-single\"> nested in a <li>: body written faithfully, version bumped, image gone, no error. Write the body as contentFormat=\"adf\" instead -- the media node survives. Fetch the page with contentFormat=\"adf\" first to get the real node structure, splice your change into that (jq on the JSON, do not retype it), and write it back as adf. The ADF media-node shape, the attachment-recovery path if an image was already lost, and the multi-byte payload gotchas are in the ama-confluence-api skill. If you genuinely need html here, restore the media node immediately afterwards and verify the mediaSingle count did not go 1 -> 0.")
  }
}'
