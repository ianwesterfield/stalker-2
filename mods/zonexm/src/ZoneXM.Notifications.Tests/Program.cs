using System.Text;
using System.Runtime.InteropServices;
using ZoneXM.Notifications;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}
var file = Path.Combine(Path.GetTempPath(), $"zonexm-notifications-test-{Guid.NewGuid():N}.txt");
try
{
    var events = new List<string>();
    var bridge = new NotificationBridge(file, events.Add);
    var now = DateTimeOffset.FromUnixTimeSeconds(1800000000);
    var allowed = new HashSet<string>(StringComparer.Ordinal) { "Pandora", "Mail", "Calendar" };
    var history = new Notice(1, now.AddSeconds(-100), "Pandora", "Pandora", "Old song", "Artist");
    void Observe(DateTimeOffset when, params Notice[] notices)
    {
        bridge.Observe(notices, allowed, when);
        bridge.Publish(when);
    }
    string[] Lines() => File.ReadAllLines(file);
    Observe(now, history);
    Check(Lines().Length == 8 && Lines()[3] == "", "Startup history was replayed");
    Check(events.Count == 1 && events[0].Contains("baseline"), "Baseline diagnostics missing");
    var first = new Notice(2, now, "Pandora", "Pandora", "Song", "Artist");
    Observe(now, history, first);
    var firstId = Lines()[4];
    Check(Lines()[0] == "ZoneXM/notification/1" && Lines()[6] == "Song", "New entry not published");
    Check(events.Any(e => e.Contains("received/updated")) && events.Any(e => e.Contains("forwarded to banner file")),
        "Receipt/publication diagnostics missing");
    var eventCount = events.Count;
    Observe(now.AddSeconds(1), history, first);
    Check(events.Count == eventCount, "Heartbeats spammed activity log");
    Check(Lines()[4] == firstId && Lines()[2] == now.ToUnixTimeSeconds().ToString(), "Heartbeat reset event age or ID");
    var repeated = first with { Id = 3, Created = now.AddSeconds(2) };
    Observe(now.AddSeconds(2), first, repeated);
    Check(Lines()[4] != firstId, "Identical text with new notification ID was suppressed");
    var updated = repeated with { Title = "Updated", Created = now.AddSeconds(3) };
    Observe(now.AddSeconds(3), updated);
    Check(Lines()[6] == "Updated", "Updated notification content lost");
    allowed.Remove("Pandora");
    Observe(now.AddSeconds(4), updated);
    Check(Lines()[3] == "", "Revoking consent for pending app did not clear it");
    allowed.Add("Pandora");
    Observe(now.AddSeconds(5), updated);
    Check(Lines()[3] == "", "Filter change replayed seen history");
    var mail = new Notice(4, now.AddSeconds(6), "Mail", "Mail", "Subject", "Body");
    var latest = new Notice(5, now.AddSeconds(7), "Calendar", "Calendar", "Meeting", "Soon");
    Observe(now.AddSeconds(7), latest, mail);
    Check(Lines()[3] == "Calendar", "Burst did not select newest entry");
    Observe(now.AddSeconds(37), latest, mail);
    Check(Lines()[3] == "", "Notification did not expire at 30 seconds");
    Check(events.Any(e => e.Contains("30-second expiry")), "Expiry diagnostic missing");
    var stale = latest with { Id = 99, Created = now.AddSeconds(-60) };
    Observe(now.AddSeconds(38), stale);
    Check(Lines()[3] == "", "Delayed old entry was replayed");
    var future = latest with { Id = 100, Created = now.AddSeconds(50) };
    Observe(now.AddSeconds(39), future);
    Check(Lines()[3] == "", "Future notification accepted");
    bridge.Reset();
    Observe(now.AddSeconds(40), latest, mail);
    Check(Lines()[3] == "", "Resume replayed accumulated notifications");
    var unicode = first with { Id = 6, Created = now.AddSeconds(41), Title = "Music\n\u97f3\U0001f3b5", Body = "A\0B\tC" };
    Observe(now.AddSeconds(41), unicode);
    Check(Lines()[6] == "Music \u97f3\U0001f3b5" && Lines()[7] == "A B C", "UTF-8 or sanitization failed");
    Check(File.ReadAllBytes(file)[0] == (byte)'Z', "Unexpected UTF-8 BOM");
    Check(NotificationBridge.Clean(string.Concat(Enumerable.Repeat("\U0001f3b5", 241))).EnumerateRunes().Count() == 240,
        "Truncation broke Unicode or bound");
    Observe(now.AddSeconds(42));
    Check(Lines()[3] == "", "Dismissed notification was retained");
    bridge.Clear();
    Check(!File.Exists(file) && !File.Exists(file + ".tmp"), "Notification contents left after stop");
    allowed.Clear();
    Observe(now.AddSeconds(43));
    var unapproved = first with { Id = 200, AppId = "New.App", Created = now.AddSeconds(44) };
    Observe(now.AddSeconds(44), unapproved);
    Check(Lines()[3] == "", "Newly discovered app forwarded without consent");
    allowed.Add("Other.App");
    Observe(now.AddSeconds(45), unapproved with { Id = 201 });
    Check(Lines()[3] == "", "Allowing one app permitted another app");
    allowed.Add("New.App");
    bridge.Reset();
    Observe(now.AddSeconds(46), unapproved);
    Check(Lines()[3] == "", "Opt-in replayed existing history");
    Observe(now.AddSeconds(47), unapproved with { Id = 202, Created = now.AddSeconds(47) });
    Check(Lines()[3] == "New.App", "Explicitly opted-in app did not forward");
    allowed.Remove("New.App");
    Observe(now.AddSeconds(48), unapproved with { Id = 202, Created = now.AddSeconds(47) });
    Check(Lines()[3] == "", "Opt-out left a pending notification");
    Observe(now.AddSeconds(49), unapproved with { Id = 203, Created = now.AddSeconds(49) });
    Check(Lines()[3] == "", "Reopened unapproved app forwarded");
    Check(events.All(e => !e.Contains("Music") && !e.Contains("A\0B") && !e.Contains("Artist") && !e.Contains("Subject")),
        "Notification title/body leaked to diagnostics");
    Console.WriteLine("PASS: startup/resume history, event IDs, opt-in-only apps, new/reopened apps denied, consent revocation, newest-only bursts, expiry, dismissal, UTF-8, atomic snapshots, cleanup");
}
finally
{
    if (File.Exists(file)) File.Delete(file);
    if (File.Exists(file + ".tmp")) File.Delete(file + ".tmp");
}

