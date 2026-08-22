using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.Tests;

public sealed class PerformanceRateCalculatorTests
{
    [Fact]
    public void CpuPercentUsesWholeMachineCapacity()
    {
        var result = PerformanceRateCalculator.CpuPercent(
            TimeSpan.FromSeconds(1),
            TimeSpan.FromSeconds(1),
            logicalProcessorCount: 32);

        Assert.NotNull(result);
        Assert.Equal(3.125, result!.Value, 3);
    }

    [Fact]
    public void CpuPercentRejectsInvalidInterval()
    {
        Assert.Null(PerformanceRateCalculator.CpuPercent(TimeSpan.FromSeconds(1), TimeSpan.Zero, 32));
    }

    [Fact]
    public void ByteRateUsesDeltaNotCumulativeCounter()
    {
        var result = PerformanceRateCalculator.BytesPerSecond(
            currentBytes: 30UL * 1024 * 1024,
            previousBytes: 10UL * 1024 * 1024,
            wallDelta: TimeSpan.FromSeconds(2));

        Assert.NotNull(result);
        Assert.Equal(10d * 1024 * 1024, result!.Value, 0);
    }

    [Fact]
    public void ByteRateRejectsCounterReset()
    {
        Assert.Null(PerformanceRateCalculator.BytesPerSecond(100, 200, TimeSpan.FromSeconds(1)));
    }
}
