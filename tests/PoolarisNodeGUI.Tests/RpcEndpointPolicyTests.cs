using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.Tests;

public sealed class RpcEndpointPolicyTests
{
    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("localhost")]
    [InlineData("LOCALHOST")]
    [InlineData("::1")]
    public void AcceptsLoopbackHosts(string host)
    {
        Assert.True(RpcEndpointPolicy.IsLoopbackHost(host));
    }

    [Theory]
    [InlineData("192.168.1.10")]
    [InlineData("10.0.0.2")]
    [InlineData("8.8.8.8")]
    [InlineData("example.com")]
    [InlineData("")]
    public void RejectsNonLoopbackHosts(string host)
    {
        Assert.False(RpcEndpointPolicy.IsLoopbackHost(host));
    }

    [Theory]
    [InlineData(1, true)]
    [InlineData(22110, true)]
    [InlineData(65535, true)]
    [InlineData(0, false)]
    [InlineData(65536, false)]
    [InlineData(-1, false)]
    public void ValidatesGrpcPortRange(int port, bool expected)
    {
        Assert.Equal(expected, RpcEndpointPolicy.IsValidPort(port));
    }
}
