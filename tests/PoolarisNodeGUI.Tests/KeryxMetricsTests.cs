using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Tests;

public sealed class KeryxMetricsTests
{
    [Fact]
    public void MetricsOnlySnapshotCountsAsData()
    {
        var metrics = new KeryxMetricsSnapshot(
            123,
            new KeryxProcessMetrics(1, 2, 16, 12.5, 100, 3, 4, 5.5, 6.5),
            null,
            null,
            null,
            null);

        var snapshot = new KeryxRpcSnapshot(
            null,
            null,
            Array.Empty<KeryxPeerInfo>(),
            null,
            metrics);

        Assert.True(snapshot.HasAnyData);
        Assert.NotNull(snapshot.Metrics);
        Assert.Equal(12.5, snapshot.Metrics!.Process!.CpuUsage);
    }

    [Fact]
    public void EmptySnapshotIsNotData()
    {
        var snapshot = new KeryxRpcSnapshot(
            null,
            null,
            Array.Empty<KeryxPeerInfo>());

        Assert.False(snapshot.HasAnyData);
    }
}
