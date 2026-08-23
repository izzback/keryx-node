using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Threading;
using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed record PerformanceHistoryRow(
    string Time,
    string WindowsCpu,
    string WorkingSet,
    string DiskRead,
    string DiskWrite,
    string KeryxCpu,
    string ActivePeers);

public sealed class PerformancePageViewModel : ViewModelBase, IDisposable
{
    private const int MaxHistorySamples = 120;
    private readonly RuntimeNodeSession _session;
    private readonly ProcessPerformanceSampler _sampler = new();
    private readonly DispatcherTimer _timer;
    private ProcessPerformanceSnapshot? _local;
    private bool _disposed;

    public PerformancePageViewModel(RuntimeNodeSession session)
    {
        _session = session;
        _session.PropertyChanged += SessionOnPropertyChanged;
        _timer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _timer.Tick += TimerOnTick;
        RefreshMonitoringState();
    }

    public ObservableCollection<PerformanceHistoryRow> History { get; } = new();

    private KeryxMetricsSnapshot? Metrics => _session.RpcSnapshot?.Metrics;
    private KeryxProcessMetrics? RpcProcess => Metrics?.Process;
    private KeryxConnectionMetrics? Connections => Metrics?.Connections;
    private KeryxBandwidthMetrics? Bandwidth => Metrics?.Bandwidth;
    private KeryxConsensusMetrics? Consensus => Metrics?.Consensus;
    private KeryxStorageMetrics? Storage => Metrics?.Storage;

    public string NodeLabel => _session.AttachedNodeLabel;
    public string NodePid => _session.AttachedPid;
    public string NodeMode => _session.AttachedNode is null
        ? "—"
        : _session.AttachedNode.IsManaged ? "MANAGED NODE" : "EXTERNAL NODE";
    public string RpcEndpoint => _session.RpcEndpointDisplay;
    public string RpcStatus => _session.RpcStatus;
    public string MetricsStatus => Metrics is null ? "Unavailable" : "Available";
    public string LastUpdated => _session.RpcLastUpdatedDisplay;

    // Windows process source — exact attached PID.
    public string WindowsCpu => _local?.CpuPercent is double cpu ? $"{cpu:0.0}%" : "—";
    public string WindowsPrivateMemory => _local is null ? "—" : FormatBytes((ulong)Math.Max(0, _local.PrivateMemoryBytes));
    public string WindowsWorkingSet => _local is null ? "—" : FormatBytes((ulong)Math.Max(0, _local.WorkingSetBytes));
    public string WindowsThreads => _local?.ThreadCount.ToString("N0") ?? "—";
    public string WindowsHandles => _local?.HandleCount.ToString("N0") ?? "—";
    public string WindowsDiskRead => _local?.DiskReadBytesPerSecond is double value ? FormatRate(value) : "—";
    public string WindowsDiskWrite => _local?.DiskWriteBytesPerSecond is double value ? FormatRate(value) : "—";

    // Keryx GetMetrics source. The names intentionally mirror the RPC fields.
    public string KeryxCpu => RpcProcess is null ? "—" : $"{RpcProcess.CpuUsage:0.0}%";
    public string KeryxResidentSet => RpcProcess is null ? "—" : FormatBytes(RpcProcess.ResidentSetSizeBytes);
    public string KeryxVirtualMemory => RpcProcess is null ? "—" : FormatBytes(RpcProcess.VirtualMemorySizeBytes);
    public string KeryxCoreCount => RpcProcess?.CoreCount.ToString("N0") ?? "—";
    public string KeryxFileDescriptors => RpcProcess?.FileDescriptorCount.ToString("N0") ?? "—";
    public string KeryxDiskRead => RpcProcess is null ? "—" : FormatRate(RpcProcess.DiskIoReadBytesPerSecond);
    public string KeryxDiskWrite => RpcProcess is null ? "—" : FormatRate(RpcProcess.DiskIoWriteBytesPerSecond);
    public string KeryxDiskReadTotal => RpcProcess is null ? "—" : FormatBytes(RpcProcess.DiskIoReadBytes);
    public string KeryxDiskWriteTotal => RpcProcess is null ? "—" : FormatBytes(RpcProcess.DiskIoWriteBytes);

