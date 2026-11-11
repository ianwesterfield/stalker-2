using System.Text.Json;

namespace ZoneXM.Notifications;

internal sealed record HelperSettings
{
    public int Version { get; init; } = 1;
    public int DuckPercent { get; init; } = 15;
    public string[] AllowedApps { get; init; } = [];

    internal void Validate()
    {
        if (Version != 1 || DuckPercent is < 0 or > 100 || AllowedApps is null
            || AllowedApps.Any(string.IsNullOrWhiteSpace))
            throw new InvalidDataException("Invalid helper settings.");
    }

    internal static HelperSettings Load(string path)
    {
        if (!File.Exists(path)) return new();
        var settings = JsonSerializer.Deserialize<HelperSettings>(File.ReadAllText(path))
            ?? throw new InvalidDataException("Missing helper settings.");
        settings.Validate();
        return settings;
    }

    internal void Save(string path)
    {
        Validate();
        var temporary = path + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
