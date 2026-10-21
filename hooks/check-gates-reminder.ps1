# Daily 08:50 reminder (scheduled task AMA-Harness-CheckGates-Reminder, hidden via
# run-hidden-generic.vbs): a full check-gates.sh run is still owed -- see
# scripts/run-check-gates-full.sh's header for why. Self-clearing: chimes + writes a
# digest line while the marker exists; deletes its own task once the marker is gone
# (run-check-gates-full.sh removes both on a green run, this is the belt to that brace).
$ErrorActionPreference = 'SilentlyContinue'
$StateDir = Join-Path $env:USERPROFILE '.claude\harness-state\notices'
$Marker = Join-Path $StateDir '.check-gates-full-run-owed'
$Digest = Join-Path $StateDir 'check-gates-reminder.txt'

if (Test-Path $Marker) {
  $why = Get-Content $Marker -Raw
  # Single-quoted format string: a backtick in a double-quoted PS string is an escape
  # (`b = backspace turned 'bash' into 'ash' on the first live run).
  Add-Content -Path $Digest -Value ('{0} full check-gates.sh run still owed ({1}) -- run "bash scripts/run-check-gates-full.sh" from the harness repo when the machine is quiet (few Claude sessions); it clears this reminder on green.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $why.Trim())
  $wav = 'C:\Windows\Media\Windows Notify Calendar.wav'
  if (Test-Path $wav) { (New-Object System.Media.SoundPlayer($wav)).PlaySync() }
} else {
  schtasks.exe /Delete /TN 'AMA-Harness-CheckGates-Reminder' /F | Out-Null
}
exit 0