    public string StorageSize => Storage is null ? "—" : FormatBytes(Storage.StorageSizeBytes);
    public string ActivePeers => Connections?.ActivePeers.ToString("N0") ?? "—";
    public string BorshConnections => Connections?.BorshLiveConnections.ToString("N0") ?? "—";
    public string JsonConnections => Connections?.JsonLiveConnections.ToString("N0") ?? "—";
    public string BorshHandshakeFailures => Connections?.BorshHandshakeFailures.ToString("N0") ?? "—";
    public string JsonHandshakeFailures => Connections?.JsonHandshakeFailures.ToString("N0") ?? "—";

    public string NetworkTxTotal => Bandwidth is null ? "—" : FormatBytes(SaturatingSum(
        Bandwidth.BorshBytesTx,
        Bandwidth.JsonBytesTx,
        Bandwidth.GrpcP2pBytesTx,
        Bandwidth.GrpcUserBytesTx));
    public string NetworkRxTotal => Bandwidth is null ? "—" : FormatBytes(SaturatingSum(
        Bandwidth.BorshBytesRx,
        Bandwidth.JsonBytesRx,
        Bandwidth.GrpcP2pBytesRx,
        Bandwidth.GrpcUserBytesRx));

    public string BlockCount => Consensus?.BlockCount.ToString("N0") ?? "—";
    public string HeaderCount => Consensus?.HeaderCount.ToString("N0") ?? "—";
    public string VirtualDaaScore => Consensus?.VirtualDaaScore.ToString("N0") ?? "—";
    public string MempoolSize => Consensus?.MempoolSize.ToString("N0") ?? "—";
    public string Difficulty => Consensus is null ? "—" : Consensus.Difficulty.ToString("N2");
    public string BlocksSubmitted => Consensus?.BlocksSubmitted.ToString("N0") ?? "—";
    public string BodyCountEvents => Consensus?.BodyCounts.ToString("N0") ?? "—";
    public string HeaderCountEvents => Consensus?.HeaderCounts.ToString("N0") ?? "—";
    public string TransactionCountEvents => Consensus?.TransactionCounts.ToString("N0") ?? "—";

