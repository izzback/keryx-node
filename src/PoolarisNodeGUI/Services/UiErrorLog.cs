using System.Text;

namespace PoolarisNodeGUI.Services;

public static class UiErrorLog
{
    public static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PoolarisNodeGUI",
        "diagnostics",
        "ui-errors.log");

    public static void Write(Exception exception, string source)
    {
        try
        {
            var path = LogPath;
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
                Directory.CreateDirectory(directory);

            var entry = new StringBuilder()
                .AppendLine("============================================================")
                .AppendLine($"Timestamp: {DateTimeOffset.Now:O}")
                .AppendLine($"Source: {source}")
                .AppendLine($"Type: {exception.GetType().FullName}")
                .AppendLine($"Message: {exception.Message}")
                .AppendLine("StackTrace:")
                .AppendLine(exception.StackTrace ?? "—")
                .AppendLine("InnerException:")
                .AppendLine(exception.InnerException?.ToString() ?? "—")
                .ToString();

            File.AppendAllText(path, entry, Encoding.UTF8);
        }
        catch
        {
            // Diagnostics must never become a second crash source.
        }
    }
}
