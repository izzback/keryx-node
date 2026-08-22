using System.Diagnostics;
using System.Globalization;
using Poolaris.NodeGui.Models;

namespace Poolaris.NodeGui.Services;

public sealed class NodeProcessService
{
    private Process? _ownedProcess;

    public Process? FindRunningNode()
    {
        if (_ownedProcess is { HasExited: false })
        {
            return _ownedProcess;
        }

        return Process.GetProcessesByName("keryxd")
            .OrderByDescending(p =>
            {
                try { return p.StartTime; }
                catch { return DateTime.MinValue; }
            })
            .FirstOrDefault();
    }

    public string BuildArguments(NodeLaunchOptions options)
    {
        var args = new List<string>
        {
            $"--appdir=\"{options.DataDirectory}\"",
            $"--async-threads={options.AsyncThreads}",
            $"--ram-scale={options.RamScale.ToString(CultureInfo.InvariantCulture)}",
            $"--rocksdb-preset={options.RocksDbPreset}",
            $"--rocksdb-cache-size={options.RocksDbCacheMiB}",
            $"--outpeers={options.OutboundPeers}",
            $"--maxinpeers={options.MaxInboundPeers}",
            $"--loglevel={options.LogLevel}"
        };

        if (options.Testnet)
            args.Add("--testnet");
        if (options.UtxoIndex)
            args.Add("--utxoindex");
        if (!options.AcceptInbound)
            args.Add("--connect=127.0.0.1:1");
        if (options.EnableGrpc)
            args.Add($"--rpclisten=127.0.0.1:{options.GrpcPort}");
        if (options.EnableWrpcJson)
            args.Add($"--rpclisten-json=127.0.0.1:{options.WrpcJsonPort}");
        if (options.EnableWrpcBorsh)
            args.Add($"--rpclisten-borsh=127.0.0.1:{options.WrpcBorshPort}");

        return string.Join(' ', args);
    }

    public Process Start(NodeLaunchOptions options)
    {
        if (FindRunningNode() is { HasExited: false })
            throw new InvalidOperationException("A keryxd process is already running.");

        if (!File.Exists(options.NodeExecutable))
            throw new FileNotFoundException("keryxd.exe was not found.", options.NodeExecutable);

        Directory.CreateDirectory(options.DataDirectory);

        var startInfo = new ProcessStartInfo
        {
            FileName = options.NodeExecutable,
            Arguments = BuildArguments(options),
            WorkingDirectory = Path.GetDirectoryName(options.NodeExecutable) ?? Environment.CurrentDirectory,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (options.EnableIbdPerf)
            startInfo.Environment["KERYX_IBD_PERF"] = "1";

        _ownedProcess = Process.Start(startInfo) ?? throw new InvalidOperationException("Unable to start keryxd.exe.");
        return _ownedProcess;
    }

    public async Task StopAsync(TimeSpan gracefulWait)
    {
        var process = FindRunningNode();
        if (process is null || process.HasExited)
            return;

        // When we own a console-less process, CloseMainWindow may not be supported.
        // Try it first; force kill only after the grace period.
        try { process.CloseMainWindow(); } catch { }

        var deadline = DateTime.UtcNow + gracefulWait;
        while (!process.HasExited && DateTime.UtcNow < deadline)
            await Task.Delay(250);

        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
        }
    }
}
