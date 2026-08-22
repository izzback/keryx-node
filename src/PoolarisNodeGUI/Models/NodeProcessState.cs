namespace PoolarisNodeGUI.Models;

public enum NodeProcessState
{
    Stopped,
    Starting,
    Running,
    Failed
}

public sealed record NodeStartResult(
    bool Success,
    NodeProcessState State,
    int? ProcessId = null,
    int? ExitCode = null,
    string? Error = null,
    string? StandardOutput = null,
    string? StandardError = null);
