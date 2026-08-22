using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public sealed class KeryxArgumentBuilder
{
    public IReadOnlyList<string> Build(NodeSettings settings)
    {
        var args = new List<string>();

        if (!string.IsNullOrWhiteSpace(settings.AppDirectory))
            args.Add($"--appdir={settings.AppDirectory.Trim()}");

        if (settings.IsTestnet)
            args.Add("--testnet");

        if (settings.EnableGrpc)
            args.Add($"--rpclisten=127.0.0.1:{settings.GrpcPort}");
        else
            args.Add("--nogrpc");

        if (settings.EnableWrpcBorsh)
            args.Add($"--rpclisten-borsh=127.0.0.1:{settings.WrpcBorshPort}");

        if (settings.EnableWrpcJson)
            args.Add($"--rpclisten-json=127.0.0.1:{settings.WrpcJsonPort}");

        args.Add($"--async-threads={settings.AsyncThreads}");
        args.Add($"--ram-scale={settings.RamScale:0.##}");
        args.Add($"--rocksdb-preset={settings.RocksDbPreset}");
        args.Add($"--rocksdb-cache-size={settings.RocksDbCacheSizeMb}");
        args.Add($"--outpeers={settings.OutboundPeers}");
        args.Add($"--maxinpeers={(settings.AcceptInboundConnections ? settings.MaxInboundPeers : 0)}");
        args.Add($"--loglevel={settings.LogLevel}");

        if (settings.UtxoIndex)
            args.Add("--utxoindex");
        if (!settings.DnsPeerDiscovery)
            args.Add("--nodnsseed");
        if (!settings.Upnp)
            args.Add("--disable-upnp");
        if (settings.Archival)
            args.Add("--archival");
        if (settings.UnsafeRpc)
            args.Add("--unsaferpc");
        if (settings.EnableUnsyncedMining)
            args.Add("--enable-unsynced-mining");
        if (settings.DisableLogFiles)
            args.Add("--nologfiles");
        if (settings.RocksDbNoBlobFiles)
            args.Add("--rocksdb-no-blob-files");

        return args;
    }

    public string BuildDisplayCommand(NodeSettings settings)
    {
        var exe = string.IsNullOrWhiteSpace(settings.NodeExecutable) ? "keryxd.exe" : Quote(settings.NodeExecutable.Trim());
        return string.Join(" ", new[] { exe }.Concat(Build(settings).Select(QuoteIfNeeded)));
    }

    private static string QuoteIfNeeded(string value) => value.Any(char.IsWhiteSpace) ? $"\"{value}\"" : value;
    private static string Quote(string value) => $"\"{value.Replace("\"", "\\\"")}\"";
}
