namespace Poolaris.NodeGui.Models;

public sealed class NodeLaunchOptions
{
    public string NodeExecutable { get; set; } = @"H:\keryx-node\keryxd.exe";
    public string DataDirectory { get; set; } = @"E:\datanode\keryx-node";
    public bool Testnet { get; set; }
    public bool UtxoIndex { get; set; } = true;
    public bool AcceptInbound { get; set; } = true;
    public bool EnableGrpc { get; set; } = true;
    public int GrpcPort { get; set; } = 22110;
    public bool EnableWrpcJson { get; set; } = true;
    public int WrpcJsonPort { get; set; } = 24110;
    public bool EnableWrpcBorsh { get; set; }
    public int WrpcBorshPort { get; set; } = 23110;
    public int OutboundPeers { get; set; } = 24;
    public int MaxInboundPeers { get; set; } = 128;
    public int AsyncThreads { get; set; } = 32;
    public double RamScale { get; set; } = 4.0;
    public int RocksDbCacheMiB { get; set; } = 8192;
    public string RocksDbPreset { get; set; } = "default";
    public string LogLevel { get; set; } = "info";
    public bool EnableIbdPerf { get; set; }
}
