namespace PoolarisNodeGUI.Models;

public sealed record KeryxProcessInfo(
    int ProcessId,
    string ExecutablePath,
    DateTime? StartTime,
    bool IsManaged = false)
{
    public string DisplayName => $"{(IsManaged ? "MANAGED" : "EXTERNAL")} NODE  •  PID {ProcessId}";
    public string StartedDisplay => StartTime?.ToString("g") ?? "—";
}
