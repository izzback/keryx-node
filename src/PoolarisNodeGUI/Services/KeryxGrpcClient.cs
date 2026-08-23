using Grpc.Net.Client;
using PoolarisNodeGUI.Models;
using Protowire;

namespace PoolarisNodeGUI.Services;

public sealed class KeryxGrpcClient
{
    private long _requestId;

    public async Task<KeryxRpcSnapshot> GetSnapshotAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        KeryxNodeInfo? info = null;
        KeryxDagInfo? dag = null;
        IReadOnlyList<KeryxPeerInfo> peers = Array.Empty<KeryxPeerInfo>();
        var errors = new List<string>(3);

        try
        {
            info = await GetInfoAsync(host, port, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            errors.Add($"GetInfo: {ex.Message}");
        }

        try
        {
            dag = await GetBlockDagInfoAsync(host, port, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            errors.Add($"GetBlockDagInfo: {ex.Message}");
        }

        try
        {
            peers = await GetConnectedPeerInfoAsync(host, port, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            errors.Add($"GetConnectedPeerInfo: {ex.Message}");
        }

        cancellationToken.ThrowIfCancellationRequested();
        return new KeryxRpcSnapshot(
            info,
            dag,
            peers,
            errors.Count == 0 ? null : string.Join(" | ", errors));
    }

    public async Task<KeryxNodeInfo> GetInfoAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        var response = await SendAsync(host, port, new KaspadRequest
        {
            Id = NextId(),
            GetInfoRequest = new GetInfoRequestMessage()
        }, cancellationToken).ConfigureAwait(false);

        var payload = response.GetInfoResponse ?? throw new InvalidOperationException("Keryx returned an unexpected response to GetInfo.");
        ThrowIfRpcError(payload.Error);
        return new KeryxNodeInfo(
            payload.ServerVersion,
            payload.IsSynced,
            payload.IsUtxoIndexed,
            payload.MempoolSize);
    }

    public async Task<KeryxDagInfo> GetBlockDagInfoAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        var response = await SendAsync(host, port, new KaspadRequest
        {
            Id = NextId(),
            GetBlockDagInfoRequest = new GetBlockDagInfoRequestMessage()
        }, cancellationToken).ConfigureAwait(false);

        var payload = response.GetBlockDagInfoResponse ?? throw new InvalidOperationException("Keryx returned an unexpected response to GetBlockDagInfo.");
        ThrowIfRpcError(payload.Error);
        return new KeryxDagInfo(
            payload.NetworkName,
            payload.BlockCount,
            payload.HeaderCount,
            payload.VirtualDaaScore,
            payload.Difficulty,
            payload.TipHashes.ToArray(),
            payload.Sink,
            payload.PruningPointHash,
            payload.PastMedianTime);
    }

    public async Task<IReadOnlyList<KeryxPeerInfo>> GetConnectedPeerInfoAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        var response = await SendAsync(host, port, new KaspadRequest
        {
            Id = NextId(),
            GetConnectedPeerInfoRequest = new GetConnectedPeerInfoRequestMessage()
        }, cancellationToken).ConfigureAwait(false);

        var payload = response.GetConnectedPeerInfoResponse ?? throw new InvalidOperationException("Keryx returned an unexpected response to GetConnectedPeerInfo.");
        ThrowIfRpcError(payload.Error);
        return payload.Infos.Select(peer => new KeryxPeerInfo(
            peer.Id,
            peer.Address,
            peer.LastPingDuration,
            peer.IsOutbound,
            peer.TimeOffset,
            peer.UserAgent,
            peer.AdvertisedProtocolVersion,
            peer.TimeConnected,
            peer.IsIbdPeer)).ToArray();
    }

    public async Task ShutdownAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        if (!RpcEndpointPolicy.IsLoopbackHost(host))
            throw new InvalidOperationException("Poolaris refuse d'envoyer Shutdown à un endpoint RPC non-loopback.");
        if (!RpcEndpointPolicy.IsValidPort(port))
            throw new ArgumentOutOfRangeException(nameof(port), "Le port RPC doit être compris entre 1 et 65535.");

        var response = await SendAsync(host, port, new KaspadRequest
        {
            Id = NextId(),
            ShutdownRequest = new ShutdownRequestMessage()
        }, cancellationToken).ConfigureAwait(false);

        var payload = response.ShutdownResponse ?? throw new InvalidOperationException("Keryx returned an unexpected response to Shutdown.");
        ThrowIfRpcError(payload.Error);
    }

    private async Task<KaspadResponse> SendAsync(string host, int port, KaspadRequest request, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(4));

        using var channel = GrpcChannel.ForAddress($"http://{host}:{port}");
        var client = new RPC.RPCClient(channel);
        using var call = client.MessageStream(cancellationToken: timeout.Token);

        await call.RequestStream.WriteAsync(request).ConfigureAwait(false);
        await call.RequestStream.CompleteAsync().ConfigureAwait(false);

        while (await call.ResponseStream.MoveNext(timeout.Token).ConfigureAwait(false))
        {
            var response = call.ResponseStream.Current;
            if (response.Id == request.Id)
                return response;
        }

        throw new InvalidOperationException("Keryx closed the gRPC stream before returning the requested response.");
    }

    private ulong NextId() => unchecked((ulong)Interlocked.Increment(ref _requestId));

    private static void ThrowIfRpcError(RPCError? error)
    {
        if (error is not null && !string.IsNullOrWhiteSpace(error.Message))
            throw new InvalidOperationException(error.Message);
    }
}
