using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Threading;
using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class DashboardViewModel : ViewModelBase, IDisposable
{
    private readonly RuntimeNodeSession _session;
    private readonly ProcessPerformanceSampler _performanceSampler = new();
    private readonly DispatcherTimer _timer;
    private ProcessPerformanceSnapshot? _performance;
    private bool _disposed;

    public DashboardViewModel() : this(new RuntimeNodeSession()) { }

    public DashboardViewModel(RuntimeNodeSession session)
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

    public string NodeLabel => _session.AttachedNodeLabel;
    public string NodeExecutable => _session.AttachedNode?.ExecutablePath ?? "—";
    public string NodePid => _session.AttachedPid;
    public string NodeStarted => _session.AttachedNode?.StartedDisplay ?? "—";
    public string NodeMode => _session.AttachedNode is null
        ? "—"
        : _session.AttachedNode.IsManaged ? "MANAGED NODE" : "EXTERNAL NODE";

    public string NodeUptime
    {
        get
        {
            var started = _session.AttachedNode?.StartTime;
            if (!started.HasValue) return "—";
            var uptime = DateTime.Now - started.Value;
            if (uptime < TimeSpan.Zero) return "—";
            return uptime.TotalDays >= 1
                ? $"{(int)uptime.TotalDays}d {uptime:hh\:mm\:ss}"
                : uptime.ToString("hh\:mm\:ss");
        }
    }

    public string CpuUsage => _performance?.CpuPercent is double cpu ? $"{cpu:0.0}%" : "—";
    public string PrivateMemory => _performance is null ? "—" : FormatBytes(_performance.PrivateMemoryBytes);
    public string WorkingSet => _performance is null ? "—" : FormatBytes(_performance.WorkingSetBytes);
    public string Threads => _performance?.ThreadCount.ToString() ?? "—";
    public string Handles => _performance?.HandleCount.ToString() ?? "—";

    public string DiskIo
    {
        get
        {
            if (_performance is null || (_performance.DiskReadBytesPerSecond is null && _performance.DiskWriteBytesPerSecond is null))
                return "—";

            var read = _performance.DiskReadBytesPerSecond.HasValue ? FormatRate(_performance.DiskReadBytesPerSecond.Value) : "—";
            var write = _performance.DiskWriteBytesPerSecond.HasValue ? FormatRate(_performance.DiskWriteBytesPerSecond.Value) : "—";
            return $"R {read} / W {write}";
        }
    }

    private KeryxRpcSnapshot? Rpc => _session.RpcSnapshot;
    public string RpcStatus => _session.RpcStatus;
    public string RpcEndpoint => _session.RpcEndpointDisplay;
    public string RpcLastUpdated => _session.RpcLastUpdatedDisplay;
    public string RpcError => _session.RpcError;
    public string NodeVersion => Rpc?.Info?.ServerVersion ?? "—";
    public string SyncState => Rpc?.Info is null ? "UNKNOWN" : Rpc.Info.IsSynced ? "SYNCED" : "IBD";
    public string NetworkName => Rpc?.Dag?.NetworkName ?? "—";
    public string BlockCount => Rpc?.Dag is { } dag ? dag.BlockCount.ToString("N0") : "—";
    public string HeaderCount => Rpc?.Dag is { } dag ? dag.HeaderCount.ToString("N0") : "—";
    public string VirtualDaaScore => Rpc?.Dag is { } dag ? dag.VirtualDaaScore.ToString("N0") : "—";
    public string Difficulty => Rpc?.Dag is { } dag ? dag.Difficulty.ToString("N2") : "—";
    public string MempoolSize => Rpc?.Info is { } info ? info.MempoolSize.ToString("N0") : "—";
    public string UtxoIndex => Rpc?.Info is null ? "—" : Rpc.Info.IsUtxoIndexed ? "Enabled" : "Disabled";
    public string PeerCount => Rpc?.Peers is { } peers ? peers.Count.ToString() : "—";

    public string InboundOutbound
    {
        get
        {
            if (Rpc?.Peers is not { } peers) return "— / —";
            var outbound = peers.Count(x => x.IsOutbound);
            var inbound = peers.Count - outbound;
            return $"{inbound} / {outbound}";
        }
    }

    public string IbdSource => Rpc?.Peers.FirstOrDefault(x => x.IsIbdPeer)?.Address ?? "—";

    private void TimerOnTick(object? sender, EventArgs e)
    {
        var attached = _session.AttachedNode;
        if (attached is null)
        {
            StopMonitoring();
            return;
        }

        var sample = _performanceSampler.Sample(attached.ProcessId);
        if (sample is null)
        {
            _session.Detect();
            StopMonitoring();
            return;
        }

        _performance = sample;
        RaiseRuntimeProperties();
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.AttachedNodeLabel)
            or nameof(RuntimeNodeSession.AttachedPid)
            or nameof(RuntimeNodeSession.IsAttached))
        {
            RefreshMonitoringState();
            RaiseRuntimeProperties();
        }

        if (e.PropertyName is nameof(RuntimeNodeSession.RpcSnapshot)
            or nameof(RuntimeNodeSession.RpcStatus)
            or nameof(RuntimeNodeSession.RpcError)
            or nameof(RuntimeNodeSession.RpcLastUpdated)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcEnabled)
            or nameof(RuntimeNodeSession.RpcEndpointVerified))
        {
            RaiseRpcProperties();
        }
    }

    private void RefreshMonitoringState()
    {
        _performance = null;
        _performanceSampler.Reset();
        if (_session.AttachedNode is null)
        {
            _timer.Stop();
            return;
        }

        _performance = _performanceSampler.Sample(_session.AttachedNode.ProcessId);
        if (!_timer.IsEnabled)
            _timer.Start();
    }

    private void StopMonitoring()
    {
        _timer.Stop();
        _performanceSampler.Reset();
        _performance = null;
        RaiseRuntimeProperties();
    }

    private void RaiseRuntimeProperties()
    {
        OnPropertyChanged(nameof(NodeLabel));
        OnPropertyChanged(nameof(NodeExecutable));
        OnPropertyChanged(nameof(NodePid));
        OnPropertyChanged(nameof(NodeStarted));
        OnPropertyChanged(nameof(NodeMode));
        OnPropertyChanged(nameof(NodeUptime));
        OnPropertyChanged(nameof(CpuUsage));
        OnPropertyChanged(nameof(PrivateMemory));
        OnPropertyChanged(nameof(WorkingSet));
        OnPropertyChanged(nameof(Threads));
        OnPropertyChanged(nameof(Handles));
        OnPropertyChanged(nameof(DiskIo));
    }

    private void RaiseRpcProperties()
    {
        OnPropertyChanged(nameof(RpcStatus));
        OnPropertyChanged(nameof(RpcEndpoint));
        OnPropertyChanged(nameof(RpcLastUpdated));
        OnPropertyChanged(nameof(RpcError));
        OnPropertyChanged(nameof(NodeVersion));
        OnPropertyChanged(nameof(SyncState));
        OnPropertyChanged(nameof(NetworkName));
        OnPropertyChanged(nameof(BlockCount));
        OnPropertyChanged(nameof(HeaderCount));
        OnPropertyChanged(nameof(VirtualDaaScore));
        OnPropertyChanged(nameof(Difficulty));
        OnPropertyChanged(nameof(MempoolSize));
        OnPropertyChanged(nameof(UtxoIndex));
        OnPropertyChanged(nameof(PeerCount));
        OnPropertyChanged(nameof(InboundOutbound));
        OnPropertyChanged(nameof(IbdSource));
    }

    private static string FormatBytes(long bytes)
    {
        const double gib = 1024d * 1024d * 1024d;
        const double mib = 1024d * 1024d;
        return bytes >= gib ? $"{bytes / gib:0.00} GB" : $"{bytes / mib:0.0} MB";
    }

    private static string FormatRate(double bytesPerSecond)
        => $"{bytesPerSecond / (1024d * 1024d):0.0} MB/s";

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _timer.Stop();
        _timer.Tick -= TimerOnTick;
        _session.PropertyChanged -= SessionOnPropertyChanged;
    }
}

