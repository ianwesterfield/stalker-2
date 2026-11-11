namespace ZoneXM.Notifications;

internal sealed class ActivityLog
{
    internal const int Capacity = 200;
    private readonly object gate = new();
    private readonly Queue<string> entries = new();
    private long version;

    internal void Add(string message)
    {
        lock (gate)
        {
            entries.Enqueue($"[{DateTimeOffset.Now:HH:mm:ss.fff}] {message}");
            while (entries.Count > Capacity) entries.Dequeue();
            version++;
        }
    }

    internal (long Version, string Text) Snapshot()
    {
        lock (gate) return (version, string.Join(Environment.NewLine, entries));
    }

    internal void Clear()
    {
        lock (gate)
        {
            entries.Clear();
            version++;
        }
    }
}
