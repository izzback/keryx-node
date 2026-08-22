using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Poolaris.NodeGui.Services;

public sealed record NodeReleaseInfo(string Tag, string Version, string AssetName, string DownloadUrl);

public sealed class NodeUpdateService
{
    private const string LatestReleaseApi = "https://api.github.com/repos/Keryx-Labs/keryx-node/releases/latest";
    private readonly HttpClient _httpClient;

    public NodeUpdateService()
    {
        _httpClient = new HttpClient();
        _httpClient.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Poolaris-Node-GUI", "0.1"));
        _httpClient.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
    }

    public string? GetInstalledVersion(string executablePath)
    {
        if (!File.Exists(executablePath))
            return null;

        var info = FileVersionInfo.GetVersionInfo(executablePath);
        return info.ProductVersion ?? info.FileVersion;
    }

    public async Task<NodeReleaseInfo> GetLatestReleaseAsync(CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.GetAsync(LatestReleaseApi, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);

        var root = json.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? throw new InvalidDataException("Latest release has no tag name.");
        var version = tag.TrimStart('v', 'V');

        var candidates = root.GetProperty("assets")
            .EnumerateArray()
            .Select(asset => new
            {
                Name = asset.GetProperty("name").GetString() ?? string.Empty,
                Url = asset.GetProperty("browser_download_url").GetString() ?? string.Empty
            })
            .Where(x => x.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            .Where(x => x.Name.Contains("win", StringComparison.OrdinalIgnoreCase) || x.Name.Contains("windows", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.Name.Contains("amd64", StringComparison.OrdinalIgnoreCase) || x.Name.Contains("x64", StringComparison.OrdinalIgnoreCase))
            .ToList();

        var selected = candidates.FirstOrDefault()
            ?? throw new InvalidDataException("No Windows ZIP asset was found in the latest Keryx release.");

        return new NodeReleaseInfo(tag, version, selected.Name, selected.Url);
    }

    public async Task<string> InstallAsync(
        NodeReleaseInfo release,
        string currentExecutablePath,
        bool nodeIsRunning,
        CancellationToken cancellationToken = default)
    {
        if (nodeIsRunning)
            throw new InvalidOperationException("Stop the node before installing an update.");
        if (string.IsNullOrWhiteSpace(currentExecutablePath))
            throw new InvalidOperationException("Select the current keryxd.exe path first.");

        var targetDirectory = Path.GetDirectoryName(currentExecutablePath)
            ?? throw new InvalidOperationException("Invalid keryxd.exe path.");
        Directory.CreateDirectory(targetDirectory);

        var workRoot = Path.Combine(Path.GetTempPath(), "PoolarisNodeGui", Guid.NewGuid().ToString("N"));
        var zipPath = Path.Combine(workRoot, release.AssetName);
        var extractPath = Path.Combine(workRoot, "extract");
        Directory.CreateDirectory(extractPath);

        try
        {
            using (var response = await _httpClient.GetAsync(release.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
            {
                response.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
                await using var destination = File.Create(zipPath);
                await source.CopyToAsync(destination, cancellationToken);
            }

            ZipFile.ExtractToDirectory(zipPath, extractPath, overwriteFiles: true);

            var newExecutable = Directory.EnumerateFiles(extractPath, "keryxd.exe", SearchOption.AllDirectories).FirstOrDefault()
                ?? throw new InvalidDataException("The downloaded release does not contain keryxd.exe.");

            var timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var backupPath = currentExecutablePath + $".backup-{timestamp}";

            if (File.Exists(currentExecutablePath))
                File.Copy(currentExecutablePath, backupPath, overwrite: false);

            var stagedPath = currentExecutablePath + ".new";
            File.Copy(newExecutable, stagedPath, overwrite: true);
            File.Move(stagedPath, currentExecutablePath, overwrite: true);

            return backupPath;
        }
        finally
        {
            try { if (Directory.Exists(workRoot)) Directory.Delete(workRoot, recursive: true); } catch { }
        }
    }

    public static bool VersionsDiffer(string? installedVersion, string latestVersion)
    {
        if (string.IsNullOrWhiteSpace(installedVersion))
            return true;

        var installed = installedVersion.Split('+', '-', ' ').FirstOrDefault() ?? installedVersion;
        var latest = latestVersion.Split('+', '-', ' ').FirstOrDefault() ?? latestVersion;

        if (Version.TryParse(installed, out var current) && Version.TryParse(latest, out var newest))
            return newest > current;

        return !string.Equals(installedVersion.TrimStart('v', 'V'), latestVersion.TrimStart('v', 'V'), StringComparison.OrdinalIgnoreCase);
    }
}
