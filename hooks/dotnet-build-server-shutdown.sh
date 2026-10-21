#!/usr/bin/env bash
# PostToolUse (Bash|PowerShell), dispatched via dispatch-post-bash.manifest. After a
# FOREGROUND `dotnet build|test|publish` returns, runs `dotnet build-server shutdown` so the
# MSBuild worker nodes, VBCSCompiler and the Razor server it left behind exit now instead
# of idling for up to 15 minutes each.
#
# Why (<harnessEpicKey>, 2026-09-27): the machine paged at 1.3 GB free. 42 dotnet.exe were
# live -- two concurrent `dotnet test` runs at ~15 MSBuild nodes each, plus 18 IDLE
# leftover nodes (1,995 MB) from builds that had already finished. Node reuse keeps them
# alive on purpose; with several sessions building, that costs 2 GB doing nothing.
# MSBUILDDISABLENODEREUSE=1 in settings.json's env block stops NEW nodes lingering; this
# hook covers what the flag does not (VBCSCompiler keeps its own keep-alive; a session whose
# env predates the flag) and is the same rule applied at the moment the build is done.
#
# Guards, in order, all before any fork:
#   - needle + command-position test: the command must INVOKE dotnet build/test/publish --
#     a `cat SKILL.md` that mentions `dotnet test` is not a build;
#   - a backgrounded call (tool_response carries backgroundTaskId) is still building: skip;
#   - a build in flight ANYWHERE (a live `dotnet test|build|publish|msbuild` client process,
#     usually another session's) -> `--msbuild` only. Idle nodes still die; a BUSY node is
#     unreachable anyway (its pipe is held by its parent), and VBCSCompiler is left alone
#     because shutting it mid-compile drops that build to in-process compilation for no
#     gain. One powershell fork (~1s) for the probe, only on the build path.
# Silent to the model. One line per run in harness-state/logs/dotnet-build-server-shutdown.log
# (mode, in-flight count, dotnet.exe before -> after) is the evidence the fix is holding.
#
# Test seams: AMA_DOTNET_SHUTDOWN_DRY_RUN=1 prints the verdict on stderr and acts on
# nothing; AMA_DOTNET_INFLIGHT=<n> replaces the process probe.
set -u
IFS= read -r -d '' payload || true
# The `\"` forms are a quoted binary path as it appears in the JSON payload:
# "C:\Program Files\dotnet\dotnet.exe" test  ->  dotnet.exe\" test
case "$payload" in
  *'dotnet test'*|*'dotnet build'*|*'dotnet publish'*|*'dotnet.exe test'*|*'dotnet.exe build'*|*'dotnet.exe publish'*|*'dotnet.exe\" test'*|*'dotnet.exe\" build'*|*'dotnet.exe\" publish'*) ;;
  *) exit 0 ;;
esac
# Not a second `case` -- build-needle-cache.sh would fold it into the needle above.
[[ $payload == *backgroundTaskId* ]] && exit 0

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0
flat="$(printf '%s' "$command" | tr -d '\r' | tr '\n' ';')"
# Command position: start of a segment, optionally a quoted/absolute path to the binary.
printf '%s' "$flat" | grep -qE '(^|[;&|(]|&&|\$\()[[:space:]]*(["'"'"']?[^;&|]*[/\\])?dotnet(\.exe)?["'"'"']?[[:space:]]+(test|build|publish)([[:space:]]|$)' || exit 0

sid8="-"
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{8}) ]] && sid8="${BASH_REMATCH[1]}"
dry="${AMA_DOTNET_SHUTDOWN_DRY_RUN:-}"

# Client processes only (lib header has the shapes it must NOT count).
source "${BASH_SOURCE[0]%/*}/lib-dotnet-inflight.sh"
inflight="$(dotnet_inflight_count)"

count_dotnet() { tasklist //FI "IMAGENAME eq dotnet.exe" //FO CSV 2>/dev/null | grep -c '^"dotnet.exe"'; }

if [ "$inflight" -gt 0 ]; then mode="msbuild-only"; else mode="full"; fi
if [ -n "$dry" ]; then
  printf 'dry-run: mode=%s inflight=%s\n' "$mode" "$inflight" >&2
  exit 0
fi

before="$(count_dotnet)"
if [ "$mode" = full ]; then
  timeout 60 dotnet build-server shutdown >/dev/null 2>&1
else
  timeout 60 dotnet build-server shutdown --msbuild >/dev/null 2>&1
fi
after="$(count_dotnet)"

log="$HOME/.claude/harness-state/logs/dotnet-build-server-shutdown.log"
[ -d "${log%/*}" ] || mkdir -p "${log%/*}" 2>/dev/null
printf '%(%Y-%m-%dT%H:%M:%S)T sid=%s mode=%s inflight=%s dotnet=%s->%s\n' -1 "$sid8" "$mode" "$inflight" "${before:-?}" "${after:-?}" >> "$log" 2>/dev/null
exit 0
