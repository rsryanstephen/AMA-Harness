# On-demand remedy for "the Claude chimes are silent but everything else plays"
# (PROJ-15360). Forces powershell's per-app Volume Mixer volume back to 100% on the
# CURRENT default render endpoint and reports before -> after.
#
# You should rarely need this: hooks/notify-sound.sh now repairs the value itself after every
# tone. It stays for the case where you want the fix immediately without waiting for a tone,
# or to confirm what the stored value actually is.
#
# Background, because this has now recurred three times and been re-derived by hand each time:
# Windows remembers per-app volume per *(app, endpoint)* pair and keeps it indefinitely. A 0%
# entry makes Media.SoundPlayer report success and play silence, while the endpoint's own
# volume looks perfectly healthy -- and [console]::beep stays audible throughout, because Beep
# renders through the system-sounds session rather than the calling process's own. That
# asymmetry is what makes it read as a device-routing fault when it is not.
#
# A per-app session only exists while a process is actually rendering, so this plays one short
# chime in order to have a session to repair. That is not incidental -- without it there is
# nothing to set.
$ErrorActionPreference = 'Stop'

$wav = Join-Path $env:USERPROFILE '.claude\harness-state\logs\.notify-sound-cache\Windows Ding.wav'
if (-not (Test-Path -LiteralPath $wav)) {
  # Cache not built yet -- the stock file works just as well for creating a session.
  $wav = 'C:\Windows\Media\Windows Ding.wav'
}
if (-not (Test-Path -LiteralPath $wav)) {
  Write-Output "no WAV available to create an audio session with; cannot repair"
  exit 1
}

$player = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\notify-sound-play.ps1'
if (-not (Test-Path -LiteralPath $player)) {
  Write-Output "cannot find hooks/notify-sound-play.ps1 next to this script"
  exit 1
}

Write-Output "endpoint: current default (eMultimedia); playing one chime to create a session..."
$out = & $player -Wav $wav -Force
if ($out) { $out | ForEach-Object { Write-Output "  $_" } }
else { Write-Output "  no change reported -- session already at 100% unmuted" }