    private void TimerOnTick(object? sender, EventArgs e)
    {
        var attached = _session.AttachedNode;
        if (attached is null)
        {
            StopMonitoring();
            return;
        }

        var sample = _sampler.Sample(attached.ProcessId);
        if (sample is null)
        {
            _session.Detect();
            StopMonitoring();
            return;
        }

        _local = sample;
        AppendHistory();
        RaiseAll();
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.IsAttached))
        {
            RefreshMonitoringState();
            RaiseAll();
            return;
        }

        if (e.PropertyName is nameof(RuntimeNodeSession.RpcSnapshot)
            or nameof(RuntimeNodeSession.RpcStatus)
            or nameof(RuntimeNodeSession.RpcLastUpdated)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcEndpointVerified))
        {
            RaiseAll();
        }
    }

    private void RefreshMonitoringState()
    {
        _sampler.Reset();
        _local = null;
        History.Clear();

        if (_session.AttachedNode is null)
        {
            _timer.Stop();
            return;
        }

        _local = _sampler.Sample(_session.AttachedNode.ProcessId);
        if (!_timer.IsEnabled)
            _timer.Start();
    }

    private void StopMonitoring()
    {
        _timer.Stop();
        _sampler.Reset();
        _local = null;
        RaiseAll();
    }

    private void AppendHistory()
    {
        History.Insert(0, new PerformanceHistoryRow(
            DateTime.Now.ToString("HH:mm:ss"),
            WindowsCpu,
            WindowsWorkingSet,
            WindowsDiskRead,
            WindowsDiskWrite,
            KeryxCpu,
            ActivePeers));

        while (History.Count > MaxHistorySamples)
            History.RemoveAt(History.Count - 1);
    }

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(NodeLabel));
        OnPropertyChanged(nameof(NodePid));
        OnPropertyChanged(nameof(NodeMode));
        OnPropertyChanged(nameof(RpcEndpoint));
        OnPropertyChanged(nameof(RpcStatus));
        OnPropertyChanged(nameof(MetricsStatus));
        OnPropertyChanged(nameof(LastUpdated));
        OnPropertyChanged(nameof(WindowsCpu));
        OnPropertyChanged(nameof(WindowsPrivateMemory));
        OnPropertyChanged(nameof(WindowsWorkingSet));
        OnPropertyChanged(nameof(WindowsThreads));
        OnPropertyChanged(nameof(WindowsHandles));
        OnPropertyChanged(nameof(WindowsDiskRead));
        OnPropertyChanged(nameof(WindowsDiskWrite));
        OnPropertyChanged(nameof(KeryxCpu));
        OnPropertyChanged(nameof(KeryxResidentSet));
        OnPropertyChanged(nameof(KeryxVirtualMemory));
        OnPropertyChanged(nameof(KeryxCoreCount));
        OnPropertyChanged(nameof(KeryxFileDescriptors));
        OnPropertyChanged(nameof(KeryxDiskRead));
        OnPropertyChanged(nameof(KeryxDiskWrite));
        OnPropertyChanged(nameof(KeryxDiskReadTotal));
        OnPropertyChanged(nameof(KeryxDiskWriteTotal));
        OnPropertyChanged(nameof(StorageSize));
        OnPropertyChanged(nameof(ActivePeers));
        OnPropertyChanged(nameof(BorshConnections));
        OnPropertyChanged(nameof(JsonConnections));
        OnPropertyChanged(nameof(BorshHandshakeFailures));
        OnPropertyChanged(nameof(JsonHandshakeFailures));
        OnPropertyChanged(nameof(NetworkTxTotal));
        OnPropertyChanged(nameof(NetworkRxTotal));
        OnPropertyChanged(nameof(BlockCount));
        OnPropertyChanged(nameof(HeaderCount));
        OnPropertyChanged(nameof(VirtualDaaScore));
        OnPropertyChanged(nameof(MempoolSize));
        OnPropertyChanged(nameof(Difficulty));
        OnPropertyChanged(nameof(BlocksSubmitted));
        OnPropertyChanged(nameof(BodyCountEvents));
        OnPropertyChanged(nameof(HeaderCountEvents));
        OnPropertyChanged(nameof(TransactionCountEvents));
    }

    private static string FormatBytes(ulong bytes)
    {
        const double kib = 1024d;
        const double mib = kib * 1024d;
        const double gib = mib * 1024d;
        const double tib = gib * 1024d;

        if (bytes >= tib) return $"{bytes / tib:0.00} TB";
        if (bytes >= gib) return $"{bytes / gib:0.00} GB";
        if (bytes >= mib) return $"{bytes / mib:0.0} MB";
        if (bytes >= kib) return $"{bytes / kib:0.0} KB";
        return $"{bytes} B";
    }

    private static string FormatRate(double bytesPerSecond)
    {
        if (double.IsNaN(bytesPerSecond) || double.IsInfinity(bytesPerSecond) || bytesPerSecond < 0)
            return "—";
        return $"{bytesPerSecond / (1024d * 1024d):0.0} MB/s";
    }

    private static ulong SaturatingSum(params ulong[] values)
    {
        ulong total = 0;
        foreach (var value in values)
        {
            if (ulong.MaxValue - total < value)
                return ulong.MaxValue;
            total += value;
        }
        return total;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _timer.Stop();
        _timer.Tick -= TimerOnTick;
        _session.PropertyChanged -= SessionOnPropertyChanged;
    }
}
