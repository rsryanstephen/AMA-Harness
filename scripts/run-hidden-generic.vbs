' Runs one FULL command line via Task Scheduler with ZERO visible console flash.
' <harnessEpicKey>. Sibling of run-hidden.vbs -- that one hardcodes a bash -lc wrapping
' (every existing caller passes a bare bash command and relies on it), which is wrong
' for a task whose payload is a powershell.exe invocation, e.g. an existing script that
' already does its own hiding internally (run-fleet-health-hidden.ps1) but was still
' launched through a console-subsystem OUTER layer (powershell.exe -WindowStyle Hidden)
' that flashes once at process creation -- confirmed live (same root cause as
' run-hidden.vbs's own header comment, reproduced again for Fleet-Health-Check
' specifically after `StartWhenAvailable` caught up a missed run while the user was at
' their desk).
'
' This wrapper does NOT rewrite the argument at all -- it is passed straight to
' WScript.Shell.Run as the complete command line, so the caller supplies its own
' quoting (same "each hop is its own argv slot" rule as run-hidden.vbs, just with one
' fewer hop since there's no bash -lc splice here to double quotes for).
'
' Usage (as a scheduled task action):
'   Execute:   wscript.exe
'   Arguments: "<path>\run-hidden-generic.vbs" "<full command line, any executable>"
'
' Exit code of the launched command is propagated as wscript.exe's own exit code, so
' Get-ScheduledTaskInfo's LastTaskResult still means what it already means.
'
' Embedded quotes do NOT survive the hop: a `-File ""C:\Program Files\x.ps1""` inside the
' command argument reached PowerShell as `-File C:\Program` (exit 0xFFFD0000, file not
' found; AMA-Harness-Defender-Hot-Record's first run, 2026-10-15). Every existing caller
' only ever "worked" because its paths have no spaces -- keep every path in the inner
' command line space-free rather than quoting it.
Set objShell = CreateObject("WScript.Shell")
cmdLine = WScript.Arguments(0)
exitCode = objShell.Run(cmdLine, 0, True)
WScript.Quit(exitCode)
