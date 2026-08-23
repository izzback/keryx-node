using System.Net;

namespace PoolarisNodeGUI.Services;

public static class RpcEndpointPolicy
{
    public static bool IsValidPort(int port) => port is >= 1 and <= 65535;

    public static bool IsLoopbackHost(string? host)
    {
        if (string.IsNullOrWhiteSpace(host))
            return false;

        var value = host.Trim();
        if (value.Equals("localhost", StringComparison.OrdinalIgnoreCase))
            return true;

        return IPAddress.TryParse(value, out var address) && IPAddress.IsLoopback(address);
    }
}
