using System.Globalization;
using System.Text.RegularExpressions;

namespace Poolaris.NodeGui.Services;

public sealed record KeryxLogSnapshot(
    string LogFile,
    IReadOnlyList<string> Tail,
    double BlocksPerSecond,
    DateTimeOffset? LastBlockTimestamp,
    string? LatestIbdPerfLine);

public sealed partial class KeryxLogService
{
    [GeneratedRegex(@"Processed\s+(?<blocks>\d+)\s+blocks.*?last\s+(?<seconds>[0-9.]+)s", RegexOptions.IgnoreCase)]
    private static partial Regex ProcessedBlocksRegex();

    [GeneratedRegex(@"last block timestamp:\s*(?<timestamp>.+)$", RegexOptions.IgnoreCase)]
    private static partial Regex LastBlockTimestampRegex();

    public KeryxLogSnapshot Read(string dataDirectory, int maxLines = 120)
    {
        var file = FindNewestLog(dataDirectory);
        if (file is null)
            return new(string.Empty, Array.Empty<string>(), 0, null, null);

        var tail = ReadTail(file, maxLines);
        double bps = 0;
        DateTimeOffset? lastBlock = null;
        string? ibdPerf = null;

        foreach (var line in tail)
        {
            var processed = ProcessedBlocksRegex().Match(line);
            if (processed.Success &&
                double.TryParse(processed.Groups["blocks"].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var blocks) &&
                double.TryParse(processed.Groups["seconds"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) &&
                seconds > 0)
            {
                bps = blocks / seconds;
            }

            var timestampMatch = LastBlockTimestampRegex().Match(line);
            if (timestampMatch.Success)
            {
                var raw = timestampMatch.Groups["timestamp"].Value.Trim();
                if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var parsed))
                    lastBlock = parsed;
            }

            if (line.Contains("IBD-PERF:", StringComparison.OrdinalIgnoreCase))
                ibdPerf = line;
        }

        return new(file, tail, bps, lastBlock, ibdPerf);
    }

    private static string? FindNewestLog(string dataDirectory)
    {
        var roots = new List<string>();
        if (Directory.Exists(dataDirectory)) roots.Add(dataDirectory);

        var parent = Path.GetDirectoryName(dataDirectory);
        if (!string.IsNullOrWhiteSpace(parent) && Directory.Exists(parent)) roots.Add(parent);

        return roots
            .SelectMany(root => SafeEnumerate(root, "*.log"))
            .Select(path => new FileInfo(path))
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .Select(file => file.FullName)
            .FirstOrDefault();
    }

    private static IEnumerable<string> SafeEnumerate(string root, string pattern)
    {
        try { return Directory.EnumerateFiles(root, pattern, SearchOption.AllDirectories).Take(200); }
        catch { return Array.Empty<string>(); }
    }

    private static IReadOnlyList<string> ReadTail(string path, int maxLines)
    {
        try
        {
            // Keryx logs are line oriented. Reading all lines is acceptable for the first GUI
            // milestone; the next milestone will keep a streaming file cursor.
            return File.ReadLines(path).TakeLast(maxLines).ToArray();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }
}
