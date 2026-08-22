using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.Tests;

public sealed class KeryxLauncherTests
{
    [Fact]
    public void MainnetAppDirResolvesToNetworkDatadir()
    {
        var root = Path.Combine("E:\\", "datanode", "keryx-node");
        var resolved = KeryxPathResolver.ResolveDatabasePath(root, testnet: false);
        Assert.Equal(Path.Combine(root, "keryx-mainnet", "datadir"), resolved);
    }

    [Fact]
    public void DatabasePathSuggestsRootAppDir()
    {
        var database = Path.Combine("E:\\", "datanode", "keryx-node", "keryx-mainnet", "datadir");
        Assert.Equal(Path.Combine("E:\\", "datanode", "keryx-node"), KeryxPathResolver.SuggestAppDirectory(database));
    }

    [Fact]
    public void BuilderUsesRequireEqualsSyntaxForKeryxOptions()
    {
        var settings = new NodeSettings
        {
            AppDirectory = @"E:\datanode\keryx-node",
            EnableGrpc = true,
            EnableWrpcBorsh = true,
            EnableWrpcJson = true,
            GrpcPort = 22110,
            WrpcBorshPort = 23110,
            WrpcJsonPort = 24110,
            AsyncThreads = 32,
            RamScale = 4,
            RocksDbCacheSizeMb = 8192,
            OutboundPeers = 24,
            MaxInboundPeers = 128,
            UtxoIndex = true
        };

        var args = new KeryxArgumentBuilder().Build(settings);
        Assert.Contains("--appdir=E:\\datanode\\keryx-node", args);
        Assert.Contains("--rpclisten=127.0.0.1:22110", args);
        Assert.Contains("--rpclisten-borsh=127.0.0.1:23110", args);
        Assert.Contains("--rpclisten-json=127.0.0.1:24110", args);
        Assert.Contains("--async-threads=32", args);
        Assert.Contains("--ram-scale=4", args);
        Assert.Contains("--rocksdb-cache-size=8192", args);
        Assert.Contains("--outpeers=24", args);
        Assert.Contains("--maxinpeers=128", args);
        Assert.Contains("--utxoindex", args);
    }

    [Fact]
    public void TestnetUsesDocumentedRpcPorts()
    {
        var settings = new NodeSettings
        {
            IsTestnet = true,
            EnableGrpc = true,
            EnableWrpcBorsh = true,
            EnableWrpcJson = true,
            GrpcPort = 22210,
            WrpcBorshPort = 23210,
            WrpcJsonPort = 24210
        };

        var args = new KeryxArgumentBuilder().Build(settings);
        Assert.Contains("--testnet", args);
        Assert.Contains("--rpclisten=127.0.0.1:22210", args);
        Assert.Contains("--rpclisten-borsh=127.0.0.1:23210", args);
        Assert.Contains("--rpclisten-json=127.0.0.1:24210", args);
    }

    [Fact]
    public void DisablingInboundForcesMaxInPeersToZero()
    {
        var args = new KeryxArgumentBuilder().Build(new NodeSettings
        {
            AcceptInboundConnections = false,
            MaxInboundPeers = 128
        });

        Assert.Contains("--maxinpeers=0", args);
    }
}
