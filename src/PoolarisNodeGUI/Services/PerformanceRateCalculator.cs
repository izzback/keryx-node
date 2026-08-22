namespace PoolarisNodeGUI.Services;

public static class PerformanceRateCalculator
{
    public static double? CpuPercent(TimeSpan cpuDelta, TimeSpan wallDelta, int logicalProcessorCount)
    {
        if (wallDelta <= TimeSpan.Zero || logicalProcessorCount <= 0 || cpuDelta < TimeSpan.Zero)
            return null;

        var value = cpuDelta.TotalSeconds / (wallDelta.TotalSeconds * logicalProcessorCount) * 100.0;
        return Math.Clamp(value, 0, 100);
    }

    public static double? BytesPerSecond(ulong currentBytes, ulong previousBytes, TimeSpan wallDelta)
    {
        if (wallDelta <= TimeSpan.Zero || currentBytes < previousBytes)
            return null;

        return (currentBytes - previousBytes) / wallDelta.TotalSeconds;
    }
}
