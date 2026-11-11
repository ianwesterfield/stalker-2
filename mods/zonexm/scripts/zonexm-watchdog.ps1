# Zone XM watchdog — conversation awareness for music while playing Stalker 2.
#
# Watches the alert flag written by the ZoneXM UE4SS mod and ducks the output mix
# while it exists — per-app session volumes on the default device. Restores
# each app's pre-duck volume on clear, on exit, and if the flag goes stale
# (game killed mid-alert). Sessions appearing mid-duck (app restarted during
# combat) get ducked on the next poll.
#
#   .\zonexm-watchdog.ps1                                   # duck EVERYTHING except the game (default)
#   .\zonexm-watchdog.ps1 -ProcessName Pandora,msedge       # narrow: duck only these
#   .\zonexm-watchdog.ps1 -AllButProcess Stalker2-Win64-Shipping,Discord
#   .\zonexm-watchdog.ps1 -DuckLevel 0.15 -PollMs 500
# Run it hidden at logon; needs PowerShell 7+ (pure COM, no modules).

[CmdletBinding()]
param(
  [string[]]$ProcessName,                                     # if passed: narrow mode
  [string[]]$AllButProcess = @("Stalker2-Win64-Shipping"),    # otherwise: duck all but these
  [double]$DuckLevel = 0.15,                # fraction of pre-duck volume
  [int]$PollMs = 500,
  [int]$StaleAfterSec = 8,                  # flag older than this = game died
  [int]$DuckFadeMs = 350,                   # combat is urgent: fast dip
  [int]$RestoreFadeMs = 1500,               # recovery is musical: lazy rise
  [switch]$NoBanner                        # disable the read-only media bridge
)
$ErrorActionPreference = 'Stop'

# single instance: stacked watchdogs race baselines (three were running at one point)
$mutexCreated = $false
$script:mutex = New-Object System.Threading.Mutex($true, "ZoneXM.Watchdog.Singleton", [ref]$mutexCreated)
if (-not $mutexCreated) { Write-Host "ZoneXM watchdog already running — exiting"; exit 0 }

$flag = Join-Path $env:LOCALAPPDATA "Stalker2\Saved\ZoneXM\alert.flag"
# the game-side Lua must not shell out (console flash steals game input focus) — we own the dir
$null = New-Item -ItemType Directory -Path (Split-Path $flag) -Force

