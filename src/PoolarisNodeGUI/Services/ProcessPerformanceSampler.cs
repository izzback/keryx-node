using System.Diagnostics;
using System.Runtime.InteropServices;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public sealed class ProcessPerformanceSampler
{
    private int? _lastPid;
    private DateTime _lastTimestamp;
    private TimeSpan _lastCpuTime;
    private ulong? _lastReadBytes;
    private ulong? _lastWriteBytes;

    public ProcessPerformanceSnapshot? Sample(int processId, DateTime? now = null)
    {
        var timestamp = now ?? DateTime.UtcNow;

        try
        {
            using var process = Process.GetProcessById(processId);
            if (process.HasExited) return null;

            process.Refresh();
            var cpuTime = process.TotalProcessorTime;
            var privateBytes = process.PrivateMemorySize64;
            var workingSetBytes = process.WorkingSet64;
            var threadCount = process.Threads.Count;
            var handleCount = process.HandleCount;
            var io = TryGetIoCounters(process.Handle);

            double? cpuPercent = null;
            double? readPerSecond = null;
            double? writePerSecond = null;

            if (_lastPid == processId && _lastTimestamp != default)
            {
                var wallDelta = timestamp - _lastTimestamp;
                cpuPercent = PerformanceRateCalculator.CpuPercent(
                    cpuTime - _lastCpuTime,
                    wallDelta,
                    Math.Max(1, Environment.ProcessorCount));

                if (io.HasValue && _lastReadBytes.HasValue)
                    readPerSecond = PerformanceRateCalculator.BytesPerSecond(io.Value.ReadTransferCount, _lastReadBytes.Value, wallDelta);
                if (io.HasValue && _lastWriteBytes.HasValue)
                    writePerSecond = PerformanceRateCalculator.BytesPerSecond(io.Value.WriteTransferCount, _lastWriteBytes.Value, wallDelta);
            }

            _lastPid = processId;
            _lastTimestamp = timestamp;
            _lastCpuTime = cpuTime;
            _lastReadBytes = io?.ReadTransferCount;
            _lastWriteBytes = io?.WriteTransferCount;

            return new ProcessPerformanceSnapshot(
                processId,
                timestamp,
                cpuPercent,
                privateBytes,
                workingSetBytes,
                threadCount,
                handleCount,
                readPerSecond,
                writePerSecond);
        }
        catch
        {
            Reset();
            return null;
        }
    }

    public void Reset()
    {
        _lastPid = null;
        _lastTimestamp = default;
        _lastCpuTime = default;
        _lastReadBytes = null;
        _lastWriteBytes = null;
    }

    private static IoCounters? TryGetIoCounters(IntPtr processHandle)
    {
        if (!OperatingSystem.IsWindows()) return null;
        return GetProcessIoCounters(processHandle, out var counters) ? counters : null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessIoCounters(IntPtr hProcess, out IoCounters lpIoCounters);
}
