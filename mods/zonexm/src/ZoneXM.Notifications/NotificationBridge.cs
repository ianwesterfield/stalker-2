using System.IO;
using System.Text;

namespace ZoneXM.Notifications;

internal sealed record Notice(uint Id, DateTimeOffset Created, string AppId, string AppName,
    string Title, string Body);

internal sealed class NotificationBridge(string outputPath, Action<string>? log = null)
{
    internal const int LifetimeSeconds = 30;
    private HashSet<Notice> previous = [];
    private bool primed;
    private Notice? pending;
    private DateTimeOffset received;
    private string eventId = "";
    private readonly string runId = Guid.NewGuid().ToString("N");
    private long sequence;
    private string publishedEvent = "";

    internal void Reset()
    {
        previous.Clear();
        pending = null;
        primed = false;
    }

    internal void Observe(IEnumerable<Notice> notices, ISet<string> allowed, DateTimeOffset now)
    {
        var current = notices.ToHashSet();
        if (primed)
        {
            foreach (var notice in current.OrderBy(n => n.Created).ThenBy(n => n.Id))
            {
                if (previous.Contains(notice)) continue;
                var reason = !allowed.Contains(notice.AppId) ? "app not opted in"
                    : string.IsNullOrWhiteSpace(notice.Title) ? "empty title"
                    : notice.Created > now.AddSeconds(2) ? "future timestamp"
                    : notice.Created < now.AddSeconds(-LifetimeSeconds) ? "older than 30 seconds" : null;
                var app = Clean(notice.AppId);
                if (reason is not null)
                {
                    log?.Invoke($"Notification ignored: app={app}, id={notice.Id}, reason={reason}.");
                    continue;
                }
                log?.Invoke($"Notification received/updated: app={app}, id={notice.Id}.");
                pending = notice;
                received = now;
                eventId = $"{runId}:{++sequence}";
            }
        }
        else log?.Invoke($"Notification baseline: {current.Count} eligible entries; existing history skipped.");
        previous = current;
        primed = true;
        if (pending is not null)
        {
            var reason = !allowed.Contains(pending.AppId) ? "app not opted in"
                : !current.Contains(pending) ? "dismissed/replaced in Notification Center"
                : now - received >= TimeSpan.FromSeconds(LifetimeSeconds) ? "30-second expiry" : null;
            if (reason is not null)
            {
                log?.Invoke($"Notification cleared: {reason}.");
                pending = null;
            }
        }
    }

    internal void Publish(DateTimeOffset now)
    {
        var notice = pending;
        string[] lines = [
            "ZoneXM/notification/1", now.ToUnixTimeSeconds().ToString(),
            notice is null ? "0" : received.ToUnixTimeSeconds().ToString(),
            notice?.AppId ?? "", notice is null ? "" : eventId,
            notice?.AppName ?? "", notice?.Title ?? "", notice?.Body ?? ""
        ];
        var temporary = outputPath + ".tmp";
        try
        {
            File.WriteAllText(temporary, string.Join('\n', lines.Select(Clean)) + "\n",
                new UTF8Encoding(false, true));
            File.Move(temporary, outputPath, true);
            var next = notice is null ? "" : eventId;
            if (next != publishedEvent)
            {
                log?.Invoke(notice is null ? "Banner file is idle."
                    : $"Notification forwarded to banner file: app={Clean(notice.AppId)}, id={notice.Id}. Game display not confirmed.");
                publishedEvent = next;
            }
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    internal void Clear()
    {
        Reset();
        if (File.Exists(outputPath)) File.Delete(outputPath);
        publishedEvent = "";
    }

    internal static string Clean(string value)
    {
        var result = new StringBuilder();
        foreach (var rune in value.EnumerateRunes().Take(240))
            result.Append(Rune.IsControl(rune) || rune.Value is 0x2028 or 0x2029 ? " " : rune.ToString());
        return result.ToString().Trim();
    }
}
