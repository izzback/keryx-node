using System.Diagnostics;

namespace Poolaris.NodeGui.Services;

public sealed record NodeProcessSnapshot(
    bool Running,
    int ProcessId,
    double CpuPercent,
    long WorkingSetBytes,
    int ThreadCount,
    TimeSpan Uptime,
    string ExecutablePath);

public sealed class NodeMonitorService
{
    private readonly NodeProcessService _processService;
    private TimeSpan _lastCpu;
    private DateTime _lastSampleUtc = DateTime.UtcNow;
    private int _lastPid;

    public NodeMonitorService(NodeProcessService processService)
    {
        _processService = processService;
    }

    public NodeProcessSnapshot Sample()
    {
        var process = _processService.FindRunningNode();
        if (process is null || process.HasExited)
        {
            _lastPid = 0;
            _lastCpu = TimeSpan.Zero;
            _lastSampleUtc = DateTime.UtcNow;
            return new(false, 0, 0, 0, 0, TimeSpan.Zero, string.Empty);
        }

        process.Refresh();
        var now = DateTime.UtcNow;
        var cpu = process.TotalProcessorTime;
        var elapsed = now - _lastSampleUtc;
        double cpuPercent = 0;

        if (_lastPid == process.Id && elapsed.TotalMilliseconds > 0)
        {
            var cpuDelta = cpu - _lastCpu;
            cpuPercent = cpuDelta.TotalMilliseconds /
                         (elapsed.TotalMilliseconds * Environment.ProcessorCount) * 100.0;
        }

        _lastPid = process.Id;
        _lastCpu = cpu;
        _lastSampleUtc = now;

        string path;
        try { path = process.MainModule?.FileName ?? string.Empty; }
        catch { path = string.Empty; }

        TimeSpan uptime;
        try { uptime = DateTime.Now - process.StartTime; }
        catch { uptime = TimeSpan.Zero; }

        return new(
            true,
            process.Id,
            Math.Clamp(cpuPercent, 0, 100),
            process.WorkingSet64,
            process.Threads.Count,
            uptime,
            path);
    }
}
