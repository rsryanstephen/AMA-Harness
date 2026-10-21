#!/usr/bin/env bash
# Sourced, never run. ONE copy of "is a .NET build running anywhere on this machine?"
# shared by dotnet-build-memory-wait.sh (Pre: wait for it) and
# dotnet-build-server-shutdown.sh (Post: don't shut its compiler down). A private copy per
# hook is how predicates drift (AGENTS.md, shared libs).
#
#   dotnet_inflight_count   -> prints the number of live dotnet CLIENT processes whose verb
#                              is test|build|publish|msbuild, from any session or shell.
#
# Client processes only, by command line: a worker node reads
# `dotnet.exe "…\MSBuild.dll" /nodemode:1`, testhost `dotnet exec … testhost.dll`,
# VBCSCompiler `dotnet.exe "…\VBCSCompiler.dll" -pipename:…` -- none has the verb right
# after the binary, so idle leftovers never count as a build in flight. Rider's own builds
# go through its bundled host and are invisible here, deliberately: the contention this
# measures is between Claude sessions' `dotnet test` runs (2 x ~15 nodes, 2026-09-27).
# One powershell fork, ~1s. Process-liveness IS the cross-session truth -- no claim ledger
# to go stale, no session to be "live" or not.
#
# Seam: AMA_DOTNET_INFLIGHT=<n> replaces the probe (check-gates cases).
dotnet_inflight_count() {
  local n="${AMA_DOTNET_INFLIGHT:-}"
  if [ -z "$n" ]; then
    n="$(powershell.exe -NoProfile -NonInteractive -Command - 2>/dev/null <<'PS' | tr -d '\r\n '
@(Get-CimInstance Win32_Process -Filter "Name='dotnet.exe'" | Where-Object { $_.CommandLine -match 'dotnet(\.exe)?"?\s+(test|build|publish|msbuild)(\s|$)' }).Count
PS
)"
  fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
