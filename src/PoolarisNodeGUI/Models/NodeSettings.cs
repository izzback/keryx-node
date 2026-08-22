namespace PoolarisNodeGUI.Models;

public sealed class NodeSettings
{
    public string NodeExecutable { get; init; } = string.Empty;
    public string AppDirectory { get; init; } = string.Empty;
    public bool IsTestnet { get; init; }
    public bool UtxoIndex { get; init; } = true;
    public bool AcceptInboundConnections { get; init; } = true;
    public bool DnsPeerDiscovery { get; init; } = true;
    public bool Upnp { get; init; } = true;
    public bool EnableGrpc { get; init; } = true;
    public bool EnableWrpcJson { get; init; } = true;
    public bool EnableWrpcBorsh { get; init; } = true;
    public int GrpcPort { get; init; } = 22110;
    public int WrpcJsonPort { get; init; } = 24110;
    public int WrpcBorshPort { get; init; } = 23110;
    public int OutboundPeers { get; init; } = 16;
    public int MaxInboundPeers { get; init; } = 64;
    public int AsyncThreads { get; init; } = Math.Max(1, Environment.ProcessorCount);
    public double RamScale { get; init; } = 4.0;
    public int RocksDbCacheSizeMb { get; init; } = 4096;
    public string RocksDbPreset { get; init; } = "default";
    public string LogLevel { get; init; } = "info";
    public bool Archival { get; init; }
    public bool UnsafeRpc { get; init; }
    public bool EnableUnsyncedMining { get; init; }
    public bool DisableLogFiles { get; init; }
    public bool RocksDbNoBlobFiles { get; init; }
}
