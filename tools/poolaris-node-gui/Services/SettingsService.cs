using System.Text.Json;
using Poolaris.NodeGui.Models;

namespace Poolaris.NodeGui.Services;

public sealed class SettingsService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _settingsPath;

    public SettingsService()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Poolaris",
            "NodeGui");
        Directory.CreateDirectory(root);
        _settingsPath = Path.Combine(root, "settings.json");
    }

    public NodeLaunchOptions Load()
    {
        try
        {
            if (!File.Exists(_settingsPath))
                return new NodeLaunchOptions();

            var json = File.ReadAllText(_settingsPath);
            return JsonSerializer.Deserialize<NodeLaunchOptions>(json, JsonOptions) ?? new NodeLaunchOptions();
        }
        catch
        {
            return new NodeLaunchOptions();
        }
    }

    public void Save(NodeLaunchOptions options)
    {
        var json = JsonSerializer.Serialize(options, JsonOptions);
        File.WriteAllText(_settingsPath, json);
    }
}