var settingsPath = Path.Combine(Path.GetTempPath(), $"zonexm-settings-{Guid.NewGuid():N}.json");
try
{
    var defaults = HelperSettings.Load(settingsPath);
    Check(defaults.AllowedApps.Length == 0 && defaults.DuckPercent == 15, "Defaults must be opt-in only and 15%");
    foreach (var percent in new[] { 0, 15, 67, 100 })
    {
        new HelperSettings { DuckPercent = percent, AllowedApps = ["Exact.App!Id"] }.Save(settingsPath);
        var loaded = HelperSettings.Load(settingsPath);
        Check(loaded.DuckPercent == percent && loaded.AllowedApps.SequenceEqual(["Exact.App!Id"]), "Settings roundtrip failed");
    }
    foreach (var invalid in new[] { "null", "[]", "{\"Version\":2}", "{\"DuckPercent\":101}", "{\"AllowedApps\":null}" })
    {
        File.WriteAllText(settingsPath, invalid);
        var rejected = false;
        try { HelperSettings.Load(settingsPath); }
        catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { rejected = true; }
        Check(rejected, "Malformed or legacy settings were accepted as consent");
    }
    Check(!File.Exists(settingsPath + ".tmp"), "Settings temporary file left behind");
    Console.WriteLine("PASS: opt-in defaults, persisted percentage/allowlist, invalid and legacy settings fail closed");
}
finally { File.Delete(settingsPath); }

var activity = new ActivityLog();
for (var i = 0; i < 250; i++) activity.Add($"event-{i}");
var activitySnapshot = activity.Snapshot();
var activityLines = activitySnapshot.Text.Split(Environment.NewLine);
Check(activityLines.Length == ActivityLog.Capacity && activityLines[0].EndsWith("event-50")
    && activityLines[^1].EndsWith("event-249"), "Activity capacity/order wrong");
Check(System.Text.RegularExpressions.Regex.IsMatch(activityLines[0], @"^\[\d{2}:\d{2}:\d{2}\.\d{3}\] "),
    "Local timestamp missing");
Check(activity.Snapshot().Version == activitySnapshot.Version, "Reading mutated activity log");
activity.Clear();
Check(activity.Snapshot().Text == "" && activity.Snapshot().Version > activitySnapshot.Version, "Clear did not refresh log");
Parallel.For(0, 1000, i => activity.Add($"parallel-{i}"));
Check(activity.Snapshot().Text.Split(Environment.NewLine).Length == ActivityLog.Capacity, "Concurrent activity logging failed");
Console.WriteLine("PASS: bounded timestamped activity, concurrency, clear, notification events, heartbeat suppression, content privacy");

