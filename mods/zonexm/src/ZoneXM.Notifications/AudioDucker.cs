using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace ZoneXM.Notifications;

internal sealed class DuckState : IDisposable
{
    private readonly Dictionary<string, (IAudioSession Session, float Volume)> baselines = new(StringComparer.Ordinal);
    internal int Count => baselines.Count;
    internal float Factor { get; private set; } = 1;

    internal void Add(IEnumerable<IAudioSession> sessions, ISet<int> excluded)
    {
        List<Exception> failures = [];
        foreach (var session in sessions)
        {
            var retained = false;
            try
            {
                if (excluded.Contains(session.ProcessId) || baselines.ContainsKey(session.Id)) continue;
                var level = session.Volume;
                if (level <= 0.001f) continue;
                baselines.Add(session.Id, (session, level));
                retained = true;
                session.Volume = level * Factor;
            }
            catch (Exception error) { failures.Add(error); }
            finally { if (!retained) session.Dispose(); }
        }
        if (failures.Count > 0) throw new AggregateException("Could not track some audio sessions", failures);
    }

    internal void SetFactor(float factor)
    {
        if (!float.IsFinite(factor) || factor is < 0 or > 1)
            throw new ArgumentOutOfRangeException(nameof(factor));
        Factor = factor;
        List<Exception> failures = [];
        foreach (var entry in baselines.Values)
        {
            try { entry.Session.Volume = entry.Volume * factor; }
            catch (COMException error) { failures.Add(error); }
        }
        if (failures.Count > 0) throw new AggregateException("Could not adjust some audio sessions", failures);
    }

    public void Dispose()
    {
        List<Exception> failures = [];
        foreach (var entry in baselines.Values)
        {
            try { entry.Session.Volume = entry.Volume; }
            catch (COMException error) { failures.Add(error); }
            finally { entry.Session.Dispose(); }
        }
        baselines.Clear();
        Factor = 1;
        if (failures.Count > 0) throw new AggregateException("Could not restore some audio sessions", failures);
    }
}

internal sealed class AudioDucker(string flagPath, Action<string>? log = null) : IDisposable
{
    private readonly ManualResetEventSlim stop = new();
    private Thread? worker;
    private volatile bool enabled = true;
    private int duckPercent = 15;
    private volatile string statusText = "Audio: starting...";
    private string status
    {
        get => statusText;
        set
        {
            if (statusText == value) return;
            statusText = value;
            log?.Invoke(value);
        }
    }
    internal string Status => statusText;
    internal bool Enabled { get => enabled; set => enabled = value; }
    internal int DuckPercent
    {
        get => Volatile.Read(ref duckPercent);
        set
        {
            if (value is < 0 or > 100) throw new ArgumentOutOfRangeException(nameof(value));
            Volatile.Write(ref duckPercent, value);
        }
    }

    internal static bool IsFresh(DateTime lastWriteUtc, DateTime nowUtc) =>
        lastWriteUtc <= nowUtc.AddSeconds(2) && lastWriteUtc > nowUtc.AddSeconds(-8);

    internal void Start()
    {
        worker = new Thread(Run) { IsBackground = true, Name = "ZoneXM audio watchdog" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    private void Run()
    {
        using var mutex = new Mutex(false, "ZoneXM.Watchdog.Singleton");
        var owned = false;
        var initialized = false;
        var duck = new DuckState();
        try
        {
            try { owned = mutex.WaitOne(0); }
            catch (AbandonedMutexException)
            {
                owned = true;
                status = "Audio stopped: previous watchdog ended unexpectedly. Check app volumes, then reopen ZoneXM.";
                return;
            }
            if (!owned)
            {
                status = "Audio stopped: another watchdog is running. Close it, then reopen ZoneXM.";
                return;
            }
            Marshal.ThrowExceptionForHR(CoreAudio.CoInitializeEx(0, 0));
            initialized = true;
            while (!stop.IsSet)
            {
                try
                {
                    var alert = enabled && IsFresh(File.GetLastWriteTimeUtc(flagPath), DateTime.UtcNow);
                    if (alert)
                    {
                        var excluded = new HashSet<int>();
                        foreach (var game in Process.GetProcessesByName("Stalker2-Win64-Shipping"))
                        {
                            using (game) excluded.Add(game.Id);
                        }
                        duck.Add(CoreAudio.Sessions(), excluded);
                        var percent = DuckPercent;
                        var target = percent / 100f;
                        if (duck.Factor != target) Fade(duck, target, target < duck.Factor ? 350 : 1500);
                        status = $"Audio: DUCKED ({percent}%, {duck.Count} sessions)";
                    }
                    else
                    {
                        if (duck.Count > 0)
                        {
                            var count = duck.Count;
                            Fade(duck, 1, 1500);
                            duck.Dispose();
                            log?.Invoke($"Audio: restored {count} sessions (alert cleared/stale or ducking disabled).");
                        }
                        status = enabled ? "Audio: armed (all apps except the game)" : "Audio: disabled (volumes restored)";
                    }
                    stop.Wait(500);
                }
                catch (Exception error)
                {
                    status = $"Audio error ({error.GetType().Name}, 0x{error.HResult:X8}); retrying.";
                    try
                    {
                        duck.Dispose();
                        log?.Invoke("Audio: restoration completed after error.");
                    }
                    catch (Exception restoreError)
                    {
                        status = $"Audio restore error ({restoreError.GetType().Name}, 0x{restoreError.HResult:X8}); check app volumes.";
                    }
                    stop.Wait(2000);
                }
            }
        }
        catch (Exception error)
        {
            status = $"Audio stopped ({error.GetType().Name}, 0x{error.HResult:X8}). Reopen ZoneXM to retry.";
        }
        finally
        {
            try
            {
                var count = duck.Count;
                duck.Dispose();
                if (count > 0) log?.Invoke($"Audio: restored {count} sessions on shutdown.");
            }
            catch (Exception error) { status = $"Audio restoration failed ({error.GetType().Name}, 0x{error.HResult:X8}); check app volumes."; }
            if (initialized) CoreAudio.CoUninitialize();
            if (owned) mutex.ReleaseMutex();
        }
    }

    private void Fade(DuckState duck, float target, int milliseconds)
    {
        var from = duck.Factor;
        var steps = Math.Max(1, milliseconds / 33);
        for (var i = 1; i <= steps && !stop.IsSet; i++)
        {
            if (!enabled && target < 1) break;
            var t = (float)i / steps;
            var smooth = t * t * (3 - 2 * t);
            duck.SetFactor(from + (target - from) * smooth);
            stop.Wait(33);
        }
    }

    public void Dispose()
    {
        stop.Set();
        worker?.Join();
        stop.Dispose();
    }
}
