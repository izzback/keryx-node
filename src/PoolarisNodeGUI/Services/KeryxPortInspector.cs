using System.Net.NetworkInformation;

namespace PoolarisNodeGUI.Services;

public static class KeryxPortInspector
{
    public static bool IsTcpPortInUse(int port)
    {
        if (port is < 1 or > 65535)
            return true;

        return IPGlobalProperties.GetIPGlobalProperties()
            .GetActiveTcpListeners()
            .Any(endpoint => endpoint.Port == port);
    }

    public static IReadOnlyList<(string Name, int Port)> FindRpcConflicts(
        bool enableGrpc, int grpcPort,
        bool enableWrpcBorsh, int borshPort,
        bool enableWrpcJson, int jsonPort)
    {
        var conflicts = new List<(string Name, int Port)>();
        if (enableGrpc && IsTcpPortInUse(grpcPort)) conflicts.Add(("gRPC", grpcPort));
        if (enableWrpcBorsh && IsTcpPortInUse(borshPort)) conflicts.Add(("wRPC Borsh", borshPort));
        if (enableWrpcJson && IsTcpPortInUse(jsonPort)) conflicts.Add(("wRPC JSON", jsonPort));
        return conflicts;
    }
}
