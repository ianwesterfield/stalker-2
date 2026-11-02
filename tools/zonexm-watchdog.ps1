# Zone XM watchdog — conversation awareness for music while playing Stalker 2.
#
# Watches the alert flag written by ue4ss-mods/ZoneXM and ducks the output mix
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
  [int]$StaleAfterSec = 8                   # flag older than this = game died
)
$ErrorActionPreference = 'Stop'

$flag = Join-Path $env:LOCALAPPDATA "Stalker2\Saved\ZoneXM\alert.flag"

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

if ($PSBoundParameters.ContainsKey('ProcessName')) {
  Write-Host "ZoneXM watchdog armed: duck [$($ProcessName -join ', ')] x$DuckLevel on alert (flag: $flag)"
}
else {
  Write-Host "ZoneXM watchdog armed: duck ALL except [$($AllButProcess -join ', ')] x$DuckLevel on alert (flag: $flag)"
}

try {
  while ($true) {
    Start-Sleep -Milliseconds $PollMs
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
      foreach ($kv in $now.GetEnumerator()) {
        if (-not $script:baselines.ContainsKey($kv.Key)) {
          $current = [ZoneXM.Audio.Duck]::Get($kv.Value)
          if ($current -gt 0.001) {
            $script:baselines[$kv.Key] = @{ Vol = $kv.Value; Level = $current }
            [ZoneXM.Audio.Duck]::Set($kv.Value, $current * $DuckLevel)
            $script:ducked = $true
            $who = (Get-Process -Id $kv.Key -ErrorAction SilentlyContinue).ProcessName
            Write-Host "$(Get-Date -Format HH:mm:ss) DUCKED $who -> $([math]::Round($current * $DuckLevel, 3))"
          }
        }
      }
    }
    elseif (-not $alert -and $ducked) {
      Restore-Duck
      $script:ducked = $false
      Write-Host "$(Get-Date -Format HH:mm:ss) restored all"
    }
  }
}
finally {
  Restore-Duck
}
