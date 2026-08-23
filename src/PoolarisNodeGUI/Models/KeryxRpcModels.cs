namespace PoolarisNodeGUI.Models;

public sealed record KeryxNodeInfo(
    string ServerVersion,
    bool IsSynced,
    bool IsUtxoIndexed,
    ulong MempoolSize);

public sealed record KeryxDagInfo(
    string NetworkName,
    ulong BlockCount,
    ulong HeaderCount,
    ulong VirtualDaaScore,
    double Difficulty,
    IReadOnlyList<string> TipHashes,
    string Sink,
    string PruningPointHash,
    long PastMedianTime);

public sealed record KeryxPeerInfo(
    string Id,
    string Address,
    long LastPingDuration,
    bool IsOutbound,
    long TimeOffset,
    string UserAgent,
    uint AdvertisedProtocolVersion,
    long TimeConnected,
    bool IsIbdPeer)
{
    public string Direction => IsOutbound ? "OUT" : "IN";
    public string IbdSource => IsIbdPeer ? "YES" : "NO";
}

public sealed record KeryxProcessMetrics(
    ulong ResidentSetSizeBytes,
    ulong VirtualMemorySizeBytes,
    uint CoreCount,
    double CpuUsage,
    uint FileDescriptorCount,
    ulong DiskIoReadBytes,
    ulong DiskIoWriteBytes,
    double DiskIoReadBytesPerSecond,
    double DiskIoWriteBytesPerSecond);

public sealed record KeryxConnectionMetrics(
    uint BorshLiveConnections,
    ulong BorshConnectionAttempts,
    ulong BorshHandshakeFailures,
    uint JsonLiveConnections,
    ulong JsonConnectionAttempts,
    ulong JsonHandshakeFailures,
    uint ActivePeers);

public sealed record KeryxBandwidthMetrics(
    ulong BorshBytesTx,
    ulong BorshBytesRx,
    ulong JsonBytesTx,
    ulong JsonBytesRx,
    ulong GrpcP2pBytesTx,
    ulong GrpcP2pBytesRx,
    ulong GrpcUserBytesTx,
    ulong GrpcUserBytesRx);

public sealed record KeryxConsensusMetrics(
    ulong BlocksSubmitted,
    ulong HeaderCounts,
    ulong DependencyCounts,
    ulong BodyCounts,
    ulong TransactionCounts,
    ulong ChainBlockCounts,
    ulong MassCounts,
    ulong BlockCount,
    ulong HeaderCount,
    ulong MempoolSize,
    uint TipHashesCount,
    double Difficulty,
    ulong PastMedianTime,
    uint VirtualParentHashesCount,
    ulong VirtualDaaScore);

public sealed record KeryxStorageMetrics(ulong StorageSizeBytes);

public sealed record KeryxMetricsSnapshot(
    ulong ServerTime,
    KeryxProcessMetrics? Process,
    KeryxConnectionMetrics? Connections,
    KeryxBandwidthMetrics? Bandwidth,
    KeryxConsensusMetrics? Consensus,
    KeryxStorageMetrics? Storage);

public sealed record KeryxRpcSnapshot(
    KeryxNodeInfo? Info,
    KeryxDagInfo? Dag,
    IReadOnlyList<KeryxPeerInfo> Peers,
    string? Error = null,
    KeryxMetricsSnapshot? Metrics = null)
{
    public bool HasAnyData => Info is not null || Dag is not null || Peers.Count > 0 || Metrics is not null;
}
