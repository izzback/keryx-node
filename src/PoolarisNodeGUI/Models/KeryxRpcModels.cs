namespace PoolarisNodeGUI.Models;

public sealed record KeryxNodeInfo(
    string ServerVersion,
    bool IsSynced,
    bool IsUtxoIndexed);

public sealed record KeryxDagInfo(
    string NetworkName,
    ulong BlockCount,
    ulong HeaderCount,
    ulong VirtualDaaScore,
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

public sealed record KeryxRpcSnapshot(
    KeryxNodeInfo? Info,
    KeryxDagInfo? Dag,
    IReadOnlyList<KeryxPeerInfo> Peers,
    string? Error = null);