try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ZoneXM.Audio {

// Raw vtable CoreAudio — no ComImport interface casts, which are a managed-cast
// dead end off .NET Framework (InvalidCast before QI is ever attempted; proven
// 2026-11-02 across pwsh AND powershell after the IID swap postmortem). IUnknown
// occupies vtable slots 0-2; slot = 3 + method ordinal beyond that.
public static class Duck {
    static readonly Guid IID_IMMDeviceEnumerator   = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
    static readonly Guid IID_IAudioSessionManager2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
    static readonly Guid IID_IAudioSessionControl2 = new Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d");
    static readonly Guid IID_ISimpleAudioVolume    = new Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8");
    static readonly Guid CLSID_MMDeviceEnumerator  = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");

    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDefaultAudioEndpointFn(IntPtr self, int dataFlow, int role, out IntPtr dev);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int ActivateFn(IntPtr self, ref Guid iid, int clsCtx, IntPtr activationParams, out IntPtr mgr);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetSessionEnumeratorFn(IntPtr self, out IntPtr en);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetCountFn(IntPtr self, out int count);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetSessionFn(IntPtr self, int index, out IntPtr ctl);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetProcessIdFn(IntPtr self, out int pid);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetMasterVolumeFn(IntPtr self, out float level);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int SetMasterVolumeFn(IntPtr self, float level, ref Guid ctx);

    static T Vtbl<T>(IntPtr obj, int slot) {
        IntPtr vtbl = Marshal.ReadIntPtr(obj);
        IntPtr fn = Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size);
        return Marshal.GetDelegateForFunctionPointer<T>(fn);
    }

    static IntPtr QI(IntPtr unk, Guid iid) {
        IntPtr p;
        return Marshal.QueryInterface(unk, in iid, out p) == 0 ? p : IntPtr.Zero;
    }

    // returns pid -> ISimpleAudioVolume pointer for every session on the default device
    public static System.Collections.Generic.Dictionary<int, IntPtr> Sessions() {
        var map = new System.Collections.Generic.Dictionary<int, IntPtr>();
        var rcw = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator));
        IntPtr unk = Marshal.GetIUnknownForObject(rcw);
        IntPtr en = QI(unk, IID_IMMDeviceEnumerator);
        if (en == IntPtr.Zero) throw new COMException("QI IMMDeviceEnumerator failed");
        IntPtr dev;
        Marshal.ThrowExceptionForHR(Vtbl<GetDefaultAudioEndpointFn>(en, 4)(en, 0, 0, out dev));
        IntPtr mgr;
        Guid iid = IID_IAudioSessionManager2;
        Marshal.ThrowExceptionForHR(Vtbl<ActivateFn>(dev, 3)(dev, ref iid, 23, IntPtr.Zero, out mgr));
        IntPtr se;
        Marshal.ThrowExceptionForHR(Vtbl<GetSessionEnumeratorFn>(mgr, 5)(mgr, out se));
        int count;
        Marshal.ThrowExceptionForHR(Vtbl<GetCountFn>(se, 3)(se, out count));
        for (int i = 0; i < count; i++) {
            IntPtr ctl;
            if (Vtbl<GetSessionFn>(se, 4)(se, i, out ctl) != 0 || ctl == IntPtr.Zero) continue;
            IntPtr ctl2 = QI(ctl, IID_IAudioSessionControl2);
            if (ctl2 == IntPtr.Zero) { Marshal.Release(ctl); continue; }
            int pid;
            bool bad = Vtbl<GetProcessIdFn>(ctl2, 14)(ctl2, out pid) != 0 || pid == 0;
            Marshal.Release(ctl2);
            if (bad) { Marshal.Release(ctl); continue; }
            IntPtr vol = QI(ctl, IID_ISimpleAudioVolume);
            Marshal.Release(ctl);
            if (vol == IntPtr.Zero) continue;
            if (map.ContainsKey(pid)) Marshal.Release(vol); else map[pid] = vol;
        }
        Marshal.Release(se); Marshal.Release(mgr); Marshal.Release(dev);
        Marshal.Release(en); Marshal.Release(unk);
        return map;
    }

    public static float Get(IntPtr vol) {
        float v;
        Marshal.ThrowExceptionForHR(Vtbl<GetMasterVolumeFn>(vol, 4)(vol, out v));
        return v;
    }
    public static void Set(IntPtr vol, float v) {
        Guid empty = Guid.Empty;
        Marshal.ThrowExceptionForHR(Vtbl<SetMasterVolumeFn>(vol, 3)(vol, v, ref empty));
    }
}

}
'@
}
catch {
  Write-Host "ZoneXM: interop compile failed: $($_.Exception.Message)"
  throw
}
if (-not ('ZoneXM.Audio.Duck' -as [type])) {
  throw "ZoneXM: Duck type missing after compile (Add-Type flattened or dropped it)"
}

# returns pid -> ISimpleAudioVolume for the sessions this run is targeting
function Find-TargetVolumes {
  $map = @{}
  $sessions = [ZoneXM.Audio.Duck]::Sessions()
  if ($PSBoundParameters.ContainsKey('ProcessName')) {
    $pids = @{}
    foreach ($name in $ProcessName) {
      Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $pids[$_.Id] = $true }
    }
    foreach ($kv in $sessions.GetEnumerator()) {
      if ($pids.ContainsKey($kv.Key)) { $map[$kv.Key] = $kv.Value }
    }
  }
  else {
    $excl = @{}
    foreach ($name in $AllButProcess) {
      Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $excl[$_.Id] = $true }
    }
    foreach ($kv in $sessions.GetEnumerator()) {
      if (-not $excl.ContainsKey($kv.Key)) { $map[$kv.Key] = $kv.Value }
    }
  }
  return $map
}

# pid -> @{ Vol, Level }: every session restores to ITS OWN pre-duck volume
$script:baselines = @{}
$script:ducked = $false
function Restore-Duck {
  foreach ($kv in $script:baselines.GetEnumerator()) {
    try { [ZoneXM.Audio.Duck]::Set($kv.Value.Vol, $kv.Value.Level) } catch {}
  }
  $script:baselines = @{}
}

# apply baseline*factor to every tracked session (factor 1.0 = untouched)
function Set-DuckFactor([double]$f) {
  foreach ($kv in $script:baselines.GetEnumerator()) {
    try { [ZoneXM.Audio.Duck]::Set($kv.Value.Vol, [float]($kv.Value.Level * $f)) } catch {}
  }
}

# smoothstep ease between duck factors; DoEvents keeps the tray alive mid-fade
function Start-Fade([double]$from, [double]$to, [int]$ms) {
  $steps = [math]::Max(1, [int]($ms / 33))
  for ($i = 1; $i -le $steps; $i++) {
    $t = $i / $steps
    $s = $t * $t * (3 - 2 * $t)
    Set-DuckFactor ($from + ($to - $from) * $s)
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 33
  }
}

