#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Nudges Claude to run a library
# version-sync skill right after a git push that actually published a changed
# library -- PROJ-15259 fixed YourCompany.Product.Search.Shared and pushed
# to search's develop, but nothing prompted ama-search-shared-version-sync
# until the user asked. Same gap as git-push-ticket-reminder.sh existed for
# ticket status before that hook was added -- this is the same pattern applied
# to library-version-sync. No de-dupe: fires on every matching push, same
# philosophy as that sibling hook.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the push-matching regex below requires the literal
# substring "push", so a payload without it can exit on zero forks. ~60ms/fork.
case "$payload" in *push*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"

[ -n "$command" ] || exit 0

printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?push\b' || exit 0

target_dir="$(printf '%s' "$command" | grep -oP -- '-C\s+"?\K[^"[:space:]]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$(printf '%s' "$command" | grep -oP '^\s*cd\s+"?\K[^"[:space:];&]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$cwd"
target_dir="${target_dir/#\~/$HOME}"
target_dir="${target_dir/#\$HOME/$HOME}"
[ -n "$target_dir" ] || exit 0

branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$branch" ] || exit 0

slug="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" slug "$target_dir" 2>/dev/null)"
[ -n "$slug" ] || exit 0

reason=""

if [ "$slug" = "product-service-search" ] && [ "$branch" = "develop" ]; then
  old="$(git -C "$target_dir" rev-parse 'refs/remotes/origin/develop@{1}' 2>/dev/null)"
  new="$(git -C "$target_dir" rev-parse origin/develop 2>/dev/null)"
  if [ -n "$old" ] && [ -n "$new" ]; then
    changed="$(git -C "$target_dir" diff --name-only "$old..$new" -- \
      YourCompany.Product.Search.Shared/ YourCompany.Product.Search.Cache/ 2>/dev/null)"
    if [ -n "$changed" ]; then
      reason="Just pushed ${old}..${new} to develop on product-service-search, and Search.Shared/Search.Cache changed -- invoke the ama-search-shared-version-sync skill now, don't wait to be asked."
    fi
  fi
elif [ "$branch" = "master" ] && [ "$slug" != "product-service-search" ]; then
  pkgs="$(bash "$HOME/.claude/skills/ama-library-version-sync/scripts/list-published-packages.sh" "$target_dir" 2>/dev/null \
    | awk -F'\t' 'NF >= 3 && $3 != ""')"
  if [ -n "$pkgs" ]; then
    old="$(git -C "$target_dir" rev-parse 'refs/remotes/origin/master@{1}' 2>/dev/null)"
    new="$(git -C "$target_dir" rev-parse origin/master 2>/dev/null)"
    if [ -z "$old" ] || [ -z "$new" ]; then
      reason="Just pushed to master on ${slug}, which publishes a NuGet package, but no reflog to confirm whether the published code changed -- check manually and invoke ama-library-version-sync if it did."
    else
      changed_any=""
      while IFS=$'\t' read -r _pkg csproj _prefix; do
        [ -n "$csproj" ] || continue
        pkg_dir="$(dirname "$csproj")"
        rel="${pkg_dir#"$target_dir"/}"
        c="$(git -C "$target_dir" diff --name-only "$old..$new" -- "$rel/" 2>/dev/null)"
        [ -n "$c" ] && changed_any="yes"
      done <<< "$pkgs"
      if [ -n "$changed_any" ]; then
        reason="Just pushed ${old}..${new} to master on ${slug}, and a published package's code changed -- invoke the ama-library-version-sync skill now, don't wait to be asked."
      fi
    fi
  fi
fi

[ -n "$reason" ] || exit 0

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
