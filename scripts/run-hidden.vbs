' Runs one command via Task Scheduler with ZERO visible console flash. <harnessEpicKey>.
'
' Why VBScript and not `powershell.exe -WindowStyle Hidden` (the first attempt at this
' fix, confirmed live to still flash): powershell.exe is a console-subsystem
' executable, so Windows allocates its console at process CREATION, before the
' PowerShell host itself even starts running -WindowStyle-Hidden is a post-creation
' instruction the host applies to itself, and that one allocate-then-hide frame is
' exactly the flash the user reported. wscript.exe is a GUI-subsystem executable with
' no console of its own, and WScript.Shell.Run's window-style parameter (0 = hidden) is
' applied via STARTUPINFO at the CHILD process's creation time, before that process's
' console exists -- so there is nothing to flash, for wscript.exe itself or for
' whatever it launches.
'
' Usage (as a scheduled task action):
'   Execute:   wscript.exe
'   Arguments: "<path>\run-hidden.vbs" "<bash command line>"
'
' Exit code of the bash command is propagated as wscript.exe's own exit code, so
' Get-ScheduledTaskInfo's LastTaskResult still means what it already means.
Set objShell = CreateObject("WScript.Shell")
bashExe = "C:\Program Files\Git\usr\bin\bash.exe"

' Double any embedded double-quote (VBScript's own string-literal escaping rule) before
' splicing the command into the composed command line -- the ONE quoting hop in this
' whole wrapper. Every other hop (Task Scheduler -> wscript.exe's argv,
' WScript.Arguments(0) -> this script) passes the value as its own distinct argument,
' never re-parsed as a shell string.
cmd = WScript.Arguments(0)
cmd = Replace(cmd, """", """""")
cmdLine = """" & bashExe & """ -lc """ & cmd & """"

exitCode = objShell.Run(cmdLine, 0, True)
WScript.Quit(exitCode)
