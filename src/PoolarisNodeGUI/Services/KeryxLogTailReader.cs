using System.IO;
using System.Text;

namespace PoolarisNodeGUI.Services;

public sealed record KeryxLogReadResult(
    string? ActiveFile,
    string Text,
    string Status,
    int LineCount);

public static class KeryxLogTailReader
{
    private static readonly string[] PreferredExtensions = [".log", ".txt"];

    public static KeryxLogReadResult ReadNewest(
        string? logDirectory,
        int maxLines = 1500,
        int maxBytes = 1024 * 1024)
    {
        if (string.IsNullOrWhiteSpace(logDirectory))
            return new(null, string.Empty, "AppDir non configuré : impossible de résoudre le dossier de logs Keryx.", 0);

        if (!Directory.Exists(logDirectory))
            return new(null, string.Empty, $"Dossier de logs introuvable : {logDirectory}", 0);

        var activeFile = FindNewestLogFile(logDirectory);
        if (activeFile is null)
            return new(null, string.Empty, $"Aucun fichier de log trouvé dans : {logDirectory}", 0);

        try
        {
            var lines = ReadTailLines(activeFile, Math.Clamp(maxLines, 100, 10_000), Math.Clamp(maxBytes, 64 * 1024, 8 * 1024 * 1024));
            var lastWrite = File.GetLastWriteTime(activeFile);
            return new(
                activeFile,
                string.Join(Environment.NewLine, lines),
                $"{lines.Count:N0} lignes affichées · dernière écriture {lastWrite:HH:mm:ss}",
                lines.Count);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new(activeFile, string.Empty, $"Impossible de lire le log actif : {ex.Message}", 0);
        }
    }

    public static string? FindNewestLogFile(string logDirectory)
    {
        try
        {
            return Directory.EnumerateFiles(logDirectory, "*", SearchOption.AllDirectories)
                .Where(IsLogCandidate)
                .Select(path => new FileInfo(path))
                .OrderByDescending(file => file.LastWriteTimeUtc)
                .ThenByDescending(file => file.Length)
                .Select(file => file.FullName)
                .FirstOrDefault();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static bool IsLogCandidate(string path)
    {
        var extension = Path.GetExtension(path);
        if (PreferredExtensions.Contains(extension, StringComparer.OrdinalIgnoreCase))
            return true;

        var name = Path.GetFileName(path);
        return name.Contains("log", StringComparison.OrdinalIgnoreCase);
    }

    private static IReadOnlyList<string> ReadTailLines(string path, int maxLines, int maxBytes)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);

        var start = Math.Max(0, stream.Length - maxBytes);
        stream.Seek(start, SeekOrigin.Begin);

        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 16 * 1024, leaveOpen: false);
        if (start > 0)
            _ = reader.ReadLine(); // Drop the partial first line after seeking into a large file.

        var queue = new Queue<string>(maxLines + 1);
        while (reader.ReadLine() is { } line)
        {
            queue.Enqueue(line);
            if (queue.Count > maxLines)
                queue.Dequeue();
        }

        return queue.ToArray();
    }
}