if ($PSBoundParameters.ContainsKey('ProcessName')) {
  Write-Host "ZoneXM watchdog armed: duck [$($ProcessName -join ', ')] x$DuckLevel on alert (flag: $flag)"
}
else {
  Write-Host "ZoneXM watchdog armed: duck ALL except [$($AllButProcess -join ', ')] x$DuckLevel on alert (flag: $flag)"
}

# tray icon: visible proof of life, tooltip carries duck state, right-click Exit
# restores. DoEvents in the poll loop keeps the tray responsive.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$iconFile = Join-Path $PSScriptRoot 'zonexm.png'
$script:tray = $null
$script:quit = $false
$script:trayBmp = $null
if (Test-Path $iconFile) {
  $script:trayBmp = [System.Drawing.Bitmap]::FromFile($iconFile)
  $hIcon = $script:trayBmp.GetHicon()
  $script:tray = New-Object System.Windows.Forms.NotifyIcon
  $script:tray.Icon = [System.Drawing.Icon]::FromHandle($hIcon)
  $script:tray.Text = 'ZoneXM: armed'
  $cm = New-Object System.Windows.Forms.ContextMenuStrip
  [void]$cm.Items.Add('Exit ZoneXM')
  $cm.Items[0].add_Click({ $script:quit = $true })
  $script:tray.ContextMenuStrip = $cm
  $script:tray.Visible = $true
}
else {
  Write-Host "tray icon missing ($iconFile) — running headless"
}
function Set-TrayState([string]$state) {
  if ($script:tray) { $script:tray.Text = "ZoneXM: $state" }
}

$mediaProcess = $null
try {
  if (-not $NoBanner) {
    try {
      $bridge = Join-Path $PSScriptRoot 'zonexm-media.ps1'
      $mediaProcess = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$bridge`"", '-ParentProcessId', $PID) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path (Split-Path $flag) 'media.log') `
        -RedirectStandardError (Join-Path (Split-Path $flag) 'media-error.log')
    }
    catch { Write-Warning "ZoneXM banners unavailable: $($_.Exception.Message). Ducking remains active." }
  }
  while (-not $script:quit) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds $PollMs
    if ($mediaProcess -and $mediaProcess.HasExited) {
      Write-Warning "ZoneXM media bridge exited ($($mediaProcess.ExitCode)); see media-error.log beside alert.flag. Ducking remains active."
      $mediaProcess.Dispose()
      $mediaProcess = $null
    }
    $alert = Test-Path $flag
    if ($alert) {
      # a flag older than the staleness window means the game died mid-alert
      try {
        if ((Get-Item $flag).LastWriteTime -lt (Get-Date).AddSeconds(-$StaleAfterSec)) {
          Remove-Item $flag -Force
          $alert = $false
        }
      }
      catch { $alert = $false }
    }

    if ($alert) {
      $now = Find-TargetVolumes
      $freshDuringDuck = @()
      foreach ($kv in $now.GetEnumerator()) {
        if (-not $script:baselines.ContainsKey($kv.Key)) {
          $current = [ZoneXM.Audio.Duck]::Get($kv.Value)
          if ($current -gt 0.001) {
            $script:baselines[$kv.Key] = @{ Vol = $kv.Value; Level = $current }
            if ($script:ducked) { $freshDuringDuck += $kv.Value }
            $who = (Get-Process -Id $kv.Key -ErrorAction SilentlyContinue).ProcessName
            Write-Host "$(Get-Date -Format HH:mm:ss) tracking $who @ $([math]::Round($current, 3))"
          }
        }
      }
      if (-not $script:ducked -and $script:baselines.Count -gt 0) {
        Set-TrayState 'DUCKED (combat)'
        Start-Fade 1.0 $DuckLevel $DuckFadeMs
        $script:ducked = $true
        Write-Host "$(Get-Date -Format HH:mm:ss) ducked x$DuckLevel ($($script:baselines.Count) sessions)"
      }
      elseif ($script:ducked) {
        # latecomers conform instantly; everyone else is already down
        foreach ($v in $freshDuringDuck) {
          try { [ZoneXM.Audio.Duck]::Set($v, [float]([ZoneXM.Audio.Duck]::Get($v) * $DuckLevel)) } catch {}
        }
      }
    }
    elseif (-not $alert -and $ducked) {
      Start-Fade $DuckLevel 1.0 $RestoreFadeMs
      Restore-Duck
      $script:ducked = $false
      Set-TrayState 'armed'
      Write-Host "$(Get-Date -Format HH:mm:ss) restored all"
    }
  }
}
finally {
  Restore-Duck
  if ($mediaProcess) {
    if (-not $mediaProcess.HasExited) { Stop-Process -Id $mediaProcess.Id -ErrorAction Continue }
    $mediaProcess.Dispose()
  }
  if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() }
  if ($script:trayBmp) { $script:trayBmp.Dispose() }
  if ($script:mutex) { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() }
}
