using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;
using PoolarisNodeGUI.ViewModels;

namespace PoolarisNodeGUI.Tests;

public sealed class RuntimeNodeSessionTests
{
    [Fact]
    public void ManagedNodeKeepsExactConfiguredGrpcPortButStartsUnverified()
    {
        var session = new RuntimeNodeSession();
        var node = new KeryxProcessInfo(4242, @"C:\Keryx\keryxd.exe", DateTime.Now, true);

        session.AttachManaged(node, rpcPort: 24242, rpcEnabled: true);

        Assert.Equal(24242, session.RpcPort);
        Assert.True(session.RpcEnabled);
        Assert.False(session.RpcEndpointVerified);
        Assert.Contains("24242", session.RpcEndpointDisplay);
        Assert.Contains("unverified", session.RpcEndpointDisplay);
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

    [Fact]
    public void RpcShutdownIsUnavailableWithoutLiveRpcConnection()
    {
        var session = new RuntimeNodeSession();
        var node = new KeryxProcessInfo(4242, @"C:\Keryx\keryxd.exe", DateTime.Now, true);
        session.AttachManaged(node, rpcPort: 22110, rpcEnabled: true);
        session.SetRpcEndpoint("127.0.0.1", 22110, verified: true);

        var control = new ProcessControlViewModel(session);

        Assert.False(session.RpcConnected);
        Assert.False(control.CanRpcShutdown);
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
