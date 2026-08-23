using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.Tests;

public sealed class KeryxLogTailReaderTests
{
    [Fact]
    public void FindsNewestLogFile()
    {
        var root = CreateTempDirectory();
        try
        {
            var older = Path.Combine(root, "older.log");
            var newer = Path.Combine(root, "keryx.log");
            File.WriteAllText(older, "old");
            File.WriteAllText(newer, "new");
            File.SetLastWriteTimeUtc(older, DateTime.UtcNow.AddMinutes(-2));
            File.SetLastWriteTimeUtc(newer, DateTime.UtcNow);

            var result = KeryxLogTailReader.FindNewestLogFile(root);

            Assert.Equal(newer, result);
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public void ReadNewestKeepsOnlyRequestedTail()
    {
        var root = CreateTempDirectory();
        try
        {
            var path = Path.Combine(root, "keryx.log");
            File.WriteAllLines(path, Enumerable.Range(0, 150).Select(i => $"line-{i:000}"));

            var result = KeryxLogTailReader.ReadNewest(root, maxLines: 100);

            Assert.Equal(path, result.ActiveFile);
            Assert.Equal(100, result.LineCount);
            Assert.DoesNotContain("line-000", result.Text);
            Assert.Contains("line-050", result.Text);
            Assert.Contains("line-149", result.Text);
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public void MissingDirectoryIsReportedWithoutThrowing()
    {
        var root = Path.Combine(Path.GetTempPath(), "PoolarisNodeGUI.Tests", Guid.NewGuid().ToString("N"));

        var result = KeryxLogTailReader.ReadNewest(root);

        Assert.Null(result.ActiveFile);
        Assert.Empty(result.Text);
        Assert.Contains("introuvable", result.Status, StringComparison.OrdinalIgnoreCase);
    }

    private static string CreateTempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "PoolarisNodeGUI.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }
}
