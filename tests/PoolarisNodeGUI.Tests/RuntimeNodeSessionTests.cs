using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.Tests;

public sealed class RuntimeNodeSessionTests
{
    [Fact]
    public void ManagedNodeKeepsExactConfiguredGrpcPort()
    {
        var session = new RuntimeNodeSession();
        var node = new KeryxProcessInfo(4242, @"C:\Keryx\keryxd.exe", DateTime.Now, true);

        session.AttachManaged(node, rpcPort: 24242, rpcEnabled: true);

        Assert.Equal(24242, session.RpcPort);
        Assert.True(session.RpcEnabled);
        Assert.True(session.RpcEndpointVerified);
        Assert.Contains("24242", session.RpcEndpointDisplay);
    }

    [Fact]
    public void DisabledGrpcDoesNotPretendEndpointIsVerified()
    {
        var session = new RuntimeNodeSession();
        var node = new KeryxProcessInfo(4242, @"C:\Keryx\keryxd.exe", DateTime.Now, true);

        session.AttachManaged(node, rpcPort: 22110, rpcEnabled: false);

        Assert.False(session.RpcEnabled);
        Assert.False(session.RpcEndpointVerified);
        Assert.Equal("Disabled", session.RpcEndpointDisplay);
        Assert.Equal("Disabled", session.RpcStatus);
    }

    [Theory]
    [InlineData(true, "YES")]
    [InlineData(false, "NO")]
    public void IbdSourceRemainsBoolean(bool isIbdPeer, string expected)
    {
        var peer = new KeryxPeerInfo(
            "peer-id",
            "127.0.0.1:22111",
            123,
            true,
            0,
            "keryx-test",
            1,
            0,
            isIbdPeer);

        Assert.Equal(expected, peer.IbdSource);
    }
}
