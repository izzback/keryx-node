using System.IO;

namespace PoolarisNodeGUI.Services;

public static class KeryxPathResolver
{
    public const string MainnetPrefix = "keryx-mainnet";
    public const string DefaultTestnetPrefix = "keryx-testnet-10";

    public static string ResolveDatabasePath(string? appDirectory, bool testnet)
    {
        if (string.IsNullOrWhiteSpace(appDirectory))
        {
            return string.Empty;
        }

        var root = Path.GetFullPath(appDirectory.Trim());
        var networkPrefix = testnet ? DefaultTestnetPrefix : MainnetPrefix;
        return Path.Combine(root, networkPrefix, "datadir");
    }

    public static string ResolveDefaultLogPath(string? appDirectory, bool testnet)
    {
        if (string.IsNullOrWhiteSpace(appDirectory))
        {
            return string.Empty;
        }

        var root = Path.GetFullPath(appDirectory.Trim());
        var networkPrefix = testnet ? DefaultTestnetPrefix : MainnetPrefix;
        return Path.Combine(root, networkPrefix, "logs");
    }

    public static bool LooksLikeDatabaseDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        var normalized = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Replace(Path.AltDirectorySeparatorChar, Path.DirectorySeparatorChar);
        return normalized.EndsWith($"{Path.DirectorySeparatorChar}{MainnetPrefix}{Path.DirectorySeparatorChar}datadir", StringComparison.OrdinalIgnoreCase)
            || normalized.EndsWith($"{Path.DirectorySeparatorChar}{DefaultTestnetPrefix}{Path.DirectorySeparatorChar}datadir", StringComparison.OrdinalIgnoreCase);
    }

    public static string? SuggestAppDirectory(string? databaseDirectory)
    {
        if (!LooksLikeDatabaseDirectory(databaseDirectory))
        {
            return null;
        }

        var directory = new DirectoryInfo(Path.GetFullPath(databaseDirectory!));
        return directory.Parent?.Parent?.FullName;
    }
}
