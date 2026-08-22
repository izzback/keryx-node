namespace PoolarisNodeGUI.Models;

public sealed record ProcessPerformanceSnapshot(
    int ProcessId,
    DateTime Timestamp,
    double? CpuPercent,
    long PrivateMemoryBytes,
    long WorkingSetBytes,
    int ThreadCount,
    int HandleCount,
    double? DiskReadBytesPerSecond,
    double? DiskWriteBytesPerSecond);
