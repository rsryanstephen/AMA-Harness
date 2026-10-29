# Daily 09:05 reminder (scheduled task AMA-Harness-FileClaim-Reminder, hidden via
# run-hidden-generic.vbs): the file-claim commit guard added for PROJ-15368 has not yet
# been OBSERVED firing against a real concurrent session, so the ticket is still In Progress.
#
# Same self-clearing shape as check-gates-reminder.ps1: chime + write a digest line while the
# marker exists, delete our own task once it is gone. cross-session-repo-claim.sh removes the
# marker (and writes the firing itself into the same digest) the first time its file check
# actually warns, so the loop closes on the event rather than on someone remembering.
#
# NOTE the digest is drained by on-prompt.sh, which truncates it after injecting -- so a line
# written here is surfaced once, on the user's next prompt, not accumulated forever.
$ErrorActionPreference = 'SilentlyContinue'
$StateDir = Join-Path $env:USERPROFILE '.claude\harness-state\notices'
$Marker   = Join-Path $StateDir '.file-claim-firing-owed'
$Digest   = Join-Path $StateDir 'file-claim-reminder.txt'

if (Test-Path $Marker) {
  $why = Get-Content $Marker -Raw
  # Single-quoted format string on purpose: a backtick inside a double-quoted PS string is an
  # escape, and `b (backspace) turned 'bash' into 'ash' on check-gates-reminder.ps1's first
  # live run. Same trap, same fix.
  Add-Content -Path $Digest -Value ('{0} PROJ-15368 still open: the file-claim commit guard has not been seen firing against a real concurrent session yet ({1}). Check "cat ~/.claude/harness-state/sessions/.file-claims" for two live sids on one path, and whether a commit since has warned. Nothing to do if the fleet has simply been quiet.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $why.Trim())
  $wav = 'C:\Windows\Media\Windows Notify Calendar.wav'
  if (Test-Path $wav) { (New-Object System.Media.SoundPlayer($wav)).PlaySync() }
} else {
  schtasks.exe /Delete /TN 'AMA-Harness-FileClaim-Reminder' /F | Out-Null
}
exit 0
