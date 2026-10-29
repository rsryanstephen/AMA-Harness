# Plays one WAV and then repairs powershell's own per-app Volume Mixer volume if Windows has
# it stuck near zero (PROJ-15360).
#
# Why this exists: the chimes went fully silent while every other app's audio worked. Cause,
# measured live -- powershell's per-app SESSION volume was 0% on the default render endpoint,
# while every other session read 100% and the ENDPOINT itself read 50% unmuted. SoundPlayer
# happily reports success and takes real time (3.54s for 3 dings) while producing nothing.
# Endpoint volume and per-app session volume are different things; measuring only the former
# is what made this look like a device-routing problem for two rounds of debugging.
#
# Windows stores per-app volume per *(app, endpoint)* pair, not per app -- four separate
# powershell registrations exist on this machine, one per render endpoint. So switching or
# reconnecting a device brings a DIFFERENT stored entry into effect, which may be 0%. That is
# why the manual fix (README.md's mixer advice, plus a hand-rolled script re-derived three
# times) never held: it fixed one endpoint's entry, not the next one.
#
# Ordering is deliberate: the assert runs AFTER PlaySync, not before. A process has no audio
# session at all until it actually renders (confirmed: the session count goes 10 -> 11 only
# after playback), so there is nothing to assert against beforehand. After PlaySync the
# process has not exited, so its session still exists and setting it persists the stored
# per-app value. Cost of that choice: the FIRST tone after a fresh 0% entry takes effect is
# still lost, and every tone after it is audible.
#
# The assert runs on EVERY tone, never gated on a staleness marker -- it self-heals within one
# tone of any device change. Only the COMPILE is cached: the caller passes -AsmCache and the
# build is kept there, named by a hash of the C# source, so an edit can never load a stale
# build. Compiling per tone ran csc.exe and dropped a fresh unsigned DLL in %TEMP% on every
# turn end (120 on 2026-10-12), each scanned by Defender -- IT's MDE data (2026-10-14) listed
# csc.exe among this machine's top file-event sources. No -AsmCache = compile in memory.
#
# Fail-soft everywhere: any COM or compile failure must still leave the tone played. A volume
# assertion may never be the reason a tone does not sound.
param(
  [Parameter(Mandatory = $true)][string]$Wav,
  # Repair only the pathology, never a deliberate setting. A user who sets the chime to 30%
  # in the mixer keeps it; only muted-or-below-floor is treated as broken. Without this the
  # mixer slider would silently stop working as a control for the chimes.
  [double]$Floor = 0.10,
  # Force to 100% regardless of the floor, and report before -> after. Used by
  # scripts/fix-powershell-volume.ps1 as the on-demand remedy.
  [switch]$Force,
  # Dir that keeps the compiled interop assembly (notify-sound.sh passes its wav cache).
  [string]$AsmCache = ''
)

# --- play first, so the tone is never hostage to anything below ------------------------
$played = $false
try {
  $player = New-Object Media.SoundPlayer $Wav
  $player.Load()
  $player.PlaySync()
  $played = $true
} catch {
  # Nothing else to try -- the caller falls back to the unboosted original on its own.
  Write-Output "play-failed: $($_.Exception.Message)"
}

# --- then repair the app volume for next time -------------------------------------------
try {
  $src = @"
using System; using System.Runtime.InteropServices;
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int dwClsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int OpenPropertyStore(int a, out IntPtr s);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
  int GetState(out int st);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int f, int m, out IntPtr d);
  int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice ep);
}
[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
  int GetAudioSessionControl(ref Guid g, int f, out IntPtr c);
  int GetSimpleAudioVolume(ref Guid g, int f, out IntPtr v);
  int GetSessionEnumerator(out IAudioSessionEnumerator e);
}
[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator { int GetCount(out int n); int GetSession(int i, out IAudioSessionControl s); }
[Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl { int GetState(out int s); int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string n); }
[Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
  int GetState(out int s); int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string n);
  int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string v, ref Guid c);
  int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string n);
  int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string v, ref Guid c);
  int GetGroupingParam(out Guid g); int SetGroupingParam(ref Guid o, ref Guid c);
  int RegisterAudioSessionNotification(IntPtr n); int UnregisterAudioSessionNotification(IntPtr n);
  int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string n);
  int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string n);
  int GetProcessId(out int pid); int IsSystemSoundsSession();
}
[Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume {
  int SetMasterVolume(float l, ref Guid c); int GetMasterVolume(out float l);
  int SetMute(bool m, ref Guid c); int GetMute(out bool m);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public static class NotifyAppVol {
  // Repairs the session belonging to myPid on the CURRENT default render endpoint. Returns a
  // one-line status for the caller to log, or "" when nothing needed doing.
  public static string Ensure(int myPid, double floor, bool force) {
    var en = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
    IMMDevice def;
    // role 1 = eMultimedia. Resolved live rather than assumed, so whichever endpoint is
    // actually in use gets repaired -- the per-app value is stored per endpoint.
    if (en.GetDefaultAudioEndpoint(0, 1, out def) != 0 || def == null) return "";
    var iid = typeof(IAudioSessionManager2).GUID; object o;
    if (def.Activate(ref iid, 1, IntPtr.Zero, out o) != 0 || o == null) return "";
    IAudioSessionEnumerator ses;
    if (((IAudioSessionManager2)o).GetSessionEnumerator(out ses) != 0) return "";
    int n; ses.GetCount(out n);
    var ctx = Guid.Empty;
    for (int i = 0; i < n; i++) {
      IAudioSessionControl c; ses.GetSession(i, out c);
      var c2 = (IAudioSessionControl2)c;
      int pid; c2.GetProcessId(out pid);
      if (pid != myPid) continue;
      var sv = (ISimpleAudioVolume)c;
      float before; sv.GetMasterVolume(out before);
      bool muted; sv.GetMute(out muted);
      if (!force && !muted && before >= floor) return "";
      sv.SetMasterVolume(1.0f, ref ctx);
      sv.SetMute(false, ref ctx);
      float after; sv.GetMasterVolume(out after);
      return string.Format("app-volume repaired: {0:P0}{1} -> {2:P0}",
                           before, muted ? " MUTED" : "", after);
    }
    return "";
  }
}
"@
  $loaded = $false; $dll = $null
  if ($AsmCache) {
    try {
      $sha = New-Object Security.Cryptography.SHA256CryptoServiceProvider
      $key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($src))[0..7] | ForEach-Object { $_.ToString('x2') })
      $dll = Join-Path $AsmCache "NotifyAppVol-$key.dll"
      if (-not (Test-Path -LiteralPath $dll)) {
        $null = New-Item -ItemType Directory -Force -Path $AsmCache
        Add-Type -TypeDefinition $src -OutputAssembly $dll -OutputType Library
      }
      Add-Type -Path $dll
      $loaded = $true
    } catch {
      # A torn build (two tones racing the first compile) must not stick: drop it so the next
      # tone rebuilds, and fall through to the in-memory compile.
      if ($dll) { Remove-Item -LiteralPath $dll -Force -ErrorAction SilentlyContinue }
    }
  }
  if (-not $loaded) { Add-Type -TypeDefinition $src }
  $status = [NotifyAppVol]::Ensure($PID, $Floor, [bool]$Force)
  if ($status) { Write-Output $status }
} catch {
  # Deliberately swallowed -- see the fail-soft note in the header. The tone already played.
  Write-Output "appvol-check-failed: $($_.Exception.Message)"
}

if (-not $played) { exit 1 }
