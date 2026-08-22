using System.ComponentModel;
using System.Windows.Threading;
using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class DashboardViewModel : ViewModelBase
{
    private readonly RuntimeNodeSession _session;
    private readonly ProcessPerformanceSampler _performanceSampler = new();
    private readonly DispatcherTimer _timer;
    private ProcessPerformanceSnapshot? _performance;

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
    }

    private void RefreshMonitoringState()
    {
        _performance = null;
        _performanceSampler.Reset();
        if (_session.AttachedNode is null)
        {
            _timer?.Stop();
            return;
        }

        _performance = _performanceSampler.Sample(_session.AttachedNode.ProcessId);
        if (_timer is not null && !_timer.IsEnabled)
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
        OnPropertyChanged(nameof(NodeUptime));
        OnPropertyChanged(nameof(CpuUsage));
        OnPropertyChanged(nameof(PrivateMemory));
        OnPropertyChanged(nameof(WorkingSet));
        OnPropertyChanged(nameof(Threads));
        OnPropertyChanged(nameof(Handles));
        OnPropertyChanged(nameof(DiskIo));
    }

    private static string FormatBytes(long bytes)
    {
        const double gib = 1024d * 1024d * 1024d;
        const double mib = 1024d * 1024d;
        return bytes >= gib ? $"{bytes / gib:0.00} GB" : $"{bytes / mib:0.0} MB";
    }

    private static string FormatRate(double bytesPerSecond)
        => $"{bytesPerSecond / (1024d * 1024d):0.0} MB/s";
}

public sealed class PeersViewModel : ViewModelBase { }
public sealed class PerformanceViewModel : ViewModelBase { }
public sealed class LogsViewModel : ViewModelBase { }
public sealed class SettingsViewModel : ViewModelBase { }