public sealed record KeryxPeerRow(
    string Address,
    string Direction,
    string PingRaw,
    string IbdSource,
    string Protocol,
    string UserAgent);

public sealed class PeersViewModel : ViewModelBase, IDisposable
{
    private readonly RuntimeNodeSession _session;
    private bool _disposed;

    public PeersViewModel() : this(new RuntimeNodeSession()) { }

    public PeersViewModel(RuntimeNodeSession session)
    {
        _session = session;
        _session.PropertyChanged += SessionOnPropertyChanged;
        RefreshPeers();
    }

    public ObservableCollection<KeryxPeerRow> Peers { get; } = new();
    public string RpcStatus => _session.RpcStatus;
    public string RpcEndpoint => _session.RpcEndpointDisplay;
    public string LastUpdated => _session.RpcLastUpdatedDisplay;
    public string LastError => _session.RpcError;
    public string TotalPeers => _session.RpcSnapshot?.Peers.Count.ToString() ?? "—";
    public string InboundPeers => _session.RpcSnapshot?.Peers.Count(x => !x.IsOutbound).ToString() ?? "—";
    public string OutboundPeers => _session.RpcSnapshot?.Peers.Count(x => x.IsOutbound).ToString() ?? "—";
    public string IbdPeer => _session.RpcSnapshot?.Peers.FirstOrDefault(x => x.IsIbdPeer)?.Address ?? "—";
    public bool HasPeers => Peers.Count > 0;

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.RpcSnapshot)
            or nameof(RuntimeNodeSession.RpcStatus)
            or nameof(RuntimeNodeSession.RpcError)
            or nameof(RuntimeNodeSession.RpcLastUpdated)
            or nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcEnabled))
        {
            RefreshPeers();
        }
    }

    private void RefreshPeers()
    {
        Peers.Clear();
        if (_session.RpcSnapshot?.Peers is { } peers)
        {
            foreach (var peer in peers.OrderByDescending(x => x.IsIbdPeer).ThenBy(x => x.Address, StringComparer.OrdinalIgnoreCase))
            {
                Peers.Add(new KeryxPeerRow(
                    peer.Address,
                    peer.IsOutbound ? "Outbound" : "Inbound",
                    peer.LastPingDuration.ToString(),
                    peer.IsIbdPeer ? "YES" : "NO",
                    peer.AdvertisedProtocolVersion.ToString(),
                    string.IsNullOrWhiteSpace(peer.UserAgent) ? "—" : peer.UserAgent));
            }
        }

        OnPropertyChanged(nameof(RpcStatus));
        OnPropertyChanged(nameof(RpcEndpoint));
        OnPropertyChanged(nameof(LastUpdated));
        OnPropertyChanged(nameof(LastError));
        OnPropertyChanged(nameof(TotalPeers));
        OnPropertyChanged(nameof(InboundPeers));
        OnPropertyChanged(nameof(OutboundPeers));
        OnPropertyChanged(nameof(IbdPeer));
        OnPropertyChanged(nameof(HasPeers));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _session.PropertyChanged -= SessionOnPropertyChanged;
    }
}

public sealed class PerformanceViewModel : ViewModelBase { }
public sealed class LogsViewModel : ViewModelBase { }
public sealed class SettingsViewModel : ViewModelBase { }