var audioNow = DateTime.UtcNow;
Check(AudioDucker.IsFresh(audioNow.AddSeconds(-7.9), audioNow), "Fresh alert rejected");
Check(!AudioDucker.IsFresh(audioNow.AddSeconds(-8), audioNow), "Stale alert accepted");
Check(!AudioDucker.IsFresh(audioNow.AddSeconds(3), audioNow), "Future alert accepted");
var duck = new DuckState();
var gameSession = new FakeAudio("game", 100, 0.9f);
var music = new FakeAudio("music", 200, 0.8f);
var second = new FakeAudio("music-second-session", 200, 0.4f);
var muted = new FakeAudio("muted", 300, 0);
duck.Add([gameSession, music, second, muted], new HashSet<int> { 100 });
Check(duck.Count == 2 && gameSession.Disposed && muted.Disposed, "Excluded/muted sessions retained");
duck.SetFactor(0.15f);
Check(Math.Abs(music.Volume - 0.12f) < 0.00001f && Math.Abs(second.Volume - 0.06f) < 0.00001f,
    "Per-session baseline duck level wrong");
Check(gameSession.Volume == 0.9f, "Game volume changed");
var duplicate = new FakeAudio("music", 200, music.Volume);
var newcomer = new FakeAudio("new-session", 400, 0.6f);
duck.Add([duplicate, newcomer], new HashSet<int>());
Check(duplicate.Disposed && Math.Abs(newcomer.Volume - 0.09f) < 0.00001f, "Latecomer or duplicate handling failed");
foreach (var factor in new[] { 0f, 0.67f, 1f, 0.15f })
{
    duck.SetFactor(factor);
    Check(Math.Abs(music.Volume - 0.8f * factor) < 0.00001f
        && Math.Abs(newcomer.Volume - 0.6f * factor) < 0.00001f,
        "Changing slider target compounded ducking instead of using original volume");
}
foreach (var invalid in new[] { -1f, 1.01f, float.NaN, float.PositiveInfinity })
{
    var rejected = false;
    try { duck.SetFactor(invalid); } catch (ArgumentOutOfRangeException) { rejected = true; }
    Check(rejected, "Invalid duck factor accepted");
}
using (var adjustable = new AudioDucker("unused-test-flag"))
{
    Check(adjustable.DuckPercent == 15, "Default percentage changed");
    foreach (var percent in new[] { 0, 67, 100 }) { adjustable.DuckPercent = percent; Check(adjustable.DuckPercent == percent, "Target not applied"); }
    foreach (var percent in new[] { -1, 101 })
    {
        var rejected = false;
        try { adjustable.DuckPercent = percent; } catch (ArgumentOutOfRangeException) { rejected = true; }
        Check(rejected, "Invalid percentage accepted");
    }
}
duck.Dispose();
Check(music.Volume == 0.8f && second.Volume == 0.4f && newcomer.Volume == 0.6f &&
    music.Disposed && second.Disposed && newcomer.Disposed, "Restore/disposal failed");
duck.Dispose();
var failed = new FakeAudio("failed", 1, 0.7f) { FailRead = true };
var afterFailure = new FakeAudio("after-failure", 2, 0.3f);
try { duck.Add([failed, afterFailure], new HashSet<int>()); throw new Exception("Expected audio read failure"); }
catch (AggregateException) { }
Check(failed.Disposed && duck.Count == 1, "Enumeration references leaked on error");
afterFailure.FailWrite = true;
try { duck.Dispose(); throw new Exception("Expected restoration failure"); }
catch (AggregateException) { }
Check(afterFailure.Disposed && duck.Count == 0, "Failed restoration did not release owned sessions");
Console.WriteLine("PASS: audio freshness, game exclusion, multiple sessions per app, 15% levels, latecomers, restoration, error cleanup");

// Read-only live interop check on an explicit MTA; never changes user volumes.
Exception? probeFailure = null;
var probe = new Thread(() =>
{
    var initialized = false;
    try
    {
        Marshal.ThrowExceptionForHR(CoreAudio.CoInitializeEx(0, 0));
        initialized = true;
        var sessions = CoreAudio.Sessions();
        try
        {
            foreach (var session in sessions)
                Check(session.Volume >= 0 && session.Volume <= 1, "Live volume out of range");
            Console.WriteLine($"PASS: live CoreAudio enumerated/read {sessions.Count} sessions without changing volume");
        }
        finally { foreach (var session in sessions) session.Dispose(); }
    }
    catch (Exception error) { probeFailure = error; }
    finally { if (initialized) CoreAudio.CoUninitialize(); }
});
probe.SetApartmentState(ApartmentState.MTA);
probe.Start();
probe.Join();
if (probeFailure is not null) throw probeFailure;

internal sealed class FakeAudio(string id, int pid, float volume) : IAudioSession
{
    public string Id { get; } = id;
    public int ProcessId { get; } = pid;
    internal bool Disposed { get; private set; }
    internal bool FailRead { get; init; }
    internal bool FailWrite { get; set; }
    public float Volume
    {
        get => FailRead ? throw new COMException("Synthetic read error") : volume;
        set
        {
            if (FailWrite) throw new COMException("Synthetic write error");
            volume = value;
        }
    }
    public void Dispose() => Disposed = true;
}
